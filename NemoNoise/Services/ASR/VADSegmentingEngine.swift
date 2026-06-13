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
        var pieces: [String] = []
        while leftover.count >= windowSize {
            let window = Array(leftover.prefix(windowSize))
            leftover.removeFirst(windowSize)
            let isSpeech = detector.isSpeech(window)
            if case .segment(let seg) = segmenter.step(window: window, isSpeech: isSpeech) {
                let text = await decodeSegment(seg)
                if !text.isEmpty { pieces.append(text) }
            }
        }
        guard !pieces.isEmpty else {
            return TranscriptionResult(text: "", isFinal: false, emotion: nil)
        }
        return TranscriptionResult(text: TranscriptJoin.sentences(pieces), isFinal: true, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        defer { reset() }
        if let seg = segmenter.flush() {
            let text = await decodeSegment(seg)
            return TranscriptionResult(text: text, isFinal: true, emotion: nil)
        }
        return TranscriptionResult(text: "", isFinal: true, emotion: nil)
    }

    func reset() {
        leftover.removeAll(keepingCapacity: true)
        segmenter.reset()
        detector.reset()
        inner.reset()
    }

    /// Decode one segment through the inner offline engine via the standard
    /// ASREngine contract. A failed decode is logged and skipped (returns "")
    /// so one bad segment never ends the session.
    private func decodeSegment(_ samples: [Float]) async -> String {
        inner.reset()
        _ = try? await inner.feedChunk(samples, sampleRate: 16000)
        do {
            return try await inner.finish().text
        } catch {
            LogService.warn("Segment decode failed: \(error)", category: "VADSegmentingEngine")
            return ""
        }
    }
}
