import Foundation

/// `VADSpeechDetector` backed by sherpa-onnx's Silero voice activity detector.
///
/// sherpa's VAD C API is segment-level and exposes no per-frame probability,
/// but `SherpaOnnxVoiceActivityDetectorDetected()` returns a real-time
/// "currently in speech" flag computed by Silero — exactly what the gate needs.
/// We feed one `windowSize` window per call, discard the completed-segment
/// queue (we don't use it here; clearing prevents unbounded growth), and read
/// the live flag. Mirrors the OpaquePointer pattern of `SherpaOfflinePunctuator`.
final class SileroSpeechDetector: VADSpeechDetector, @unchecked Sendable {
    private let vad: OpaquePointer
    let windowSize: Int

    /// - Parameter modelPath: Path to `silero_vad.onnx`.
    init?(modelPath: String, windowSize: Int = 512) {
        var created: OpaquePointer?
        modelPath.withCString { cModel in
            "cpu".withCString { cProvider in
                var silero = SherpaOnnxSileroVadModelConfig()
                memset(&silero, 0, MemoryLayout.size(ofValue: silero))
                silero.model = cModel
                silero.threshold = 0.5
                silero.min_silence_duration = 0.25
                silero.min_speech_duration = 0.10
                silero.max_speech_duration = 20.0
                silero.window_size = Int32(windowSize)

                var config = SherpaOnnxVadModelConfig()
                memset(&config, 0, MemoryLayout.size(ofValue: config))
                config.silero_vad = silero
                config.sample_rate = 16000
                config.num_threads = 1
                config.provider = cProvider

                // Second arg is the detector's internal ring-buffer length in
                // seconds; 30 s matches sherpa's own examples.
                created = SherpaOnnxCreateVoiceActivityDetector(&config, 30.0)
            }
        }
        guard let created else { return nil }
        vad = created
        self.windowSize = windowSize
    }

    func isSpeech(_ window: [Float]) -> Bool {
        window.withUnsafeBufferPointer { buf in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buf.baseAddress, Int32(window.count))
        }
        SherpaOnnxVoiceActivityDetectorClear(vad)   // drop completed-segment queue
        return SherpaOnnxVoiceActivityDetectorDetected(vad) != 0
    }

    func reset() {
        SherpaOnnxVoiceActivityDetectorReset(vad)
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(vad)
    }
}
