# Engine Badge in Overlay + Rapid-Tap Bug Fix

Date: 2026-05-17
Status: Approved

## Problem

Two issues, fixed together because they both touch `RecordingController` and `OverlayView`:

1. **No model visibility.** The user cannot tell which ASR engine is actually running. Settings reflects user *choice*, but the running engine may be different (model missing → factory falls back to Apple; mid-session fallback also possible).
2. **Rapid hotkey taps cause UI glitches.** Three reported symptoms:
   - Overlay status flickers (`RECORDING` → `THINKING` → `READY` in rapid succession on a miss-tap).
   - Transcript text from the previous session lingers or contaminates the new one.
   - Second press appears unresponsive (state stuck in `.processing`).

## Goals

- Show the engine currently in use as a small chip in the overlay's top-right.
- Eliminate flicker / text leftover / unresponsiveness when the user taps the hotkey faster than a real utterance.

## Non-goals

- Engine selection UX in Settings (unchanged).
- Toggle-mode behavior (unchanged — toggle is explicit start/stop, not a miss-press hazard).
- Hotkey-level debouncing in `HotkeyMonitor` (rejected — risks dropping legitimate fast presses; root cause is upstream).
- Queueing presses during `.processing` (rejected — produces surprising delayed starts; standard UX is to drop).
- Adding `label: String` to the `ASREngine` protocol (rejected — single consumer, the factory already knows what it built).

## Design

### Engine label

**State.** `RecordingController` gains one observable property:

```swift
var currentEngineLabel: String = "Apple"
```

**Source of truth.** `PipelineProvider.applyDictation(...)` sets it whenever it (re)builds the dictation pipeline. It already knows whether the build fell back:

```swift
let label: String
if build.fallbackReason != nil {
    label = "Apple"                              // primary missing → factory chose Apple
} else {
    let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType)
                 ?? AppDefaults.Defaults.engineType
    label = Self.engineDisplayName(for: choice)
}
recordingController.currentEngineLabel = label
```

Mapping (kept private to `PipelineProvider`):

| `engineType` | Label |
|---|---|
| `apple` | "Apple" |
| `sensevoice` | "SenseVoice" |
| `paraformer` | "Paraformer" |
| `qwen3` | "Qwen3" |
| `cloud` | "Cloud" |
| anything else | "Apple" |

**Mid-session fallback.** `RecordingController` already receives `.engineFallback(from:)` events in its `pipelineTask` loop. Append one line in that case:

```swift
case .engineFallback(let from):
    self.isStreaming = pipeline.isStreaming
    self.currentEngineLabel = "Apple (fallback)"   // new
    LogService.info(...)
    ToastWindowController.show("Switched to local engine", style: .info)
```

The label is reset on the next pipeline rebuild (which the user can trigger by changing engine in Settings, or on next app launch).

### Overlay UI

Currently `OverlayView.body` is a single `VStack` with the status capsule (`headerBar`) and the transcript box. Wrap the status capsule in an `HStack` and add a chip to its right:

```
┌────────────────────────────────────────┐ ┌──────────┐
│ ● RECORDING  0:03         |||  ||||    │ │ SenseVoice│
└────────────────────────────────────────┘ └──────────┘
        (existing status capsule)             (new chip)
```

Implementation (sketch):

```swift
HStack(spacing: 8) {
    headerBar
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(statusGlass, in: .capsule)
        .glassEffectID("status", in: glassNS)

    engineChip
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("engineChip", in: glassNS)
}

private var engineChip: some View {
    Text(controller.currentEngineLabel)
        .font(.system(.caption2, design: .rounded))
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
}
```

Both lives inside the same `GlassEffectContainer`, so glass blending stays consistent.

### Bug fixes

Three targeted changes to `RecordingController`. All other files unchanged.

**1. Cancel pending hide on new recording.**

```swift
private func startRecording() {
    guard recordingState == .ready else { return }
    hideTask?.cancel()                  // NEW
    // ... existing code ...
}
```

Reason: `scheduleOverlayHide(after: 2)` posts a Task that hides the overlay 2s after stop. If the user starts a new recording within that window, the old hide fires mid-session.

**2. Cancel the UI's pipeline task on stop.**

```swift
private func stopRecording() {
    // ... existing guards ...
    recordingState = .processing
    pipelineTask?.cancel()              // NEW
    pipelineTask = nil                  // NEW
    stopTimer()
    // ... rest unchanged ...
}
```

