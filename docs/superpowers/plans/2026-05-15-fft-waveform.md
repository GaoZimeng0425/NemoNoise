# FFT Waveform Visualizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace RMS-scalar fake waveforms with a real 16-bin FFT spectrum visualizer, shared between the dictation HUD and translation subtitle overlays.

**Architecture:** FFT is computed once per audio chunk inside `MicAudioSource` and `SystemAudioSource` (alongside the existing RMS calculation), carried through `AudioChunk` and pipeline events, smoothed by an attack/release envelope in the controllers, and rendered by a new `SpectrumBarsView` view shared by both overlays.

**Tech Stack:** Swift, `vDSP` (Apple Accelerate framework) for FFT, SwiftUI for rendering, XCTest for unit tests.

**Reference spec:** `docs/superpowers/specs/2026-05-15-fft-waveform-design.md`

**File map:**

| Path | Status | Responsibility |
|---|---|---|
| `NemoNoise/Services/Audio/SpectrumAnalyzer.swift` | Create | Pure FFT + log-bin aggregation |
| `NemoNoiseTests/SpectrumAnalyzerTests.swift` | Create | Sine/silence/noise tests |
| `NemoNoise/Services/Audio/MicAudioSource.swift` | Modify | Add spectrum to AudioChunk; instantiate analyzer |
| `NemoNoise/Services/Audio/SystemAudioSource.swift` | Modify | Instantiate analyzer; emit chunks with spectrum |
| `NemoNoise/Services/Pipeline/PipelineEvent.swift` | Modify | `.rms` → `.level`; `.partial` carries spectrum |
| `NemoNoise/Services/Pipeline/TranscriptionPipeline.swift` | Modify | Yield new event shapes |
| `NemoNoiseTests/TranscriptionPipelineTests.swift` | Modify | Update pattern matches |
| `NemoNoise/App/RecordingController.swift` | Modify | Add `spectrum` + envelope follower |
| `NemoNoise/App/TranslationController.swift` | Modify | Same |
| `NemoNoise/UI/Overlay/SpectrumBarsView.swift` | Create | Shared bar renderer |
| `NemoNoise/UI/Overlay/LiveWaveformView.swift` | Delete | Replaced |
| `NemoNoise/UI/Overlay/OverlayView.swift` | Modify | Use SpectrumBarsView (16 bars) |
| `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift` | Modify | Use SpectrumBarsView (5 bars) |

---

## Task 1: `SpectrumAnalyzer` + unit tests (TDD)

**Files:**
- Create: `NemoNoise/Services/Audio/SpectrumAnalyzer.swift`
- Test: `NemoNoiseTests/SpectrumAnalyzerTests.swift`

Pure FFT logic with no audio-engine coupling. Test-first.

- [ ] **Step 1: Write the failing test file**

Create `NemoNoiseTests/SpectrumAnalyzerTests.swift`:

