import Speech
import AVFoundation
import os

/// FIFO queue of mid-stream final results emitted by SFSpeech. Extracted as a
/// value type so the queueing logic is unit-testable without an SFSpeech IO
/// dependency.
struct AppleSpeechFinalQueue {
    private var pending: [TranscriptionResult] = []

    mutating func enqueue(_ result: TranscriptionResult) {
        pending.append(result)
    }

    mutating func popNext() -> TranscriptionResult? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    /// Drain every queued final into one concatenated result (text joined by
    /// a single space, emotion of the first non-nil). Returns nil if empty.
    mutating func drainConcatenated() -> TranscriptionResult? {
        guard !pending.isEmpty else { return nil }
        let pieces = pending.map(\.text).filter { !$0.isEmpty }
        let combined = pieces.joined(separator: " ")
        let emotion = pending.compactMap(\.emotion).first
        pending.removeAll()
        return TranscriptionResult(text: combined, isFinal: true, emotion: emotion)
    }

    var isEmpty: Bool { pending.isEmpty }
}

final class AppleSpeechASREngine: ASREngine, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private struct State {
        /// Apple's latest cumulative transcription, updated on every callback
        /// (partial or isFinal). The source of truth for what was recognised.
        var latestCumulative: String = ""
        /// Mirror exposed to the UI as partialText. Same content as
        /// latestCumulative; kept separate to make the contract explicit.
        var partialText: String = ""
        var finishContinuation: CheckedContinuation<TranscriptionResult, Error>?
        var pendingError: Error?
        /// True once finish() called request.endAudio(). Mid-stream isFinal
        /// events from Apple BEFORE this point are unreliable (it keeps
        /// refining/replacing them); we only trust isFinal events AFTER this
        /// point as the true end-of-recording final.
        var endAudioCalled: Bool = false
    }
    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    init(locale: String? = nil) throws {
        let pref = LanguagePreference.current
        let start = ContinuousClock.now
        let resolved: SFSpeechRecognizer?

        if let localeId = locale ?? pref.localeIdentifier {
            resolved = SFSpeechRecognizer(locale: Locale(identifier: localeId))
                ?? SFSpeechRecognizer(locale: .current)
                ?? SFSpeechRecognizer()
        } else {
            resolved = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
                ?? SFSpeechRecognizer(locale: .current)
                ?? SFSpeechRecognizer()
        }

        guard let resolved else {
            LogService.error("SFSpeechRecognizer unavailable for locale: \(pref.localeIdentifier ?? "nil")", category: "ASR")
            throw ASRError.engineUnavailable
        }
        recognizer = resolved
        let elapsed = ContinuousClock.now - start
        LogService.info("locale: \(recognizer.locale.identifier), init duration: \(elapsed.description)", category: "AppleSpeechASREngine")
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        guard recognizer.isAvailable else {
            throw ASRError.audioCaptureFailed("Speech recognizer not available")
        }

        if request == nil {
            guard await requestPermission() else {
                throw ASRError.audioCaptureFailed("Speech recognition permission denied")
            }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = false
            req.addsPunctuation = true
            request = req

            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    let ns = error as NSError
                    // "No speech detected" is normal when the user holds the
                    // hotkey but doesn't talk. Don't surface it as an error —
                    // resolve as an empty final result so the UI just closes.
                    let isNoSpeech = ns.code == 1110
                        || ns.localizedDescription.localizedCaseInsensitiveContains("no speech")
                    if isNoSpeech {
                        let empty = TranscriptionResult(text: "", isFinal: true, emotion: nil)
                        // If finish() is already waiting, resolve it. Otherwise
                        // do nothing — when finish() arrives, the 500 ms timeout
                        // fallback will fire and return latestCumulative (which
                        // is "" since nothing was recognised), same result.
                        let cont = self.stateLock.withLock { state -> CheckedContinuation<TranscriptionResult, Error>? in
                            let cont = state.finishContinuation
                            state.finishContinuation = nil
                            return cont
                        }
                        cont?.resume(returning: empty)
                        return
                    }
                    let mapped: Error
                    if ns.localizedDescription.contains("Siri and Dictation are disabled") {
                        mapped = AppleSpeechError.siriDisabled
                    } else {
                        mapped = error
                    }
                    let cont = self.stateLock.withLock { state -> CheckedContinuation<TranscriptionResult, Error>? in
                        state.pendingError = mapped
                        let cont = state.finishContinuation
                        state.finishContinuation = nil
                        return cont
                    }
                    cont?.resume(throwing: mapped)
                    return
                }
                if let result {
                    let cumulative = result.bestTranscription.formattedString
                    // Always update latestCumulative + partialText. The
                    // isFinal flag from Apple is unreliable as a segment
                    // boundary — Apple emits isFinal repeatedly with
                    // refinements that REPLACE earlier "finals". Treat
                    // mid-stream isFinal as just-another-update; only when
                    // endAudioCalled is true do we trust an isFinal as the
                    // true end-of-recording signal.
                    let cont = self.stateLock.withLock { state -> CheckedContinuation<TranscriptionResult, Error>? in
                        state.latestCumulative = cumulative
                        state.partialText = cumulative
                        if result.isFinal, state.endAudioCalled, let c = state.finishContinuation {
                            state.finishContinuation = nil
                            return c
                        }
                        return nil
                    }
                    if let cont {
                        cont.resume(returning: TranscriptionResult(text: cumulative, isFinal: true, emotion: nil))
                    }
                }
            }
        }

        if let buffer = makePCMBuffer(from: samples, sampleRate: sampleRate) {
            request?.append(buffer)
        }

        let partial = stateLock.withLock { $0.partialText }
        return TranscriptionResult(text: partial, isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        request?.endAudio()

        let snapshot = stateLock.withLock { state -> Error? in
            if let err = state.pendingError {
                state.pendingError = nil
                return err
            }
            state.endAudioCalled = true
            return nil
        }
        if let error = snapshot {
            LogService.error("Recognition failed: \(error.localizedDescription)", category: "AppleSpeechASREngine")
            throw error
        }

        if task != nil {
            return try await withCheckedThrowingContinuation { continuation in
                let resolved = self.stateLock.withLock { state -> (TranscriptionResult?, Error?) in
                    if let error = state.pendingError {
                        state.pendingError = nil
                        return (nil, error)
                    }
                    state.finishContinuation = continuation
                    return (nil, nil)
                }
                if let error = resolved.1 {
                    continuation.resume(throwing: error)
                    return
                }
                if let final = resolved.0 {
                    continuation.resume(returning: final)
                    return
                }
                // Timeout fallback: if Apple doesn't emit a post-endAudio
                // isFinal within 500 ms, use whatever latestCumulative we have.
                // Apple usually emits within ~100 ms of endAudio(); 500 ms gives
                // headroom for longer buffered audio.
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    let (cont, latest) = self.stateLock.withLock { state -> (CheckedContinuation<TranscriptionResult, Error>?, String) in
                        let c = state.finishContinuation
                        state.finishContinuation = nil
                        return (c, state.latestCumulative)
                    }
                    cont?.resume(returning: TranscriptionResult(text: latest, isFinal: true, emotion: nil))
                }
            }
        }

        return TranscriptionResult(text: "", isFinal: true, emotion: nil)
    }

    func reset() {
        task?.cancel()
        task = nil
        request = nil
        stateLock.withLock { state in state = State() }
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
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
