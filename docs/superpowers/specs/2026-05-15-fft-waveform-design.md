# FFT Waveform Visualizer — Design

**Date:** 2026-05-15
**Status:** Draft (awaiting user review)
**Scope:** Replace the RMS-scalar-driven fake waveforms with a real FFT
frequency spectrum visualizer, used by both the dictation HUD and the
translation subtitle overlay.

## Why

Current waveforms are inaccurate and visually static:

- A single RMS scalar (`MicAudioSource.swift:58`) drives all 16 HUD bars
  identically. Bar-to-bar variation comes from `sin(index)` constants and
  `Date()` reads inside `body` — neither animates predictably.
- The subtitle's 5-bar waveform applies `1 - index * 0.12` attenuation to the
  same scalar, producing a fixed monotone shape that just scales with volume.
- Without a time or frequency dimension, the visualizer can't communicate
  "the system is listening" vs. "the system received an unintelligible blob."

A real FFT spectrum (16 log-spaced bins, 80Hz–4kHz) gives each bar an
independent, audio-derived value, making the visualization honest and
diagnostic.

## Architecture

```
MicAudioSource.processTap ── RMS + FFT spectrum (16 log-spaced bins, [0,1])
    │
    ▼
AudioChunk { samples, rmsLevel, spectrum: [Float] }
    │
    ▼
TranscriptionPipeline
    │
    ▼
PipelineEvent
  .level(rms: Float, spectrum: [Float])              (was .rms(Float))
  .partial(result, rms: Float, spectrum: [Float])    (was .partial(_, rmsLevel:))
  .final / .engineFallback                           unchanged
    │
    ▼
RecordingController / TranslationController
    var micLevel: Float                              (current RMS, unchanged)
    var spectrum: [Float]                            (NEW — envelope-smoothed)
    │
    ▼ on each .level event: envelope follower (attack 60ms / release 200ms)
    │
    ▼
SpectrumBarsView(spectrum, isActive, barCount)        ← shared by HUD & subtitle
```

FFT lives where RMS already lives — in the audio source's `processTap`. This
keeps the pipeline's contract simple: "audio chunks carry levels," and adds
no new infrastructure layers.

## Components

### 1. `SpectrumAnalyzer` — `NemoNoise/Services/Audio/SpectrumAnalyzer.swift` (new)

```swift
final class SpectrumAnalyzer {
    init(binCount: Int = 16, sampleRate: Float = 16000)
    func analyze(_ samples: [Float]) -> [Float]   // length == binCount, range [0, 1]
}
```

**Algorithm:**

1. **Hann window** the input samples. Reduces spectral leakage.
2. **Resize to 1024 samples** — zero-pad if shorter, truncate if longer.
   At 16kHz this gives ~15.6Hz frequency resolution.
3. **Forward real FFT** via `vDSP` (single-precision). The FFT setup
   (`vDSP_create_fftsetup` / `vDSP.FFT`) is allocated once at init and reused.
4. **Magnitudes** = √(re² + im²) for each of the 512 useful bins.
5. **dB conversion**: `20 * log10(max(mag, 1e-7))`, clamped to [-60, 0] dB.
6. **Log-frequency aggregation**: split [80Hz, 4000Hz] into `binCount` log-spaced
   bands. Each output bin = max of FFT bins falling in that band.
7. **Normalize**: linearly map [-60 dB, 0 dB] → [0, 1].

**Why max (not mean) across constituent FFT bins:** speech has narrow
transient peaks (formants); averaging blurs them and dampens the visual.

