import Foundation

/// `ASREngine` decorator that turns a non-streaming offline engine
/// (Qwen3 / SenseVoice) into a progressively-emitting one. It slices the audio
/// stream into 512-sample windows, asks the Silero detector whether each is
/// speech, runs `VADSegmenter`, and decodes each completed segment through the
/// wrapped `inner` engine. Each decoded segment is returned as an `isFinal`
/// result — the same contract a streaming engine uses at an endpoint — so the
/// existing `OverlayProgressSink` / `confirmedSegments` machinery accumulates
/// it, and `RecordingController` injects the joined segments unchanged.
///
/// Beyond plain slicing, the decorator carries cross-segment context so the
/// per-segment decodes don't drift from each other:
///
///  * **prior bias** — the session's confirmed transcript so far is handed to
///    each decode via `BiasableDecodeEngine` (Qwen3 per-stream hotwords), so a
///    name is spelled the same way in every segment;
///  * **hallucination guards** — a prompt-driven decoder fed noise can answer
///    with the bias list itself or an echo of the prior; `DecodeGuards` catches
///    both and re-decodes once with the reduced bias;
///  * **seam pauses** — each result carries the measured silence before its
///    first speech (`pauseBefore`), letting `TranscriptJoin` keep sentence
///    marks only at real sentence ends instead of at every breath.
///
/// Reports `isStreaming == true` so `OverlayView.shouldShowTranscript` displays
/// the progressive text, even though `inner` is offline.
///
/// `@unchecked Sendable`: all mutable state is touched only from the single
/// pump task that drives `feedChunk` inside `TranscriptionPipeline` (same
/// contract as `VADGatedSource`); `feedChunk` is never called concurrently.
/// Per-segment decodes are therefore naturally serialized — the pipeline
/// awaits each `feedChunk` before pulling the next chunk, while `MicAudioSource`
/// keeps buffering incoming audio into its `AsyncStream` so nothing is lost.
final class VADSegmentingEngine: ASREngine, @unchecked Sendable {
    private let inner: any ASREngine
    private let detector: any VADSpeechDetector
    private let segmenter: VADSegmenter
    private let windowSize: Int
    private var leftover: [Float] = []
    /// Samples run through the segmenter this session. A segment is
    /// contiguous audio ending at the window that closed it, so its start is
    /// `consumed - segment.count`.
    private var consumed = 0

    /// Confirmed transcript so far (all decoded pieces joined) — the prior
    /// context handed to each segment decode. Only its tail goes into a bias.
    private var confirmedText = ""
    /// Speech-timing marks for seam pauses, in consumed-sample counts:
    /// the last speech window seen, the first speech window since the last
    /// segment closed, and the last speech window of the previous segment.
    private var lastSpeechSample: Int?
    private var firstSpeechSinceSegment: Int?
    private var prevSegmentLastSpeechSample: Int?

    let isStreaming = true

    /// Delegates to the wrapped engine: the decorator passes inner text through
    /// unchanged, so if the inner engine self-punctuates (Qwen3), so does this.
    var emitsPunctuation: Bool { inner.emitsPunctuation }

    init(inner: any ASREngine, detector: any VADSpeechDetector, config: VADConfig = .default) {
        self.inner = inner
        self.detector = detector
        self.segmenter = VADSegmenter(config: config)
        self.windowSize = config.windowSize
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        leftover.append(contentsOf: samples)
        var pieces: [SegmentPiece] = []
        while leftover.count >= windowSize {
            let window = Array(leftover.prefix(windowSize))
            leftover.removeFirst(windowSize)
            consumed += windowSize
            let isSpeech = detector.isSpeech(window)
            if isSpeech {
                if firstSpeechSinceSegment == nil { firstSpeechSinceSegment = consumed }
                lastSpeechSample = consumed
            }
            let cutsBefore = segmenter.forceCutCount
            if case .segment(let seg) = segmenter.step(window: window, isSpeech: isSpeech) {
                if segmenter.forceCutCount > cutsBefore {
                    LogService.info("VAD force-cut #\(segmenter.forceCutCount) at \(String(format: "%.1f", Double(consumed) / 16000))s, segment \(String(format: "%.1f", Double(seg.count) / 16000))s", category: "VAD")
                }
                let pauseBefore = seamPauseSeconds()
                advanceSpeechMarks()
                let text = await decodeSegment(seg)
                if !text.isEmpty {
                    pieces.append(SegmentPiece(text: text, pauseBefore: pauseBefore, start: start(of: seg)))
                }
            }
        }
        guard let first = pieces.first else {
            return TranscriptionResult(text: "", isFinal: false, emotion: nil)
        }
        return TranscriptionResult(text: TranscriptJoin.sentences(pieces.map { ($0.text, $0.pauseBefore) }),
                                   isFinal: true, emotion: nil,
                                   audioStart: first.start, pauseBefore: first.pauseBefore)
    }

