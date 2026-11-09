import Speech
import AVFoundation
import os

/// Locales whose assets have already been verified/installed in this
/// process. The AssetInventory queries are slow IPC round-trips and were
/// re-run on every session begin, which made each recording start sluggish.
private let speechAssetsReady = OSAllocatedUnfairLock<Set<String>>(initialState: [])

/// FIFO queue of mid-stream final results emitted by the transcriber.
/// Extracted as a value type so the queueing logic is unit-testable without a
/// Speech IO dependency.
nonisolated struct AppleSpeechFinalQueue {
    private var pending: [TranscriptionResult] = []

    mutating func enqueue(_ result: TranscriptionResult) {
        pending.append(result)
    }

    mutating func popNext() -> TranscriptionResult? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    /// Drain every queued final into one concatenated result (joined by
    /// `TranscriptJoin` — no stray space between CJK sentences; emotion of
    /// the first non-nil). Returns nil if empty.
    mutating func drainConcatenated() -> TranscriptionResult? {
        guard !pending.isEmpty else { return nil }
        let combined = TranscriptJoin.sentences(pending.map(\.text))
        let emotion = pending.compactMap(\.emotion).first
        let audioStart = pending.compactMap(\.audioStart).first
        pending.removeAll()
        return TranscriptionResult(text: combined, isFinal: true, emotion: emotion, audioStart: audioStart)
    }

    var isEmpty: Bool { pending.isEmpty }
}

/// What the engine has heard, in the shape the pipeline consumes: each
/// utterance the transcriber commits is reported once as its own `isFinal`
/// result (the segment boundary sinks rely on), and the partial is only the
/// utterance still being refined. Pure value type — the results loop feeds it,
/// `feedChunk` / `finish` read it.
nonisolated struct AppleSpeechTranscript {
    private var commits = AppleSpeechFinalQueue()
    private var volatile = ""
    private var volatileStart: TimeInterval?
    private var volatileEnd: TimeInterval?

    /// `audioStart` / `audioEnd`: the result's range on the session audio
    /// timeline.
    mutating func apply(text: String, isFinal: Bool,
                        audioStart: TimeInterval? = nil, audioEnd: TimeInterval? = nil) {
        if isFinal {
            // The final pass can drop phrases the last draft had heard — but
            // the draft often already runs past the range being finalized
            // ("ABCDEF" while "ABC" commits); keeping it then would commit
            // "DEF" twice. Only a draft within the final's range may replace
            // it; with either end unknown, trust the final.
            let draftWithinFinal: Bool = {
                guard let draftEnd = volatileEnd, let finalEnd = audioEnd else { return false }
                return draftEnd <= finalEnd + 0.05
            }()
            let kept = draftWithinFinal ? HeardText.fuller(final: text, draft: volatile) : text
            if kept != text {
                LogService.info("Final dropped words the draft had — kept the draft (\(text.count) → \(kept.count) chars)",
                                category: "AppleSpeechASREngine")
            }
            if !kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                commits.enqueue(TranscriptionResult(text: kept, isFinal: true, emotion: nil,
                                                    audioStart: audioStart ?? volatileStart))
            }
            volatile = ""
            volatileStart = nil
            volatileEnd = nil
        } else {
            volatile = text
            volatileStart = audioStart
            volatileEnd = audioEnd
        }
    }

    /// Per-chunk report: utterances committed since the last report as one
    /// final, otherwise the current utterance as a partial.
    mutating func takeChunkResult() -> TranscriptionResult {
        if let committed = commits.drainConcatenated() { return committed }
        return TranscriptionResult(text: volatile, isFinal: false, emotion: nil)
    }

    /// End-of-session report: whatever was not yet reported, plus the
    /// unfinished utterance.
    mutating func takeFinishResult() -> TranscriptionResult {
        let committed = commits.drainConcatenated()
        let text = TranscriptJoin.sentences([committed?.text ?? "", volatile])
        let audioStart = committed?.audioStart ?? (volatile.isEmpty ? nil : volatileStart)
        volatile = ""
        volatileStart = nil
        volatileEnd = nil
        return TranscriptionResult(text: text, isFinal: true, emotion: nil, audioStart: audioStart)
    }
}