```swift
import XCTest
@testable import NemoNoise

final class SpectrumAnalyzerTests: XCTestCase {
    private let sampleRate: Float = 16000
    private let binCount = 16

    func makeSine(freq: Float, duration: Float = 0.1, amplitude: Float = 0.5) -> [Float] {
        let count = Int(sampleRate * duration)
        let twoPi = 2 * Float.pi
        return (0..<count).map { i in
            amplitude * sin(twoPi * freq * Float(i) / sampleRate)
        }
    }

    func testReturnsBinCountElements() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let result = analyzer.analyze(makeSine(freq: 1000))
        XCTAssertEqual(result.count, binCount)
    }

    func testSilenceIsNearZero() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let silence = Array<Float>(repeating: 0, count: 1024)
        let result = analyzer.analyze(silence)
        for (i, v) in result.enumerated() {
            XCTAssertLessThan(v, 0.05, "bin \(i) should be near 0 for silence, got \(v)")
        }
    }

    func testLowFrequencyDominatesLowBin() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let result = analyzer.analyze(makeSine(freq: 100))
        guard let maxIdx = result.indices.max(by: { result[$0] < result[$1] }) else {
            return XCTFail("empty result")
        }
        XCTAssertLessThanOrEqual(maxIdx, 2, "100Hz sine should peak in bin 0-2, got \(maxIdx)")
    }

    func testMidFrequencyDominatesMidBin() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let result = analyzer.analyze(makeSine(freq: 1000))
        guard let maxIdx = result.indices.max(by: { result[$0] < result[$1] }) else {
            return XCTFail("empty result")
        }
        XCTAssertGreaterThanOrEqual(maxIdx, 6, "1kHz sine should peak in middle bins, got \(maxIdx)")
        XCTAssertLessThanOrEqual(maxIdx, 12, "1kHz sine should peak in middle bins, got \(maxIdx)")
    }

    func testHighFrequencyDominatesHighBin() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let result = analyzer.analyze(makeSine(freq: 3000))
        guard let maxIdx = result.indices.max(by: { result[$0] < result[$1] }) else {
            return XCTFail("empty result")
        }
        XCTAssertGreaterThanOrEqual(maxIdx, 12, "3kHz sine should peak in upper bins, got \(maxIdx)")
    }

    func testShortInputIsPadded() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        // 100 samples is much less than the 1024 FFT size — analyzer must pad.
        let result = analyzer.analyze(makeSine(freq: 1000, duration: 0.006))
        XCTAssertEqual(result.count, binCount)
    }

    func testValuesStayInZeroOneRange() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let loud = makeSine(freq: 500, amplitude: 0.95)
        let result = analyzer.analyze(loud)
        for v in result {
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/SpectrumAnalyzerTests 2>&1 | tail -30
```

Expected: build failure with "cannot find 'SpectrumAnalyzer' in scope".

- [ ] **Step 3: Create the analyzer**

Create `NemoNoise/Services/Audio/SpectrumAnalyzer.swift`:

```swift
import Accelerate
import Foundation

/// Computes a frequency-domain spectrum from audio samples.
///
/// Output is `binCount` log-spaced magnitude values in [0, 1], covering
/// 80Hz to 4kHz. Designed for speech visualization.
final class SpectrumAnalyzer {
    private let binCount: Int
    private let sampleRate: Float
    private let fftSize: Int = 1024
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    private let bandEdges: [Int]  // FFT bin indices marking band boundaries

    private let minDb: Float = -60
    private let maxDb: Float = 0
    private let lowFreq: Float = 80
    private let highFreq: Float = 4000

    init(binCount: Int = 16, sampleRate: Float = 16000) {
        self.binCount = binCount
        self.sampleRate = sampleRate
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = hann

        // Map log-spaced [lowFreq, highFreq] into FFT bin indices.
        let nyquist = sampleRate / 2
        let binHz = nyquist / Float(fftSize / 2)
        var edges: [Int] = []
        let logLow = log(lowFreq)
        let logHigh = log(highFreq)
        for i in 0...binCount {
            let f = exp(logLow + (logHigh - logLow) * Float(i) / Float(binCount))
            edges.append(min(fftSize / 2 - 1, max(1, Int(f / binHz))))
        }
        self.bandEdges = edges
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func analyze(_ samples: [Float]) -> [Float] {
        // 1. Resize to fftSize: pad with zeros or truncate.
        var buffer = [Float](repeating: 0, count: fftSize)
        let copyCount = min(samples.count, fftSize)
        for i in 0..<copyCount {
            buffer[i] = samples[i]
        }

        // 2. Apply Hann window.
        vDSP_vmul(buffer, 1, window, 1, &buffer, 1, vDSP_Length(fftSize))

        // 3. Pack into split-complex form for vDSP real FFT.
        let halfSize = fftSize / 2
        var realp = [Float](repeating: 0, count: halfSize)
        var imagp = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var splitComplex = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buffer.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { cp in
                        vDSP_ctoz(cp, 2, &splitComplex, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // 4. Magnitudes are now squared. sqrt to get linear magnitude.
        var sqrtMags = [Float](repeating: 0, count: halfSize)
        var count = Int32(halfSize)
        vvsqrtf(&sqrtMags, magnitudes, &count)

        // 5. Aggregate FFT bins into log-spaced bands; take max per band.
        var output = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            let lo = bandEdges[i]
            let hi = max(lo + 1, bandEdges[i + 1])
            var peak: Float = 0
            for j in lo..<hi where j < halfSize {
                if sqrtMags[j] > peak { peak = sqrtMags[j] }
            }
            // dB conversion + normalize to [0, 1].
            let db = 20 * log10(max(peak, 1e-7))
            let clamped = min(maxDb, max(minDb, db))
            output[i] = (clamped - minDb) / (maxDb - minDb)
        }
        return output
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/SpectrumAnalyzerTests 2>&1 | tail -30
```

