import Foundation

/// `AudioSource` decorator that runs voice-activity gating between a real
/// source and the ASR engine. Slices `inner`'s variable-length chunks into
/// fixed `windowSize` windows, asks the detector whether each is speech, runs
/// `VADGate`, and re-emits gated audio as `AudioChunk`s.
///
/// Engine-agnostic and pipeline-transparent: swap `MicAudioSource()` for
/// `VADGatedSource(inner: MicAudioSource(), detector: …)` — nothing else changes.
///
/// `@unchecked Sendable`: all mutable state (`leftover`, `gate`, `detector`) is
/// touched only from the single pump `Task` created in `start()`. Call `start()`
/// once per session; `process(_:)` must not be invoked concurrently. (Tests call
/// `process(_:)` synchronously on one thread, which is safe.)
final class VADGatedSource: AudioSource, @unchecked Sendable {
    private let inner: any AudioSource
    private let detector: any VADSpeechDetector
    private let gate: VADGate
    private let windowSize: Int
    private let analyzer = SpectrumAnalyzer(binCount: 16, sampleRate: 16000)
    private var leftover: [Float] = []

    init(inner: any AudioSource, detector: any VADSpeechDetector, config: VADConfig = .default) {
        self.inner = inner
        self.detector = detector
        self.gate = VADGate(config: config)
        self.windowSize = config.windowSize
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        detector.reset()
        gate.reset()
        leftover.removeAll(keepingCapacity: true)
        let innerStream = try await inner.start()

        return AsyncStream<AudioChunk> { continuation in
            let task = Task { [self] in
                for await chunk in innerStream {
                    if let out = process(chunk.samples) {
                        continuation.yield(out)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() { inner.stop() }

    /// Slice accumulated samples into windows, gate each, repackage emitted
    /// samples into one AudioChunk. Returns nil if no full window was produced.
    /// `internal` (not private) so it can be unit-tested deterministically.
    func process(_ samples: [Float]) -> AudioChunk? {
        leftover.append(contentsOf: samples)
        var emitted: [Float] = []
        while leftover.count >= windowSize {
            let window = Array(leftover.prefix(windowSize))
            leftover.removeFirst(windowSize)
            let speech = detector.isSpeech(window)
            for w in gate.step(window: window, isSpeech: speech) {
                emitted.append(contentsOf: w)
            }
        }
        guard !emitted.isEmpty else { return nil }
        let rms = (emitted.reduce(Float(0)) { $0 + $1 * $1 } / Float(emitted.count)).squareRoot()
        let spectrum = analyzer.analyze(emitted)
        return AudioChunk(samples: emitted, rmsLevel: rms, spectrum: spectrum)
    }
}