/// Apple Speech engine backed by the macOS 26 `SpeechAnalyzer` framework —
/// fully on-device, no cloud, no request throttling (the old
/// `SFSpeechRecognizer` path hit kAFAssistantErrorDomain limits when users
/// burst short dictations).
///
/// Usage pattern mirrors the framework's streaming design: audio chunks are
/// yielded into an `AnalyzerInput` stream, `SpeechTranscriber.results`
/// delivers volatile partials per utterance plus `isFinal` commits, and
/// `finish()` ends the input and awaits the analyzer's end-of-input
/// finalization.
final class AppleSpeechASREngine: ASREngine, @unchecked Sendable {
    // The transcriber emits punctuation natively — the CT-Transformer must
    // not re-add it.
    let emitsPunctuation = true
    // Each transcriber `isFinal` is surfaced as one sentence (see
    // `AppleSpeechTranscript`).
    let emitsSentenceFinals = true

    private let localeID: String
    /// Locale tag for logs and assembly labels (e.g. "zh-CN"). `nonisolated`:
    /// reads only the immutable `localeID`, and the factory (nonisolated)
    /// logs it at build time.
    nonisolated var localeLabel: String { localeID }

    private struct State {
        var analyzer: SpeechAnalyzer?
        var transcriber: SpeechTranscriber?
        var input: AsyncStream<AnalyzerInput>.Continuation?
        var resultTask: Task<Void, Never>?
        var converter: AVAudioConverter?
        var targetFormat: AVAudioFormat?
        var sourceSampleRate: Double = 0
        /// Committed utterances not yet reported, plus the one being refined.
        var transcript = AppleSpeechTranscript()
        var pendingError: Error?
    }
    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    nonisolated init(locale: String? = nil) throws {
        let pref = LanguagePreference.current
        localeID = locale ?? pref.localeIdentifier ?? "zh-CN"
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        if stateLock.withLock({ $0.analyzer == nil }) {
            try await begin(sampleRate: sampleRate)
        }
        if let error = stateLock.withLock({ $0.pendingError }) {
            throw error
        }

        guard let buffer = makePCMBuffer(from: samples, sampleRate: sampleRate),
              let inputBuffer = convert(buffer) else {
            return partialResult()
        }
        let continuation = stateLock.withLock { $0.input }
        continuation?.yield(AnalyzerInput(buffer: inputBuffer))
        return partialResult()
    }

    func finish() async throws -> TranscriptionResult {
        stateLock.withLock { $0.input?.finish() }

        if let analyzer = stateLock.withLock({ $0.analyzer }) {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        // Wait for the results stream to commit the final utterance (bounded
        // — a fixed 100 ms sleep truncated the tail of the last sentence).
        let resultTask = stateLock.withLock { $0.resultTask }
        if let resultTask {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { _ = await resultTask.value; return true }
                group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
                _ = await group.next()
                group.cancelAll()
            }
        }

        let result = stateLock.withLock { $0.transcript.takeFinishResult() }
        let error = stateLock.withLock { $0.pendingError }
        teardown()
        if let error {
            LogService.error("Recognition failed: \(error.localizedDescription)", category: "AppleSpeechASREngine")
            throw error
        }
        return result
    }

    func reset() {
        teardown()
    }

    private func teardown() {
        stateLock.withLock { state in
            state.resultTask?.cancel()
            state.resultTask = nil
            state.input?.finish()
            state.input = nil
            state.analyzer = nil
            state.transcriber = nil
            state.converter = nil
            state.targetFormat = nil
            state.transcript = AppleSpeechTranscript()
            state.pendingError = nil
        }
    }

    private func partialResult() -> TranscriptionResult {
        stateLock.withLock { $0.transcript.takeChunkResult() }
    }

