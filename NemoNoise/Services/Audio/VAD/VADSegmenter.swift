import Foundation

/// One segmentation decision per fixed-size window.
enum SegmenterEvent: Equatable {
    /// Still accumulating the current utterance (or idle in silence).
    case buffering
    /// A completed segment's samples (pre-speech prefix + speech + trailing
    /// hangover silence), ready to decode.
    case segment([Float])
}

/// Pure, IO-free speech segmentation state machine. Given a stream of
/// fixed-size windows tagged speech/non-speech, it accumulates the current
/// utterance and emits a completed segment when an endpoint is reached:
/// sustained silence (`minSilenceMs` hangover) or a `maxSegmentMs` force-cut.
/// Runs shorter than `minSpeechMs` are treated as noise and discarded.
///
/// Durations are counted in *windows*, never wall-clock, so the machine is
/// fully deterministic and unit-testable. Mirrors `VADGate`'s pre-speech
/// onset recovery (96 ms ring buffer) so the leading consonant isn't clipped.
final class VADSegmenter {
    private let windowSize: Int
    private let preSpeechCount: Int
    private let minSilenceWindows: Int
    private let minSpeechWindows: Int
    private let maxSegmentWindows: Int

    private var inSpeech = false
    private var current: [Float] = []
    private var preBuffer: [[Float]] = []
    private var silenceRun = 0
    private var speechWindows = 0
    private var segmentWindows = 0

    init(config: VADConfig = .default) {
        self.windowSize = config.windowSize
        self.preSpeechCount = config.preSpeechWindows
        let windowMs = Double(config.windowSize) / 16000.0 * 1000.0
        func windows(_ ms: Int) -> Int { max(1, Int((Double(ms) / windowMs).rounded(.up))) }
        self.minSilenceWindows = windows(config.minSilenceMs)
        self.minSpeechWindows = windows(config.minSpeechMs)
        self.maxSegmentWindows = windows(config.maxSegmentMs)
    }

    func step(window: [Float], isSpeech: Bool) -> SegmenterEvent {
        if !inSpeech {
            if isSpeech {
                // Onset: open a segment, prepend the pre-speech ring buffer.
                inSpeech = true
                current = preBuffer.flatMap { $0 } + window
                preBuffer.removeAll(keepingCapacity: true)
                silenceRun = 0
                speechWindows = 1
                segmentWindows = current.count / windowSize
                return .buffering
            }
            preBuffer.append(window)
            if preBuffer.count > preSpeechCount {
                preBuffer.removeFirst(preBuffer.count - preSpeechCount)
            }
            return .buffering
        }

        // In speech: always accumulate (keeps trailing offset audio intact).
        current.append(contentsOf: window)
        segmentWindows += 1
        if isSpeech {
            silenceRun = 0
            speechWindows += 1
        } else {
            silenceRun += 1
        }

        if segmentWindows >= maxSegmentWindows { return closeSegment() }
        if silenceRun >= minSilenceWindows { return closeSegment() }
        return .buffering
    }

    /// Flush an in-progress segment at end of recording. Returns nil when no
    /// segment is open or it never had enough speech.
    func flush() -> [Float]? {
        defer { resetSegmentState() }
        guard inSpeech, speechWindows >= minSpeechWindows else { return nil }
        return current
    }

    func reset() {
        resetSegmentState()
        preBuffer.removeAll(keepingCapacity: true)
    }

    private func closeSegment() -> SegmenterEvent {
        defer { resetSegmentState() }
        if speechWindows >= minSpeechWindows { return .segment(current) }
        return .buffering   // noise blip — discard
    }

    private func resetSegmentState() {
        inSpeech = false
        current.removeAll(keepingCapacity: true)
        silenceRun = 0
        speechWindows = 0
        segmentWindows = 0
    }
}