    func finish() async throws -> TranscriptionResult {
        defer { reset() }
        if let seg = segmenter.flush() {
            let pauseBefore = seamPauseSeconds()
            advanceSpeechMarks()
            let text = await decodeSegment(seg)
            return TranscriptionResult(text: text, isFinal: true, emotion: nil,
                                       audioStart: start(of: seg), pauseBefore: pauseBefore)
        }
        return TranscriptionResult(text: "", isFinal: true, emotion: nil)
    }

    func reset() {
        leftover.removeAll(keepingCapacity: true)
        consumed = 0
        confirmedText = ""
        lastSpeechSample = nil
        firstSpeechSinceSegment = nil
        prevSegmentLastSpeechSample = nil
        segmenter.reset()
        detector.reset()
        inner.reset()
    }

    private func start(of segment: [Float]) -> TimeInterval {
        Double(max(0, consumed - segment.count)) / 16000
    }

    /// Silence between the previous segment's last speech and this segment's
    /// first speech, in seconds; nil when there was no previous segment.
    private func seamPauseSeconds() -> TimeInterval? {
        guard let first = firstSpeechSinceSegment, let prev = prevSegmentLastSpeechSample else { return nil }
        return max(0, Double(first - prev) / 16000)
    }

    /// A closed segment's speech marks become the next seam's baseline.
    private func advanceSpeechMarks() {
        prevSegmentLastSpeechSample = lastSpeechSample
        firstSpeechSinceSegment = nil
    }

    /// Decode one segment through the inner offline engine via the standard
    /// ASREngine contract. A failed decode is logged and skipped (returns "")
    /// so one bad segment never ends the session.
    ///
    /// When `inner` accepts a bias (`BiasableDecodeEngine`), the decode runs
    /// with lexicon + prior, and a hallucination guard that fires re-decodes
    /// once with the offending half of the bias removed.
    private func decodeSegment(_ samples: [Float]) async -> String {
        let terms = UserLexicon.biasStrings()
        guard let biasable = inner as? (any BiasableDecodeEngine) else {
            let text = await decodeOnce(samples)
            record(text)
            return text
        }
        biasable.setNextDecodeBias(DecodeBias.compose(terms: terms, prior: confirmedText))
        var text = await decodeOnce(samples)
        if !text.isEmpty {
            if DecodeGuards.isLexiconDump(text, terms: terms) {
                biasable.setNextDecodeBias(DecodeBias.compose(terms: [], prior: confirmedText))
                let retry = await decodeOnce(samples)
                if !retry.isEmpty && !DecodeGuards.isLexiconDump(retry, terms: terms) {
                    LogService.info("Lexicon-dump guard: re-decoded without terms (\"\(text.prefix(30))\" → \"\(retry.prefix(30))\")", category: "VADSegmentingEngine")
                    text = retry
                }
            } else if DecodeGuards.echoesPrior(text, prior: confirmedText,
                                               audioSeconds: Double(samples.count) / 16000) {
                biasable.setNextDecodeBias(DecodeBias.compose(terms: terms, prior: ""))
                let retry = await decodeOnce(samples)
                if !retry.isEmpty && Double(retry.count) < DecodeGuards.echoAcceptRatio * Double(text.count) {
                    LogService.info("Prior-echo guard: re-decoded without prior (\"\(text.prefix(30))\" → \"\(retry.prefix(30))\")", category: "VADSegmentingEngine")
                    text = retry
                }
            }
        }
        record(text)
        return text
    }

    private func decodeOnce(_ samples: [Float]) async -> String {
        inner.reset()
        _ = try? await inner.feedChunk(samples, sampleRate: 16000)
        do {
            return try await inner.finish().text
        } catch {
            LogService.warn("Segment decode failed: \(error)", category: "VADSegmentingEngine")
            return ""
        }
    }

    private func record(_ text: String) {
        guard !text.isEmpty else { return }
        confirmedText = TranscriptJoin.sentences([confirmedText, text])
    }

    private struct SegmentPiece {
        let text: String
        let pauseBefore: TimeInterval?
        let start: TimeInterval
    }
}
