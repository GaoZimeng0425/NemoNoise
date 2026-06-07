# Voice-Input VAD Robustness Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a voice-activity gate between the microphone and the ASR engine so dictation no longer clips the first word or hallucinates text from silence/noise — for every engine, with zero pipeline/engine-protocol changes.

**Architecture:** A `VADGatedSource` `AudioSource` decorator wraps `MicAudioSource`. It slices the inner source's variable-length chunks into 512-sample windows, asks a `VADSpeechDetector` (Silero via sherpa-onnx, energy fallback) whether each window is speech, and runs a pure `VADGate`: non-speech windows are emitted as silence (so streaming engines' endpoint detection still works), and a small pre-speech ring buffer is flushed on speech onset (so the leading consonant isn't lost). `PipelineProvider` swaps `MicAudioSource()` for the gated source.

**Tech Stack:** Swift, XCTest, sherpa-onnx C API (`SherpaOnnxVoiceActivityDetector`), AVFoundation. macOS app target `NemoNoise`.

**Spec:** `docs/superpowers/specs/2026-06-07-voice-input-vad-design.md`

## Conventions for every task

- **Code lives at** `<repo-root>/NemoNoise/` (the Swift app sources). New VAD files go in `NemoNoise/Services/Audio/VAD/`. Tests go in `NemoNoiseTests/`. All paths in this plan are relative to repo root `/Users/gaozimeng/Learn/macOS/NemoNoise`.
- The Xcode project uses **file-system-synchronized groups** — new `.swift` files under existing synchronized folders are auto-added to the target. No `.pbxproj` edits.
- **Build/test command** (run from repo root `/Users/gaozimeng/Learn/macOS/NemoNoise`):
  ```bash
  xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
    -destination 'platform=macOS' -only-testing:NemoNoiseTests/<ClassName> -quiet 2>&1 | tail -25
  ```
  Success prints `** TEST SUCCEEDED **`; failure prints `** TEST FAILED **` with the failing assertion.
- A "verify it fails" step in Swift usually fails at **compile time** ("cannot find 'X' in scope") because the type doesn't exist yet. That counts as the expected red.
- All test classes start with `import XCTest` and `@testable import NemoNoise`.

---

### Task 1: `VADSpeechDetector` protocol + `VADConfig` + `EnergySpeechDetector`

The model-free seam and the fallback detector. No sherpa dependency, fully unit-testable.

**Files:**
- Create: `NemoNoise/Services/Audio/VAD/VADSpeechDetector.swift`
- Test: `NemoNoiseTests/EnergySpeechDetectorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `NemoNoiseTests/EnergySpeechDetectorTests.swift`:

```swift
import XCTest
@testable import NemoNoise

final class EnergySpeechDetectorTests: XCTestCase {
    private func window(_ amplitude: Float, count: Int = 512) -> [Float] {
        [Float](repeating: amplitude, count: count)
    }

    func testLoudWindowIsSpeech() {
        let det = EnergySpeechDetector(config: VADConfig.default)
        XCTAssertTrue(det.isSpeech(window(0.5)))
    }

    func testSilentWindowIsNotSpeech() {
        let det = EnergySpeechDetector(config: VADConfig.default)
        XCTAssertFalse(det.isSpeech(window(0.0)))
    }

    func testThresholdBoundary() {
        var cfg = VADConfig.default
        cfg.energyThreshold = 0.1
        let det = EnergySpeechDetector(config: cfg)
        XCTAssertFalse(det.isSpeech(window(0.05)))   // rms 0.05 < 0.1
        XCTAssertTrue(det.isSpeech(window(0.2)))      // rms 0.2 > 0.1
    }

    func testWindowSizeFromConfig() {
        XCTAssertEqual(EnergySpeechDetector(config: .default).windowSize, 512)
    }

    func testEmptyWindowIsNotSpeech() {
        XCTAssertFalse(EnergySpeechDetector(config: .default).isSpeech([]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' -only-testing:NemoNoiseTests/EnergySpeechDetectorTests -quiet 2>&1 | tail -25
```
Expected: build FAILS with "cannot find 'EnergySpeechDetector' / 'VADConfig' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `NemoNoise/Services/Audio/VAD/VADSpeechDetector.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/Services/Audio/VAD/VADSpeechDetector.swift NemoNoiseTests/EnergySpeechDetectorTests.swift
git commit -m "feat(vad): add VADSpeechDetector seam + energy fallback detector"
```

---

### Task 2: `VADGate` pure gating logic

Decides what to emit per window: silence for non-speech, pre-buffer flush on onset.

**Files:**
- Create: `NemoNoise/Services/Audio/VAD/VADGate.swift`
- Test: `NemoNoiseTests/VADGateTests.swift`

- [ ] **Step 1: Write the failing test**

Create `NemoNoiseTests/VADGateTests.swift`:

```swift
import XCTest
@testable import NemoNoise

final class VADGateTests: XCTestCase {
    private let W = 512
    private func real(_ v: Float = 0.5) -> [Float] { [Float](repeating: v, count: 512) }

    func testNonSpeechEmitsSingleSilentWindow() {
        let gate = VADGate(config: .default)
        let out = gate.step(window: real(), isSpeech: false)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].count, W)
        XCTAssertTrue(out[0].allSatisfy { $0 == 0 })
    }

    func testSustainedSpeechPassesThroughUnchanged() {
        let gate = VADGate(config: .default)
        _ = gate.step(window: real(), isSpeech: true)   // onset
        let out = gate.step(window: real(0.7), isSpeech: true)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], real(0.7))
    }

    func testOnsetFlushesPreSpeechBufferThenCurrentWindow() {
        let gate = VADGate(config: .default)   // preSpeechWindows = 3
        // Two non-speech windows accumulate into the pre-buffer (and emit silence).
        _ = gate.step(window: real(0.1), isSpeech: false)
        _ = gate.step(window: real(0.2), isSpeech: false)
        // Onset: flush the 2 buffered real windows, then the current speech window.
        let out = gate.step(window: real(0.3), isSpeech: true)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0], real(0.1))
        XCTAssertEqual(out[1], real(0.2))
        XCTAssertEqual(out[2], real(0.3))
    }

    func testPreSpeechBufferIsCappedAtConfiguredWindows() {
        let gate = VADGate(config: .default)   // cap 3
        for v in [Float(0.1), 0.2, 0.3, 0.4, 0.5] {
            _ = gate.step(window: real(v), isSpeech: false)
        }
        let out = gate.step(window: real(0.9), isSpeech: true)
        // Only the last 3 non-speech windows survive + current.
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0], real(0.3))
        XCTAssertEqual(out[1], real(0.4))
        XCTAssertEqual(out[2], real(0.5))
        XCTAssertEqual(out[3], real(0.9))
    }

    func testResetClearsStateAndBuffer() {
        let gate = VADGate(config: .default)
        _ = gate.step(window: real(0.1), isSpeech: false)
        gate.reset()
        // After reset, an onset has nothing buffered to flush.
        let out = gate.step(window: real(0.3), isSpeech: true)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], real(0.3))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' -only-testing:NemoNoiseTests/VADGateTests -quiet 2>&1 | tail -25