Expected: `Test Suite 'SpectrumAnalyzerTests' passed` with 7 tests, 0 failures.

If a test fails (e.g. the frequency-bin assertion is off by one), iterate on the
band-edge math. The peak-bin assertions allow some tolerance (`maxIdx <= 2` for
100Hz, `6..12` for 1kHz, `>= 12` for 3kHz) precisely because exact bin placement
depends on the log-spacing math.

- [ ] **Step 5: Commit**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && git add NemoNoise/Services/Audio/SpectrumAnalyzer.swift NemoNoiseTests/SpectrumAnalyzerTests.swift && git commit -m "feat(audio): add SpectrumAnalyzer for FFT-based bin magnitudes

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `AudioChunk` carries spectrum; audio sources compute it

**Files:**
- Modify: `NemoNoise/Services/Audio/MicAudioSource.swift`
- Modify: `NemoNoise/Services/Audio/SystemAudioSource.swift`

- [ ] **Step 1: Extend `AudioChunk` and `MicAudioSource`**

In `NemoNoise/Services/Audio/MicAudioSource.swift`:

Update the struct:
```swift
struct AudioChunk: Sendable {
    let samples: [Float]
    let rmsLevel: Float
    let spectrum: [Float]
}
```

Add a stored analyzer property to `MicAudioSource`:
```swift
final class MicAudioSource: AudioSource, Sendable {
    private let engine = AVAudioEngine()
    private let continuation: ContinuationBox = ContinuationBox()
    private let targetSampleRate: Double = 16000
    private let bufferSize: AVAudioFrameCount = 4096
    private let analyzer = SpectrumAnalyzer(binCount: 16, sampleRate: 16000)
    // ...
}
```

Update `processTap` to compute spectrum:
```swift
nonisolated private func processTap(buffer: AVAudioPCMBuffer, resampler: AudioResampler) {
    guard let samples = resampler.resample(buffer: buffer) else { return }
    let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    let spectrum = analyzer.analyze(samples)
    continuation.value?.yield(AudioChunk(samples: samples, rmsLevel: rms, spectrum: spectrum))
}
```

(`SpectrumAnalyzer` is a final class — fine to capture in a nonisolated method
since `analyze(_:)` only reads immutable internal state plus its own local stack
buffers. No data race.)

- [ ] **Step 2: Update `SystemAudioSource`**

Open `NemoNoise/Services/Audio/SystemAudioSource.swift`. It also constructs `AudioChunk` after computing RMS. Mirror the change:

```swift
private let analyzer = SpectrumAnalyzer(binCount: 16, sampleRate: 16000)
```

And in whatever method emits the chunk (around line 72-73), update:
```swift
let rms = sqrt(resampled.reduce(0) { $0 + $1 * $1 } / Float(max(resampled.count, 1)))
let spectrum = analyzer.analyze(resampled)
continuationBox.value?.yield(AudioChunk(samples: resampled, rmsLevel: rms, spectrum: spectrum))
```

- [ ] **Step 3: Build**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

If the compiler complains about `AudioChunk(samples:, rmsLevel:)` calls elsewhere (e.g. in `MockAudioSource.swift` for tests), update those callers to include `spectrum: []` (empty array is fine for mocks until Task 3 addresses tests).

- [ ] **Step 4: Run existing audio-related tests**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/AudioCaptureTests -only-testing:NemoNoiseTests/AudioSourceConformanceTests 2>&1 | tail -20
```

Expected: tests pass (or update them if they construct `AudioChunk` directly with the old initializer).

- [ ] **Step 5: Commit**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && git add NemoNoise/Services/Audio/ NemoNoiseTests/ && git commit -m "feat(audio): emit FFT spectrum on each AudioChunk

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `PipelineEvent` reshape

**Files:**
- Modify: `NemoNoise/Services/Pipeline/PipelineEvent.swift`
- Modify: `NemoNoise/Services/Pipeline/TranscriptionPipeline.swift`
- Modify: `NemoNoiseTests/TranscriptionPipelineTests.swift` (likely)

- [ ] **Step 1: Rewrite `PipelineEvent`**

Replace `NemoNoise/Services/Pipeline/PipelineEvent.swift`:

```swift
import Foundation

