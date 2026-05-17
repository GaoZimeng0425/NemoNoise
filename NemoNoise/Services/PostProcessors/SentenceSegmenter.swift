import Foundation

/// Pipeline-level sentence segmenter. Converts the partial/final stream
/// from an ASR engine into a stream of bounded segments suitable for
/// downstream translation. See
/// `docs/superpowers/specs/2026-05-17-streaming-translation-realtime-design.md`.
///
/// Single-consumer: the pipeline owns the instance and calls `process` serially.
final class SentenceSegmenter: PostProcessor, @unchecked Sendable {
    private let silenceThreshold: TimeInterval = 0.8
    private let maxSegmentDuration: TimeInterval = 6.0
    private let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！"]

    private let engine: any ASREngine
    private let now: @Sendable () -> Date

    private var currentSeq: Int = 0
    private var consumedTextLength: Int = 0
    private var segmentStartTime: Date
    private var lastPartialChangeTime: Date
    private var lastPartialText: String = ""

    init(engine: any ASREngine, now: @escaping @Sendable () -> Date = { Date() }) {
        self.engine = engine
        self.now = now
        let n = now()
        self.segmentStartTime = n
        self.lastPartialChangeTime = n
    }

    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        if result.text.isEmpty { return nil }

        if isFinal {
            currentSeq += 1
            let out = TranscriptionResult(
                text: result.text,
                isFinal: true,
                emotion: result.emotion,
                originalText: result.originalText,
                sequence: currentSeq
            )
            resetSegmentState()
            return out
        }

        let fullCount = result.text.count
        if fullCount < consumedTextLength {
            // Engine rewrote / shrunk OR new session warm-start. Reset all per-segment state.
            resetSegmentState()
        }
        let delta = String(result.text.dropFirst(consumedTextLength))
        if delta.isEmpty { return nil }    // <-- NEW

        if delta != lastPartialText {
            lastPartialText = delta
            lastPartialChangeTime = now()
        }

        let trimmed = delta.trimmingCharacters(in: .whitespaces)
        let endsWithSentenceEnder = trimmed.last.map { sentenceEnders.contains($0) } ?? false
        let n = now()
        let exceededHardLimit = n.timeIntervalSince(segmentStartTime) > maxSegmentDuration
        let stalledForSilence = !delta.isEmpty
            && n.timeIntervalSince(lastPartialChangeTime) > silenceThreshold

        if endsWithSentenceEnder || exceededHardLimit || stalledForSilence {
            currentSeq += 1
            let out = TranscriptionResult(
                text: delta,
                isFinal: true,
                emotion: result.emotion,
                originalText: result.originalText,
                sequence: currentSeq
            )
            consumedTextLength = fullCount
            engine.markBoundary()
            segmentStartTime = n
            lastPartialChangeTime = n
            lastPartialText = ""
            return out
        }

        return TranscriptionResult(
            text: delta,
            isFinal: false,
            emotion: result.emotion,
            originalText: result.originalText,
            sequence: currentSeq + 1
        )
    }

    private func resetSegmentState() {
        consumedTextLength = 0
        let n = now()
        segmentStartTime = n
        lastPartialChangeTime = n
        lastPartialText = ""
    }
}