```
Expected: FAIL — "cannot find 'VADGate' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `NemoNoise/Services/Audio/VAD/VADGate.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/Services/Audio/VAD/VADGate.swift NemoNoiseTests/VADGateTests.swift
git commit -m "feat(vad): add pure VADGate (silence gating + pre-speech onset buffer)"
```

---

### Task 3: `VADGatedSource` AudioSource decorator

Slices inner chunks into windows, drives detector + gate, repackages gated audio into `AudioChunk`s.

**Files:**
- Create: `NemoNoise/Services/Audio/VAD/VADGatedSource.swift`
- Test: `NemoNoiseTests/VADGatedSourceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `NemoNoiseTests/VADGatedSourceTests.swift`. It uses a scripted detector and calls the internal `process(_:)` directly (deterministic, no async):

```swift
import XCTest
@testable import NemoNoise

/// Detector test double: returns a scripted decision per window.
private final class ScriptedSpeechDetector: VADSpeechDetector {
    let windowSize: Int
    private let decisions: [Bool]
    private var i = 0
    init(windowSize: Int = 512, decisions: [Bool]) {
        self.windowSize = windowSize
        self.decisions = decisions
    }
    func isSpeech(_ window: [Float]) -> Bool {
        defer { i += 1 }
        return i < decisions.count ? decisions[i] : false
    }
    func reset() { i = 0 }
}

final class VADGatedSourceTests: XCTestCase {
    private func samples(_ v: Float, _ count: Int) -> [Float] { [Float](repeating: v, count: count) }

    func testConformsToAudioSource() {
        let _: any AudioSource = VADGatedSource(
            inner: MockAudioSource(),
            detector: EnergySpeechDetector()
        )
    }

    func testReturnsNilWhenLessThanOneWindow() {
        let src = VADGatedSource(inner: MockAudioSource(),
                                 detector: ScriptedSpeechDetector(decisions: [true]))
        XCTAssertNil(src.process(samples(0.5, 300)))   // < 512
    }

    func testSilenceIsGatedToZeros() {
        let src = VADGatedSource(inner: MockAudioSource(),
                                 detector: ScriptedSpeechDetector(decisions: [false, false]))
        let out = src.process(samples(0.5, 1024))      // 2 windows, both non-speech
        XCTAssertNotNil(out)
        XCTAssertEqual(out!.samples.count, 1024)
        XCTAssertTrue(out!.samples.allSatisfy { $0 == 0 })
    }

    func testOnsetPrependsPreSpeechRealAudio() {
        // window0 = non-speech (buffered + emits zeros), window1 = speech onset
        // (flush buffered real window0 + real window1). Emitted = 512 zeros +
        // 512 real (w0) + 512 real (w1) = 1536 samples.
        let src = VADGatedSource(inner: MockAudioSource(),
                                 detector: ScriptedSpeechDetector(decisions: [false, true]))
        let out = src.process(samples(0.5, 1024))
        XCTAssertNotNil(out)
        XCTAssertEqual(out!.samples.count, 1536)
        let nonZero = out!.samples.filter { $0 != 0 }.count
        XCTAssertEqual(nonZero, 1024)   // the two real windows survived
    }

    func testLeftoverCarriesAcrossCalls() {
        let src = VADGatedSource(inner: MockAudioSource(),
                                 detector: ScriptedSpeechDetector(decisions: [false, false]))
        XCTAssertNil(src.process(samples(0.0, 300)))    // 300 buffered, no window
        let out = src.process(samples(0.0, 300))         // 600 total -> 1 window
        XCTAssertNotNil(out)
        XCTAssertEqual(out!.samples.count, 512)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' -only-testing:NemoNoiseTests/VADGatedSourceTests -quiet 2>&1 | tail -25
```
Expected: FAIL — "cannot find 'VADGatedSource' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `NemoNoise/Services/Audio/VAD/VADGatedSource.swift`:

```swift
import Foundation

/// `AudioSource` decorator that runs voice-activity gating between a real
/// source and the ASR engine. Slices `inner`'s variable-length chunks into
/// fixed `windowSize` windows, asks the detector whether each is speech, runs
/// `VADGate`, and re-emits gated audio as `AudioChunk`s.
///
/// Engine-agnostic and pipeline-transparent: swap `MicAudioSource()` for
/// `VADGatedSource(inner: MicAudioSource(), detector: …)` — nothing else changes.
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
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/Services/Audio/VAD/VADGatedSource.swift NemoNoiseTests/VADGatedSourceTests.swift
git commit -m "feat(vad): add VADGatedSource AudioSource decorator"
```

---

### Task 4: `SileroSpeechDetector` — sherpa-onnx Silero VAD wrapper

Real detector backing `VADSpeechDetector` with sherpa's `SherpaOnnxVoiceActivityDetector`. No unit test (requires the model + audio); verified by compile + manual QA in Task 6. Mirrors the `OpaquePointer` pattern of `SherpaOfflinePunctuator` (no bridging-header change needed).

**Files:**
- Create: `NemoNoise/Services/Audio/VAD/SileroSpeechDetector.swift`

- [ ] **Step 1: Write the implementation**

Create `NemoNoise/Services/Audio/VAD/SileroSpeechDetector.swift`:

```swift
import Foundation

/// `VADSpeechDetector` backed by sherpa-onnx's Silero voice activity detector.
///
/// sherpa's VAD C API is segment-level and exposes no per-frame probability,
/// but `SherpaOnnxVoiceActivityDetectorDetected()` returns a real-time
/// "currently in speech" flag computed by Silero — exactly what the gate needs.
/// We feed one `windowSize` window per call, discard the completed-segment
/// queue (we don't use it here; clearing prevents unbounded growth), and read
/// the live flag.
final class SileroSpeechDetector: VADSpeechDetector, @unchecked Sendable {
    private let vad: OpaquePointer
    let windowSize: Int

    /// - Parameter modelPath: Path to `silero_vad.onnx`.
    init?(modelPath: String, windowSize: Int = 512) {
        var created: OpaquePointer?
        modelPath.withCString { cModel in
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

            // Second arg is the detector's internal ring-buffer length in
            // seconds; 30 s matches sherpa's own examples.
            created = SherpaOnnxCreateVoiceActivityDetector(&config, 30.0)
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
```

- [ ] **Step 2: Verify it compiles (no test target yet)**

Run a build of the app target:
```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -quiet 2>&1 | tail -25
```
Expected: `** BUILD SUCCEEDED **`. If the compiler reports an unknown field on `SherpaOnnxSileroVadModelConfig` / `SherpaOnnxVadModelConfig`, open
`NemoNoise/Resources/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers/sherpa-onnx/c-api/c-api.h`
(struct defs near line 1848 / 1920) and match the exact field names.

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/Services/Audio/VAD/SileroSpeechDetector.swift
git commit -m "feat(vad): add SileroSpeechDetector wrapping sherpa VAD"
```

---

### Task 5: Register the Silero VAD model in `ModelManager`

Add a `.sileroVad` descriptor so the model can be downloaded and located.

**Files:**
- Modify: `NemoNoise/Services/ModelManagement/ModelManager.swift` (descriptor extension ~line 123–186; `allDescriptors` ~line 200)
- Test: `NemoNoiseTests/ModelManagerTests.swift` (append)

- [ ] **Step 1: Verify the model URL resolves**

```bash
curl -sIL "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx" | grep -iE "HTTP/|content-length|location" | tail -5
```
Expected: a final `HTTP/.. 200` and a non-trivial `content-length` (~2 MB). If it 404s, get the current `silero_vad.onnx` asset URL from the sherpa-onnx VAD docs (https://k2-fsa.github.io/sherpa-onnx/) and use that in Step 3 instead.

- [ ] **Step 2: Write the failing test**

Append to `NemoNoiseTests/ModelManagerTests.swift` (inside the existing `final class ModelManagerTests`):

```swift
    func testSileroVadDescriptorIsRegistered() {
        let ids = ModelManager.allDescriptors.map(\.id)
        XCTAssertTrue(ids.contains("silero-vad"))
    }

    func testSileroVadDescriptorRequiresOnnxFile() {
        let d = ModelDescriptor.sileroVad
        XCTAssertEqual(d.subdir, "silero-vad")
        XCTAssertEqual(d.requiredItems, ["silero_vad.onnx"])
    }
```

- [ ] **Step 3: Run test to verify it fails**

Run:
```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' -only-testing:NemoNoiseTests/ModelManagerTests -quiet 2>&1 | tail -25
```
Expected: FAIL — "type 'ModelDescriptor' has no member 'sileroVad'".

- [ ] **Step 4: Write minimal implementation**

In `ModelManager.swift`, add to the `extension ModelDescriptor` block (after `.qwen3`):

```swift
    static let sileroVad = ModelDescriptor(
        id: "silero-vad",
        displayName: "Silero VAD",
        detail: "Voice activity detection · cleaner input, no clipped onsets",
        downloadSize: "~2 MB",
        subdir: "silero-vad",
        files: [
            (name: "silero_vad.onnx", url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!),
        ]
    )
```

Then extend `allDescriptors`:

```swift
    static let allDescriptors: [ModelDescriptor] = [.senseVoice, .paraformer, .punctuation, .qwen3, .sileroVad]
```

- [ ] **Step 5: Run test to verify it passes**

Run the Step 3 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add NemoNoise/Services/ModelManagement/ModelManager.swift NemoNoiseTests/ModelManagerTests.swift
git commit -m "feat(vad): register Silero VAD model descriptor"
```

---

### Task 6: Wire `VADGatedSource` into the dictation pipeline

Swap `MicAudioSource()` for the gated source in `PipelineProvider`, choosing Silero when the model is present and energy otherwise.

**Files:**
- Modify: `NemoNoise/App/PipelineProvider.swift` (`applyDictation`, ~line 90–120; add a private helper)