**Thread safety:** `analyze(_:)` is called from `nonisolated` audio tap
context. The `vDSP` setup is immutable after init, so the analyzer is
safe to call from any thread without locks — but should be owned by a
single audio source (don't share across sources).

**Tests (`NemoNoiseTests/SpectrumAnalyzerTests.swift`):**

- 100Hz sine wave → bin 0 has the highest magnitude
- 2000Hz sine wave → bin ~13 has the highest magnitude (within ±1)
- Silence (all zeros) → all bins < 0.05
- White noise → all bins roughly equal (within 0.3 of each other)
- Returned array length always equals `binCount`

### 2. `AudioChunk` extension — `NemoNoise/Services/Audio/MicAudioSource.swift`

```swift
struct AudioChunk: Sendable {
    let samples: [Float]
    let rmsLevel: Float
    let spectrum: [Float]      // NEW
}
```

Both `MicAudioSource` and `SystemAudioSource` instantiate a `SpectrumAnalyzer`
once and call `analyze(samples)` alongside the existing RMS computation in
`processTap`.

### 3. `PipelineEvent` rewrite — `NemoNoise/Services/Pipeline/PipelineEvent.swift`

**Before:**
```swift
case partial(TranscriptionResult, rmsLevel: Float)
case rms(Float)
```

**After:**
```swift
case partial(TranscriptionResult, rms: Float, spectrum: [Float])
case level(rms: Float, spectrum: [Float])
```

`.final` and `.engineFallback` unchanged.

`.rms` and `.partial(_, rmsLevel:)` are only consumed by `RecordingController`
and `TranslationController` for UI state. No sinks, services, or pipeline
internals read them, so this rename is safe.

### 4. `TranscriptionPipeline` — `Services/Pipeline/TranscriptionPipeline.swift`

The pipeline currently yields `.rms(chunk.rmsLevel)` and
`.partial(result, rmsLevel: chunk.rmsLevel)` (lines 69 and 71). Update to
yield `chunk.spectrum` alongside.

### 5. Controllers — `App/RecordingController.swift` & `App/TranslationController.swift`

Both gain:

```swift
var spectrum: [Float] = Array(repeating: 0, count: 16)
```

Each `.level` and `.partial` event triggers an envelope follower:

```swift
private func applyEnvelope(_ target: [Float]) {
    let dt: Float = 0.085         // approx chunk period @ 16kHz / 4096
    let attack: Float = 0.06
    let release: Float = 0.20
    for i in 0..<min(spectrum.count, target.count) {
        let tau = target[i] > spectrum[i] ? attack : release
        let alpha = 1 - exp(-dt / tau)
        spectrum[i] += (target[i] - spectrum[i]) * alpha
    }
}
```

**Why this is in the controller, not the view:** the envelope state is part
of the audio observation — multiple views might share it (HUD + menubar +
subtitle), so we want a single source of truth. Putting it in the controller
also keeps the view declarative.

**Why fixed `dt = 0.085`:** chunks arrive at variable rate depending on hardware
buffer size, but the audio source's resampling target makes ~85ms the practical
average. Using a fixed dt simplifies math; the small variability is absorbed
by the view's `.animation` interpolation.

### 6. `SpectrumBarsView` — `NemoNoise/UI/Overlay/SpectrumBarsView.swift` (new)

```swift
struct SpectrumBarsView: View {
    let spectrum: [Float]
    let isActive: Bool
    let barCount: Int
    var barColor: Color = .accentColor
    var barSpacing: CGFloat = 3
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 24
    var minHeight: CGFloat = 3
}
```

**Body:**

```swift
HStack(alignment: .center, spacing: barSpacing) {
    ForEach(0..<barCount, id: \.self) { i in
        Capsule()
            .fill(isActive ? barColor : Color.secondary.opacity(0.3))
            .frame(width: barWidth, height: barHeight(at: i))
    }
}
.frame(height: maxHeight)
.animation(.easeOut(duration: 0.08), value: spectrum)
```

**Bar height function:**
```swift
private func barHeight(at index: Int) -> CGFloat {
    guard isActive, !spectrum.isEmpty else { return minHeight }
    let sourceIdx = downsample(index, sourceCount: spectrum.count, targetCount: barCount)
    let v = CGFloat(spectrum[sourceIdx])
    return minHeight + v * (maxHeight - minHeight)
}
```

**Downsampling** `spectrum.count` → `barCount`:
- If equal, identity
- If `barCount < spectrum.count` (e.g., 5 from 16), each output bar's source
  index is `index * (spectrum.count / barCount)`. Spectrum is already log-binned
  in audio source, so further sparse sampling is acceptable.

### 7. View migrations

**`OverlayView.swift`:** replace
```swift
LiveWaveformView(micLevel: controller.micLevel, isRecording: ...)
```
with
```swift
SpectrumBarsView(
    spectrum: controller.spectrum,
    isActive: controller.recordingState == .recording,
    barCount: 16
)
```
Drop the surrounding `.animation(.interactiveSpring..., value: controller.micLevel)`
(animation moves inside `SpectrumBarsView`).

**`SubtitleOverlayView.swift`:** replace the inline 5-bar `HStack` (lines 73-82)
with:
```swift
SpectrumBarsView(
    spectrum: controller.spectrum,
    isActive: controller.translationState == .capturing,
    barCount: 5,
    barColor: .green
)
```
Remove `waveformBarHeight(index:)` (lines 110-117) — obsolete.

**Delete** `NemoNoise/UI/Overlay/LiveWaveformView.swift` — fully replaced.

**Out of scope:** `MenubarView.swift` waveform (lines 124-132). Leave it on
`micLevel` for now; menubar is glanceable and a single-scalar bar still works.
Migrate in a separate change if desired.

## Files Touched

| File | Status |
|---|---|
| `NemoNoise/Services/Audio/SpectrumAnalyzer.swift` | New |
| `NemoNoiseTests/SpectrumAnalyzerTests.swift` | New |
| `NemoNoise/Services/Audio/MicAudioSource.swift` | Add spectrum to `AudioChunk`; compute FFT |
| `NemoNoise/Services/Audio/SystemAudioSource.swift` | Compute FFT |
| `NemoNoise/Services/Pipeline/PipelineEvent.swift` | `.rms` → `.level`; `.partial` carries spectrum |
| `NemoNoise/Services/Pipeline/TranscriptionPipeline.swift` | Forward spectrum |
| `NemoNoise/App/RecordingController.swift` | Add `spectrum` + envelope follower |
| `NemoNoise/App/TranslationController.swift` | Add `spectrum` + envelope follower |
| `NemoNoise/UI/Overlay/SpectrumBarsView.swift` | New |
| `NemoNoise/UI/Overlay/LiveWaveformView.swift` | Delete |
| `NemoNoise/UI/Overlay/OverlayView.swift` | Use SpectrumBarsView |
| `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift` | Use SpectrumBarsView |

**Not touched:** `MenubarView.swift`, all sinks, all engines, window controllers,
`OnboardingView`, settings.

## Risk & Verification

**Risk: FFT correctness**. Mitigated by unit tests on `SpectrumAnalyzer`
(known-frequency sine waves should peak in known bins).

**Risk: Performance**. 1024-point single-precision FFT via vDSP is <100µs per
chunk; chunks arrive at ~12Hz. Total CPU cost <0.1%. Negligible.

**Risk: PipelineEvent breaking changes**. The pipeline test
(`TranscriptionPipelineTests.swift`) almost certainly pattern-matches `.rms`
and `.partial`. Will need updates as part of the change. Confirmed during
implementation, not before — the test will fail and tell us where.

**Risk: Envelope tuning**. The 60/200ms attack/release are reasonable
starting values but may feel sluggish or jittery. Spec authorizes tuning
inline up to ±50ms either direction without further sign-off.

## Out of Scope

- Spectrogram (2D time × frequency) — that's a different visualization.
- Peak-hold dots above each bar — could be a future small addition.
- Per-bar color gradient (e.g., low freq red → high freq blue) — possible
  later, not core to "look real."
- Migrating menubar waveform.
- Adapting `LiveWaveformView.swift`'s existing gradient style — the new
  `SpectrumBarsView` uses a flat color; gradient can be added if requested.