Reason: the controller's `pipelineTask` consumes `pipeline.start()`'s event stream. Without cancellation, late partials from the old session can land in `partialText` / `confirmedSegments` after `stop` has been called. Pipeline-internal cleanup is unaffected: `pipeline.finalize()` calls `source.stop()`, which closes the audio stream and lets the pipeline's own detached task exit on its own.

**3. Push-to-talk minimum recording duration (300ms) → abort path.**

```swift
private var recordingStartedAt: Date?

private func startRecording() {
    // ... existing guards / setup ...
    recordingStartedAt = Date()         // NEW (just before state = .recording)
    recordingState = .recording
    // ... rest unchanged ...
}

func handleHotkeyUp() {
    LogService.info(...)
    if recordingMode == .pushToTalk && recordingState == .recording {
        performHaptic()
        let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if elapsed < 0.3 {
            abortRecording()
        } else {
            stopRecording()
        }
    }
}

private func abortRecording() {
    guard recordingState == .recording, let pipeline, let mutex else { return }
    pipelineTask?.cancel()
    pipelineTask = nil
    pipeline.stop()                     // discard audio; do NOT finalize
    mutex.release(.dictation)
    stopTimer()
    invalidateSilenceTimer()
    stopEscMonitor()
    confirmedSegments = []
    partialText = ""
    micLevel = 0
    spectrum = Array(repeating: 0, count: 16)
    recordingState = .ready             // synchronous; no .processing window
    hideOverlay()                       // hide immediately, no 2s delay
}
```

Reason: a miss-tap < 300ms produces no useful audio. Walking it through `.recording → .processing → .ready` causes the THINKING flash, fires `pipeline.finalize()` (which may take hundreds of ms), and leaves the mutex held during that window — the next press is silently dropped. The abort path skips finalize, releases mutex synchronously, clears state, and returns to `.ready` in the same MainActor tick.

The 300ms threshold matches typical involuntary key bounce + UI motor planning latency. Lower would let through real glitches; higher would defeat genuine quick utterances ("hi", "yes").

Toggle mode is untouched: toggle requires two deliberate presses, so this concept doesn't apply.

## Why these three are sufficient

The reported symptoms map cleanly:

| Symptom | Root cause | Fix |
|---|---|---|
| Status flicker | Short tap walks full `.recording → .processing → .ready` | Min duration → abort |
| Text leftover / mixed | Late events from old session; stale hideTask | Cancel `pipelineTask`; cancel `hideTask` |
| Second press unresponsive | `.processing` window holds mutex while finalize runs | Abort releases mutex synchronously |

No new state machine, no event-ID tagging, no queueing.

## Testing

`RecordingController` is not unit-testable today: its `init` starts the global `HotkeyMonitor` and `startRecording` calls `AXIsProcessTrusted` / `AVCaptureDevice` directly. The existing project has no `RecordingControllerTests`, and refactoring for injectability is out of scope for this change.

**Unit (`PipelineProviderTests`):**
- `test_engineDisplayName_mapsKnownChoices` — table-driven check over all five engine type strings + an unknown string.
- `test_applyDictation_setsLabelToAppleWhenFallbackReasonPresent` — feed an `EngineBuild` whose `fallbackReason != nil` regardless of the configured `engineType`, assert the controller's `currentEngineLabel == "Apple"`.

**Manual (functional — rapid tap):**
- Push-to-talk: tap hotkey ~5 times in quick succession; overlay does not flicker between RECORDING and THINKING, no THINKING flash for sub-300ms taps, next deliberate press starts cleanly with empty transcript.
- Push-to-talk: hold for ~500ms, verify normal stop → finalize path still works (no regression).
- Toggle mode: rapid double-press → starts then stops normally (no regression).

**Manual (engine label):**
- Select SenseVoice (with model installed); relaunch; chip reads "SenseVoice".
- Delete SenseVoice model directory, keep selection on SenseVoice; relaunch; chip reads "Apple" (build-time fallback).
- Set engine to Cloud with valid API key → chip reads "Cloud"; clear the key → relaunch → chip reads "Apple".
- Mid-session fallback ("Apple (fallback)") path is not easily forced manually; verify by code inspection that the assignment is in the `.engineFallback` case.

## Files touched

- `NemoNoise/App/RecordingController.swift` — new state (`currentEngineLabel`, `recordingStartedAt`), new method (`abortRecording`), three small edits.
- `NemoNoise/App/PipelineProvider.swift` — set `currentEngineLabel` after build; add private `engineDisplayName(for:)`.
- `NemoNoise/UI/Overlay/OverlayView.swift` — wrap header in `HStack`, add `engineChip` view.
- `NemoNoiseTests/PipelineProviderTests.swift` — two new tests covering the label mapping.

Estimated diff: ~80 lines net.