    /// One-time session setup on the first chunk: permission, transcriber +
    /// analyzer, language assets, hotword context, and the results loop.
    private func begin(sampleRate: Int) async throws {
        guard await requestPermission() else {
            throw ASRError.audioCaptureFailed("Speech recognition permission denied")
        }

        let locale = Locale(identifier: localeID)
        let wanted = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        guard supported.contains(wanted) else {
            LogService.error("SpeechAnalyzer has no locale \(wanted) (supported: \(supported.sorted().joined(separator: ", ")))", category: "AppleSpeechASREngine")
            throw ASRError.engineUnavailable
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // No `.fastResults`: tried on meeting + translation tracks
            // (2026-11-09, device). The user felt no latency gain, Chinese
            // lost nearly all commas, the period of a committed sentence
            // leaked to the next line's start, and short read-aloud phrases
            // came out wrong ("帮个忙" → "万个忙", "领域还在" → "两翼小虫").
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Bias recognition toward the user's dictionary so names and jargon
        // come out right when spoken.
        let bias = UserLexicon.biasStrings()
        if !bias.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = bias
            try? await analyzer.setContext(context)
        }

        try await ensureAssets(for: transcriber, bcp47: wanted)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ASRError.engineUnavailable
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let resultTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    // The analyzer's timeline starts at the first buffer fed —
                    // the session's first chunk.
                    let start = result.range.start
                    let end = result.range.end
                    let audioStart = start.isNumeric ? start.seconds : nil
                    let audioEnd = end.isNumeric ? end.seconds : nil
                    self.stateLock.withLock {
                        $0.transcript.apply(text: text, isFinal: result.isFinal,
                                            audioStart: audioStart, audioEnd: audioEnd)
                    }
                }
            } catch {
                LogService.warn("SpeechAnalyzer result error: \(error.localizedDescription)", category: "AppleSpeechASREngine")
                self.stateLock.withLock { $0.pendingError = error }
            }
        }

        try await analyzer.start(inputSequence: stream)

        // Chunks arrive as mono Float at the source rate; convert when the
        // analyzer wants a different format.
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )
        let converter: AVAudioConverter? = {
            guard let sourceFormat, !format.isEqual(sourceFormat) else { return nil }
            return AVAudioConverter(from: sourceFormat, to: format)
        }()

        stateLock.withLock { state in
            state.analyzer = analyzer
            state.transcriber = transcriber
            state.input = continuation
            state.resultTask = resultTask
            state.converter = converter
            state.targetFormat = format
            state.sourceSampleRate = Double(sampleRate)
        }
        LogService.info("SpeechAnalyzer session started — locale=\(wanted), format=\(format)", category: "AppleSpeechASREngine")
    }

    /// Warm the SpeechAnalyzer stack at launch: resolve locale support and
    /// make sure the on-device assets are installed and reserved, so the
    /// first dictation session isn't held up by asset queries/downloads.
    /// Errors are swallowed — prewarm is best-effort; the session-time path
    /// still enforces them.
    static func prewarm(locale: String? = nil) async {
        let id = locale ?? LanguagePreference.current.localeIdentifier ?? "zh-CN"
        let bcp47 = Locale(identifier: id).identifier(.bcp47)
        guard speechAssetsReady.withLock({ !$0.contains(bcp47) }) else { return }

        let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        guard supported.contains(bcp47) else { return }
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: id),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        try? await installAssets(for: transcriber, localeID: id, bcp47: bcp47)
    }

    /// Download/prepare the on-device language assets for the locale (first
    /// use only) and keep the locale reserved so it isn't evicted.
    private func ensureAssets(for transcriber: SpeechTranscriber, bcp47: String) async throws {
        if speechAssetsReady.withLock({ $0.contains(bcp47) }) { return }
        try await Self.installAssets(for: transcriber, localeID: localeID, bcp47: bcp47)
    }

    private static func installAssets(for transcriber: SpeechTranscriber, localeID: String, bcp47: String) async throws {
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        if !installed.contains(bcp47) {
            LogService.info("SpeechAnalyzer assets missing for \(bcp47) — downloading", category: "AppleSpeechASREngine")
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                throw ASRError.engineUnavailable
            }
            try await request.downloadAndInstall()
        }
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == bcp47 }) {
            try? await AssetInventory.reserve(locale: Locale(identifier: localeID))
        }
        speechAssetsReady.withLock { $0.insert(bcp47) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat = stateLock.withLock({ $0.targetFormat }) else { return nil }
        guard let converter = stateLock.withLock({ $0.converter }) else {
            return buffer
        }
        let capacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)
        ) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        do {
            try converter.convert(to: out, from: buffer)
        } catch {
            return nil
        }
        guard out.frameLength > 0 else { return nil }
        return out
    }

    private func makePCMBuffer(from samples: [Float], sampleRate: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }
        let count = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        buffer.frameLength = count
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress, let channelData = buffer.floatChannelData else { return }
            channelData[0].update(from: base, count: samples.count)
        }
        return buffer
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            // The handler runs on an arbitrary queue (SFSpeechRecognizer.h);
            // `@Sendable` keeps it from inheriting main-actor isolation, which
            // Swift 6 would assert at runtime.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
