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
    /// 5 × 512 / 16000 = 160 ms of leading silence inside every segment.
    /// LLM-style offline decoders need that natural utterance edge: trimming
    /// just 0.18 s of it measurably corrupts the first syllable (语音输入 →
    /// 语音水软), and ~150 ms of head padding is what the reference lore
    /// (blurt dogfood) settled on for whole-utterance decoding.
    var preSpeechWindows: Int = 5
    /// Energy-fallback RMS threshold (used only by EnergySpeechDetector).
    var energyThreshold: Float = 0.02

    // MARK: - Segmentation (VADSegmenter, Phase 2)

    /// Sustained silence after speech that closes a segment (hangover).
    /// 600 ms keeps natural in-sentence pauses from splitting a segment.
    var minSilenceMs: Int = 600
    /// Minimum speech duration for a segment to count; shorter runs are
    /// treated as noise blips and discarded. ~200 ms.
    var minSpeechMs: Int = 200
    /// Hard cap on a single segment with no pause; forces a cut so no
    /// offline decode ever exceeds the model's short-audio window. 15 s.
    var maxSegmentMs: Int = 15000

    static let `default` = VADConfig()

    /// Meeting mode: longer hangover and a much longer hard cut than dictation
    /// — hour-long sessions shouldn't shred into dictation-sized 15 s pieces,
    /// but segments must still stay bounded for the offline decode window and
    /// for the live panel to update at a readable cadence.
    static let meeting = VADConfig(minSilenceMs: 800, maxSegmentMs: 30_000)
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
