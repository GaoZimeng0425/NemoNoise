import Foundation

/// Per-window speech / non-speech decision for a fixed-size audio window.
/// The seam that lets the VAD backend (Silero model vs. energy fallback) swap
/// without touching the gate. Resolved from the design-spec spike: sherpa-onnx
/// exposes a real-time "currently in speech" boolean, not a per-frame
/// probability — so this returns Bool, not Float.
protocol VADSpeechDetector: AnyObject {
    /// Number of samples each `isSpeech` call expects. 512 for Silero @ 16 kHz.
    var windowSize: Int { get }
    /// Decide whether `window` (16 kHz mono Float) is speech.
    func isSpeech(_ window: [Float]) -> Bool
    /// Clear internal state for a new recording session.
    func reset()
}

/// Tunables for the VAD gate. Defaults mirror LiveTranslate's vad_processor.py.
struct VADConfig {
    /// Window fed to the detector; Silero's native window at 16 kHz.
    var windowSize: Int = 512
    /// Windows of pre-speech audio retained to recover clipped onsets.
    /// 3 × 512 / 16000 ≈ 96 ms.
    var preSpeechWindows: Int = 3
    /// Energy-fallback RMS threshold (used only by EnergySpeechDetector).
    var energyThreshold: Float = 0.02

    static let `default` = VADConfig()
}

/// Model-free fallback: flags a window as speech when its RMS exceeds a
/// threshold. Weak against music/noise, but needs no model — used when the
/// Silero model is absent.
final class EnergySpeechDetector: VADSpeechDetector {
    let windowSize: Int
    private let threshold: Float

    init(config: VADConfig = .default) {
        self.windowSize = config.windowSize
        self.threshold = config.energyThreshold
    }

    func isSpeech(_ window: [Float]) -> Bool {
        guard !window.isEmpty else { return false }
        let sumSq = window.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (sumSq / Float(window.count)).squareRoot()
        return rms >= threshold
    }

    func reset() {}
}