/// Events emitted by a running TranscriptionPipeline.
///
/// Consumers (controllers) subscribe via `pipeline.start()` and map these to
/// `@Observable` state changes for SwiftUI.
enum PipelineEvent: Sendable {
    /// An intermediate (partial) transcription update plus the current input
    /// level (RMS and frequency spectrum).
    case partial(TranscriptionResult, rms: Float, spectrum: [Float])

    /// Final transcription. Emitted from `finalize()`. The result has already
    /// been delivered to every sink before this event is yielded.
    case final(TranscriptionResult)

    /// Pipeline switched from primary engine to fallback mid-session.
    case engineFallback(from: String)

    /// Input-level update with no transcription text. Use for waveform UI when
    /// the engine produced no new text in this chunk.
    case level(rms: Float, spectrum: [Float])
}
```

- [ ] **Step 2: Update `TranscriptionPipeline` to yield new event shapes**

In `NemoNoise/Services/Pipeline/TranscriptionPipeline.swift` around lines 69 and 71, replace:
```swift
continuation.yield(.rms(chunk.rmsLevel))
continuation.yield(.partial(result, rmsLevel: chunk.rmsLevel))
```

with:
```swift
continuation.yield(.level(rms: chunk.rmsLevel, spectrum: chunk.spectrum))
continuation.yield(.partial(result, rms: chunk.rmsLevel, spectrum: chunk.spectrum))
```

- [ ] **Step 3: Update `TranscriptionPipelineTests`**

In `NemoNoiseTests/TranscriptionPipelineTests.swift`, search for any pattern matches on `.rms(` or `.partial(_, rmsLevel:`. Update to the new shapes:

```swift
case .level(let rms, _):
    // ...
case .partial(let result, let rms, _):
    // ...
```

If the test constructs events directly (e.g. for table-driven tests), construct with the new fields.

- [ ] **Step 4: Build**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: BUILD SUCCEEDED. Compile errors are likely in `RecordingController` and `TranslationController` which still pattern-match the old `.rms(let level)` / `.partial(_, let rms)`. That's the next task.

If the build fails ONLY in controllers, proceed to Task 4 to fix them. If it fails elsewhere, address those callers first.

- [ ] **Step 5: Commit (incremental — controllers fixed in next task)**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && git add NemoNoise/Services/Pipeline/ NemoNoiseTests/TranscriptionPipelineTests.swift && git commit -m "refactor(pipeline): replace .rms event with .level (rms + spectrum)

Controllers still pattern-match the old shapes — fixed in next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

(This commit intentionally leaves a broken tree. The next task lands within a few minutes and restores compile. Don't push until both commits are in.)

---

## Task 4: Controllers — spectrum state + envelope follower

**Files:**
- Modify: `NemoNoise/App/RecordingController.swift`
- Modify: `NemoNoise/App/TranslationController.swift`

- [ ] **Step 1: Update `RecordingController`**

In `NemoNoise/App/RecordingController.swift`:

Add the spectrum property near `micLevel` (line 14):
```swift
var micLevel: Float = 0
var spectrum: [Float] = Array(repeating: 0, count: 16)
```

Replace the `for try await event in pipeline.start()` switch (around lines 163-178). The old block matched `.partial(_, let rms)` and `.rms(let level)`. New version:

```swift
for try await event in pipeline.start() {
    switch event {
    case .partial(_, let rms, let spectrum):
        self.micLevel = rms
        self.applyEnvelope(spectrum)
        self.isListeningSilence = false
        self.resetSilenceTimer()
    case .level(let rms, let spectrum):
        self.micLevel = rms
        self.applyEnvelope(spectrum)
    case .engineFallback(let from):
        self.isStreaming = pipeline.isStreaming
        LogService.info("Engine fallback from \(from)", category: "Recording")
        ToastWindowController.show("Switched to local engine", style: .info)
    case .final:
        break
    }
}
```

Add the envelope helper near the bottom of the class:
```swift
private func applyEnvelope(_ target: [Float]) {
    let dt: Float = 0.085
    let attackTau: Float = 0.06
    let releaseTau: Float = 0.20
    if spectrum.count != target.count {
        spectrum = Array(repeating: 0, count: target.count)
    }
    for i in 0..<spectrum.count {
        let tau = target[i] > spectrum[i] ? attackTau : releaseTau
        let alpha = 1 - exp(-dt / tau)
        spectrum[i] += (target[i] - spectrum[i]) * alpha
    }
}
```

When recording stops (in `stopRecording()` or wherever `micLevel = 0` is reset),
also reset spectrum:
```swift
self.micLevel = 0
self.spectrum = Array(repeating: 0, count: 16)
```

(Check the existing reset locations — typically right after `pipelineTask?.cancel()`. If `micLevel = 0` doesn't appear today, add `spectrum = Array(repeating: 0, count: 16)` adjacent to wherever recording is finalized so the waveform decays cleanly.)

- [ ] **Step 2: Update `TranslationController`**

In `NemoNoise/App/TranslationController.swift`:

Add spectrum property near `audioLevel` (line 11):
```swift
var audioLevel: Float = 0
var spectrum: [Float] = Array(repeating: 0, count: 16)
```

Replace the switch (around lines 57-63):
```swift
for try await event in pipeline.start() {
    switch event {
    case .partial(_, let rms, let spectrum):
        self.audioLevel = rms
        self.applyEnvelope(spectrum)
    case .level(let rms, let spectrum):
        self.audioLevel = rms
        self.applyEnvelope(spectrum)
    case .final, .engineFallback:
        break
    }
}
```

Add the same `applyEnvelope` helper as in Step 1.

Reset spectrum on stop (mirror the change from Step 1).

- [ ] **Step 3: Build**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && git add NemoNoise/App/RecordingController.swift NemoNoise/App/TranslationController.swift && git commit -m "feat(controllers): add spectrum state with attack/release envelope

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `SpectrumBarsView` + migrate overlays; delete `LiveWaveformView`

**Files:**
- Create: `NemoNoise/UI/Overlay/SpectrumBarsView.swift`
- Modify: `NemoNoise/UI/Overlay/OverlayView.swift`
- Modify: `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift`
- Delete: `NemoNoise/UI/Overlay/LiveWaveformView.swift`

- [ ] **Step 1: Create `SpectrumBarsView`**

Create `NemoNoise/UI/Overlay/SpectrumBarsView.swift`:

```swift
import SwiftUI

struct SpectrumBarsView: View {
    let spectrum: [Float]
    let isActive: Bool
    let barCount: Int
    var barColor: Color = .accentColor
    var barSpacing: CGFloat = 3
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 24
    var minHeight: CGFloat = 3

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(isActive ? barColor : Color.secondary.opacity(0.3))
                    .frame(width: barWidth, height: barHeight(at: i))
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.08), value: spectrum)
    }

    private func barHeight(at index: Int) -> CGFloat {
        guard isActive, !spectrum.isEmpty else { return minHeight }
        let sourceIdx = downsampleIndex(target: index)
        let v = CGFloat(spectrum[sourceIdx])
        return minHeight + v * (maxHeight - minHeight)
    }

    private func downsampleIndex(target: Int) -> Int {
        guard barCount > 0 else { return 0 }
        if spectrum.count == barCount { return target }
        let scaled = Int((Double(target) + 0.5) * Double(spectrum.count) / Double(barCount))
        return min(max(scaled, 0), spectrum.count - 1)
    }
}
```

- [ ] **Step 2: Replace `LiveWaveformView` usage in `OverlayView`**

In `NemoNoise/UI/Overlay/OverlayView.swift`, find the `headerBar` definition and the `LiveWaveformView(...)` call inside it. Replace with:

```swift
SpectrumBarsView(
    spectrum: controller.spectrum,
    isActive: controller.recordingState == .recording,
    barCount: 16
)
```

Remove the surrounding `.animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7), value: controller.micLevel)` modifier on the waveform — animation is now inside `SpectrumBarsView`.

- [ ] **Step 3: Replace inline 5-bar waveform in `SubtitleOverlayView`**

In `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift`, find the inner `HStack(alignment: .center, spacing: 2.5) { ForEach(0..<5) ... }` block inside `statusGroup` (currently around lines 73-82). Replace with:

```swift
SpectrumBarsView(
    spectrum: controller.spectrum,
    isActive: controller.translationState == .capturing,
    barCount: 5,
    barColor: .green,
    barSpacing: 2.5,
    barWidth: 3,
    maxHeight: 20,
    minHeight: 3
)
```

Delete `waveformBarHeight(index:)` (around lines 110-117) — no longer used.

- [ ] **Step 4: Delete `LiveWaveformView.swift`**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && rm NemoNoise/UI/Overlay/LiveWaveformView.swift
```

