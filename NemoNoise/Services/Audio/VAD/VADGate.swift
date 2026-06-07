import Foundation

/// Pure gating logic. Given a stream of fixed-size windows each tagged
/// speech / non-speech, decides what audio to forward downstream.
///
/// - Non-speech windows are replaced with silence (zeros) so a streaming ASR
///   engine still "hears" silence and its endpoint detection keeps working.
/// - The most recent `preSpeechWindows` non-speech windows are retained; on a
///   speech onset they are flushed (as real audio) ahead of the current window
///   so the engine doesn't lose the leading consonant.
///
/// IO-free and deterministic — unit-tested in isolation.
final class VADGate {
    private let windowSize: Int
    private let preSpeechCount: Int
    private var inSpeech = false
    private var preBuffer: [[Float]] = []

    init(config: VADConfig = .default) {
        self.windowSize = config.windowSize
        self.preSpeechCount = config.preSpeechWindows
    }

    /// Feed one window plus its speech decision; returns the windows to emit
    /// downstream (each `windowSize` samples).
    func step(window: [Float], isSpeech: Bool) -> [[Float]] {
        if isSpeech {
            if !inSpeech {
                inSpeech = true
                let flushed = preBuffer
                preBuffer.removeAll(keepingCapacity: true)
                return flushed + [window]
            }
            return [window]
        } else {
            inSpeech = false
            preBuffer.append(window)
            if preBuffer.count > preSpeechCount {
                preBuffer.removeFirst(preBuffer.count - preSpeechCount)
            }
            return [[Float](repeating: 0, count: windowSize)]
        }
    }

    func reset() {
        inSpeech = false
        preBuffer.removeAll(keepingCapacity: true)
    }
}