- [ ] **Step 1: Add the source-building helper**

In `PipelineProvider`, add this private method (place it near `makePunctuator`):

```swift
    /// Builds the dictation audio source wrapped in voice-activity gating.
    /// Uses Silero when its model is downloaded; falls back to energy gating
    /// (still better than no VAD) and logs the degradation.
    private func makeGatedMicSource() -> any AudioSource {
        let detector: any VADSpeechDetector
        if let dir = modelManager.modelPath(for: .sileroVad),
           let silero = SileroSpeechDetector(modelPath: dir.appendingPathComponent("silero_vad.onnx").path) {
            detector = silero
            LogService.info("Dictation VAD: Silero", category: "PipelineProvider")
        } else {
            detector = EnergySpeechDetector()
            LogService.warn("Silero VAD model unavailable; using energy gate", category: "PipelineProvider")
        }
        return VADGatedSource(inner: MicAudioSource(), detector: detector)
    }
```

- [ ] **Step 2: Use it in `applyDictation`**

In `applyDictation(result:fallback:punctuator:)`, change the pipeline construction's source from `MicAudioSource()` to the gated source:

```swift
                let pipeline = TranscriptionPipeline(
                    source: makeGatedMicSource(),
                    engine: build.engine,
                    postProcessors: postProcessors,
                    sink: OverlayProgressSink(target: recordingController),
                    fallback: fallback
                )
```

(Only that one line — `source:` — changes. `rebuildDictation()` already routes through `applyDictation`, so it inherits the gate automatically.)

- [ ] **Step 2b: Expose Silero VAD for download in Settings**

`SettingsView.engineTab` hardcodes which model rows show. Without a row for Silero VAD the user can never download it and the gate is stuck on the energy fallback. `modelSection(for:)` is generic, so add one always-visible row next to punctuation. In `NemoNoise/UI/Settings/SettingsView.swift`, after `modelSection(for: .punctuation)`:

```swift
            modelSection(for: .punctuation)
            modelSection(for: .sileroVad)
```

- [ ] **Step 3: Build + run the full test suite**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -quiet 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` (all existing + new VAD tests pass; nothing regressed).

- [ ] **Step 4: Manual QA (real device — the only way to verify VAD quality)**

Run the app. With the **Silero model downloaded**:
1. Start dictation, stay silent ~3 s, then speak. Confirm: no hallucinated text appears during the silence; the first syllable of your speech is not clipped.
2. Dictate with background music/keyboard noise during pauses. Confirm: noise no longer produces stray words.
3. Using the **Paraformer (streaming)** engine, confirm "stop talking → it auto-finalizes the sentence" still works (endpoint detection not broken by gating).
4. Delete the Silero model (Settings → models) and repeat (1): confirm it still records (energy fallback), logs "using energy gate", and doesn't crash.

Record results in the commit message.

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/App/PipelineProvider.swift
git commit -m "feat(vad): gate dictation mic input through VAD (Silero + energy fallback)"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- VAD core (Silero confidence) → Tasks 1, 4. ✅
- Noise gating (zero non-speech, preserve endpointing) → Task 2 (`VADGate`) + Task 6 (wiring). ✅
- Pre-speech buffer (no clipped onset) → Task 2 (onset flush) + tests. ✅
- Applies to all engines, pipeline/protocol unchanged → Task 6 (source swap only). ✅
- Energy fallback when model missing → Task 1 + Task 6 (degradation path). ✅
- `.sileroVad` model descriptor → Task 5. ✅
- IO-free unit tests → Tasks 1, 2, 3, 5. ✅
- Per-frame-probability spike → resolved in spec addendum (Bool detector via `Detected()`); Task 4 implements it. ✅

**Type consistency:** `VADSpeechDetector` (windowSize/isSpeech/reset), `VADConfig` (windowSize/preSpeechWindows/energyThreshold), `VADGate.step(window:isSpeech:) -> [[Float]]`, `VADGatedSource.process(_:) -> AudioChunk?` — names match across Tasks 1–6 and the test doubles.

**Placeholder scan:** none — every code/test step is complete; the one external unknown (model URL) has an explicit `curl` verification step with a fallback instruction.

**Out of scope (Phase 2, not in this plan):** offline-engine full segmentation (`VADSegmentingEngine`), translation-pipeline gating, user-tunable VAD settings UI.