- [ ] **Step 5: Build**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && git add NemoNoise/UI/Overlay/SpectrumBarsView.swift NemoNoise/UI/Overlay/OverlayView.swift NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift && git add -u NemoNoise/UI/Overlay/LiveWaveformView.swift && git commit -m "feat(overlay): replace fake waveforms with shared SpectrumBarsView

Delete LiveWaveformView (16-bar HUD) and the inline 5-bar subtitle
HStack. Both overlays now render the controller's envelope-smoothed
FFT spectrum via SpectrumBarsView.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Full integration verify

**Files:** none modified — verification only.

- [ ] **Step 1: Run the full test suite**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNoise && xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -50
```

Expected: all tests pass — `SpectrumAnalyzerTests`, `TranscriptionPipelineTests` (with updated assertions), and all pre-existing tests.

- [ ] **Step 2: Walk through visual scenarios**

Launch the app, exercise:

1. **HUD with mic input** — start dictation, speak. The 16-bar visualizer should show meaningful per-bar variation that tracks vowel/consonant transitions, not a uniform monotone shape. Vowels (low frequencies) light up lower bars; sibilants (s, sh) light up upper bars.
2. **HUD silence** — stop speaking. Bars should decay smoothly over ~200ms (release tau), not snap to zero.
3. **Subtitle capture** — start translation, speak in English. The 5-bar waveform shows similar speech-driven variation. Green tinted bars.
4. **Subtitle idle** — wait silently inside a capturing session. Bars decay to baseline; status capsule stays green-tinted.
5. **State transitions** — start/stop recording rapidly. No visual glitches or stuck bars.

- [ ] **Step 3: Note any tuning needed**

If attack (60ms) or release (200ms) feels off:
- Sluggish to rise → reduce attack to 30-50ms
- Too jittery → increase release to 250-300ms
- Bars feel "stuck high" → reduce release
- Bars feel "flickery" → increase release or reduce dt to slightly higher value

If any tuning is applied, commit:
```bash
git add NemoNoise/App/RecordingController.swift NemoNoise/App/TranslationController.swift && \
git commit -m "tune(controllers): adjust envelope after visual check

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Implementer notes

- **`vDSP` APIs are C-style.** Pay attention to memory ownership and split-complex packing in `SpectrumAnalyzer`. The provided code uses `withUnsafeMutableBufferPointer` correctly; do not refactor to `withUnsafeBytes` patterns without careful testing.
- **`SpectrumAnalyzer` is a class (not actor or struct)** because vDSP setup is allocated once and reused. `analyze(_:)` is effectively pure (reads immutable members, writes local stack buffers). Calling it from multiple threads is safe as long as each thread has its own analyzer instance — which is the case here (each audio source owns one).
- **Don't add `@available` checks.** Deployment target is macOS 26.4; all APIs used (`vDSP`, `vDSP_hann_window`, etc.) have been available for over a decade.
- **PBXFileSystemSynchronizedRootGroup** in `NemoNoise.xcodeproj` auto-discovers files in `NemoNoise/` and `NemoNoiseTests/`. New files do not need manual target membership configuration (confirmed in the previous Liquid Glass change).
- **Don't include the existing uncommitted change** (if `NemoNoise/UI/Settings/SettingsView.swift` shows as modified, that's separate work — leave it alone). Always stage by explicit file path.
