# Audio Interruption Recovery (R1 + R2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect mid-recording audio interruptions — input-device configuration change (R1) and raw-tap audio stall (R2) — and respond with "stop-and-notify": gracefully finalize the in-progress session (keeping recognized text) and show a toast.

**Architecture:** `MicAudioSource` owns the `AVAudioEngine` and raw tap, so detection lives there. R1 observes `AVAudioEngineConfigurationChange` (catches both default-device change and a pinned device disconnecting). R2 uses a pure, clock-injectable `AudioStallWatchdog` driven by a repeating timer that watches the **raw** tap timestamp (before VAD gating, so VAD-suppressed silence never false-triggers). Both funnel through a single one-shot `onInterruption(reason:)` callback wired at construction in `PipelineProvider`, which hops to the MainActor and calls a new `RecordingController.handleAudioInterruption(_:)` → existing `stopRecording()` finalize path + toast. The `AudioSource` protocol is unchanged; the callback bypasses the `VADGatedSource` decorator because it's injected into the concrete `MicAudioSource` at construction.

**Tech Stack:** Swift, AVFoundation, QuartzCore (`CACurrentMediaTime`), `os.OSAllocatedUnfairLock`, XCTest, xcodebuild.

---

## File Structure

- **Create** `NemoNoise/Services/Audio/AudioStallWatchdog.swift` — the `AudioInterruptionReason` enum + pure `AudioStallWatchdog` stall-detection logic (clock-injectable, unit-tested).
- **Create** `NemoNoiseTests/AudioStallWatchdogTests.swift` — unit tests for the watchdog.
- **Modify** `NemoNoise/Services/Audio/MicAudioSource.swift` — add `onInterruption` init param, stall watchdog + timer, config-change observer, one-shot fire helper. (Integration code — manual QA; conformance test must stay green.)
- **Modify** `NemoNoise/App/RecordingController.swift` — add `handleAudioInterruption(_:)`.
- **Create** `NemoNoiseTests/RecordingControllerInterruptionTests.swift` — guard test (no-op when not recording).
- **Modify** `NemoNoise/App/PipelineProvider.swift:172` (`makeGatedMicSource`) — wire the callback into `MicAudioSource`.

**Test runner:** this is an Xcode project (no SPM). Run a single test class with:
```
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/<ClassName>
```

---

### Task 1: Pure stall-detection logic + interruption reason

**Files:**
- Create: `NemoNoise/Services/Audio/AudioStallWatchdog.swift`
- Test: `NemoNoiseTests/AudioStallWatchdogTests.swift`

- [ ] **Step 1: Write the failing test**

Create `NemoNoiseTests/AudioStallWatchdogTests.swift`:

```swift
import XCTest
@testable import NemoNoise

final class AudioStallWatchdogTests: XCTestCase {
    func testNotStalledImmediatelyAfterCreation() {
        let w = AudioStallWatchdog(threshold: 2.0, now: 100.0)
        XCTAssertFalse(w.isStalled(at: 100.0))
    }

    func testNotStalledJustBeforeThreshold() {
        let w = AudioStallWatchdog(threshold: 2.0, now: 100.0)
        XCTAssertFalse(w.isStalled(at: 102.0)) // exactly threshold is not yet stalled
    }

    func testStalledPastThreshold() {
        let w = AudioStallWatchdog(threshold: 2.0, now: 100.0)
        XCTAssertTrue(w.isStalled(at: 102.01))
    }

    func testRecordingActivityResetsTheClock() {
        var w = AudioStallWatchdog(threshold: 2.0, now: 100.0)
        w.recordActivity(at: 103.0)
        XCTAssertFalse(w.isStalled(at: 104.5)) // 1.5s since last activity
        XCTAssertTrue(w.isStalled(at: 105.01)) // 2.01s since last activity
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/AudioStallWatchdogTests`
Expected: FAIL — compile error, `AudioStallWatchdog` / `AudioInterruptionReason` not found.

- [ ] **Step 3: Write minimal implementation**

Create `NemoNoise/Services/Audio/AudioStallWatchdog.swift`:

```swift
import Foundation

/// Why an in-progress recording was interrupted. Both reasons map to the same
/// "stop-and-notify" response; only the toast copy differs.
enum AudioInterruptionReason: Sendable {
    /// Input-device configuration changed mid-recording (device switched,
    /// pinned device disconnected, route changed).
    case deviceConfigurationChanged
    /// No raw audio buffers arrived for longer than the stall threshold —
    /// the capture device went silent at the hardware level.
    case audioStalled
}

/// Pure stall-detection logic: no timers, no audio, clock injected by the
/// caller. `MicAudioSource` serializes access behind a lock, so this type is
/// intentionally not thread-safe on its own.
struct AudioStallWatchdog {
    let threshold: CFTimeInterval
    private(set) var lastActivity: CFTimeInterval

    init(threshold: CFTimeInterval, now: CFTimeInterval) {
        self.threshold = threshold
        self.lastActivity = now
    }

    mutating func recordActivity(at now: CFTimeInterval) {
        lastActivity = now
    }

    func isStalled(at now: CFTimeInterval) -> Bool {
        now - lastActivity > threshold
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/AudioStallWatchdogTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/Services/Audio/AudioStallWatchdog.swift NemoNoiseTests/AudioStallWatchdogTests.swift
git commit -m "feat(audio): add pure AudioStallWatchdog + AudioInterruptionReason"
```

---

### Task 2: Wire detection into MicAudioSource

**Files:**
- Modify: `NemoNoise/Services/Audio/MicAudioSource.swift`
- Test: `NemoNoiseTests/AudioSourceConformanceTests.swift` (must stay green — proves `MicAudioSource()` still compiles with the new optional init param)

This task is AVAudioEngine/timer integration — verified by build + conformance test + manual QA (consistent with `docs/architecture.md`: real audio sources are manual-QA). No new unit test; the testable decision logic already lives in `AudioStallWatchdog`.

- [ ] **Step 1: Add the QuartzCore import**

At the top of `MicAudioSource.swift`, add `import QuartzCore` after the existing imports:

```swift
import AVFoundation
import os
import QuartzCore
```

- [ ] **Step 2: Add stored properties and init**

Inside `final class MicAudioSource`, immediately after the existing `firstChunkLogged` lock (line ~17), add:

```swift
    private let onInterruption: (@Sendable (AudioInterruptionReason) -> Void)?
    private let stallThreshold: CFTimeInterval = 2.0
    private let stallCheckInterval: CFTimeInterval = 0.5
    private let watchdog = OSAllocatedUnfairLock<AudioStallWatchdog>(
        initialState: AudioStallWatchdog(threshold: 2.0, now: 0)
    )
    private let interruptionFired = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let stallTimer = OSAllocatedUnfairLock<DispatchSourceTimer?>(initialState: nil)
    private let configObserver = OSAllocatedUnfairLock<NSObjectProtocol?>(initialState: nil)

    init(onInterruption: (@Sendable (AudioInterruptionReason) -> Void)? = nil) {
        self.onInterruption = onInterruption
    }
```

(The default `= nil` keeps the existing `MicAudioSource()` call sites and conformance test working.)

- [ ] **Step 3: Arm the watchdog + observer in `start()`**

In `start()`, immediately after `isCapturing.withLock { $0 = true }` (line ~57, before the `LogService.info("Capture started…")` line), insert:

```swift
        interruptionFired.withLock { $0 = false }
        watchdog.withLock { $0 = AudioStallWatchdog(threshold: stallThreshold, now: CACurrentMediaTime()) }
        startStallTimer()
        observeConfigurationChanges()
```

- [ ] **Step 4: Record raw-tap activity in `processTap`**

In `processTap(buffer:resampler:)`, as the very first line of the method body (before the `isFirst` block, line ~88), insert:

```swift
        watchdog.withLock { $0.recordActivity(at: CACurrentMediaTime()) }
```

This timestamps the **raw** tap — it fires on every hardware buffer regardless of speech/silence, so VAD-gated silence downstream never affects it.

- [ ] **Step 5: Tear down in `stopEngine()`**

In `stopEngine()`, after the `guard wasCapturing else { return }` line and before `engine.inputNode.removeTap(onBus: 0)`, insert:

```swift
        stallTimer.withLock { timer in
            timer?.cancel()
            timer = nil
        }
        configObserver.withLock { token in
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
```

- [ ] **Step 6: Add the timer, observer, and one-shot fire helpers**

Add these private methods to `MicAudioSource` (e.g. just before `requestMicrophoneAccess()`):

```swift
    /// Repeating background timer that asks the watchdog whether the raw tap
    /// has stalled. Fires `.audioStalled` at most once per session.
    private func startStallTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + stallCheckInterval, repeating: stallCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stalled = self.watchdog.withLock { $0.isStalled(at: CACurrentMediaTime()) }
            if stalled {
                LogService.warn("Audio stall detected (no raw tap for >\(self.stallThreshold)s)", category: "AudioCapture")
                self.fireInterruptionOnce(.audioStalled)
            }
        }
        timer.resume()
        stallTimer.withLock { $0 = timer }
    }

    /// Observe engine reconfiguration (device switch, pinned-device disconnect,
    /// route change) while capturing. Scoped to this engine instance.
    private func observeConfigurationChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            guard self.isCapturing.withLock({ $0 }) else { return }
            LogService.warn("AVAudioEngine configuration changed mid-capture", category: "AudioCapture")
            self.fireInterruptionOnce(.deviceConfigurationChanged)
        }
        configObserver.withLock { $0 = token }
    }

    /// Deliver the interruption to the callback at most once per session, then
    /// stop the engine. Subsequent triggers (e.g. stall fires right after a
    /// config change) are ignored.
    private func fireInterruptionOnce(_ reason: AudioInterruptionReason) {
        let already = interruptionFired.withLock { fired -> Bool in
            let was = fired
            fired = true
            return was
        }
        guard !already else { return }
        onInterruption?(reason)
        stopEngine()
    }
```

- [ ] **Step 7: Build + run the conformance test**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/AudioSourceConformanceTests`
Expected: PASS — `MicAudioSource()` still satisfies `any AudioSource` with the new optional init param; project compiles.

- [ ] **Step 8: Commit**

```bash
git add NemoNoise/Services/Audio/MicAudioSource.swift
git commit -m "feat(audio): detect config-change + raw-tap stall in MicAudioSource"
```

---

### Task 3: RecordingController interruption handler

**Files:**
- Modify: `NemoNoise/App/RecordingController.swift`
- Test: `NemoNoiseTests/RecordingControllerInterruptionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `NemoNoiseTests/RecordingControllerInterruptionTests.swift`:

```swift
import XCTest
@testable import NemoNoise

@MainActor
final class RecordingControllerInterruptionTests: XCTestCase {
    /// When not recording, an interruption signal must be a safe no-op:
    /// state stays `.ready` and nothing is finalized. (The active-recording
    /// path drives the AVAudioEngine + overlay and is covered by manual QA.)
    func testInterruptionIgnoredWhenNotRecording() {
        let controller = RecordingController()
        XCTAssertEqual(controller.recordingState, .ready)

        controller.handleAudioInterruption(.audioStalled)
        XCTAssertEqual(controller.recordingState, .ready)

        controller.handleAudioInterruption(.deviceConfigurationChanged)
        XCTAssertEqual(controller.recordingState, .ready)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/RecordingControllerInterruptionTests`
Expected: FAIL — compile error, `handleAudioInterruption` not found.

- [ ] **Step 3: Write minimal implementation**

In `RecordingController.swift`, add this method in the `// MARK: - Recording lifecycle` section, immediately after `handlePipelineError(_:)` (around line 350):

```swift
    /// Called (on the MainActor) when `MicAudioSource` detects a mid-recording
    /// audio interruption. Behavior: stop-and-notify — gracefully finalize the
    /// current session (keeping recognized text) via `stopRecording()`, and
    /// show a toast explaining why. No-op unless actively recording.
    func handleAudioInterruption(_ reason: AudioInterruptionReason) {
        guard recordingState == .recording else { return }
        let message: String
        switch reason {
        case .deviceConfigurationChanged:
            message = "输入设备已变化，录音已停止"
        case .audioStalled:
            message = "未检测到音频输入，录音已停止"
        }
        LogService.warn("Audio interruption (\(reason)) — finalizing session", category: "Recording")
        ToastWindowController.show(message, style: .warning, duration: 4)
        stopRecording()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/RecordingControllerInterruptionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/App/RecordingController.swift NemoNoiseTests/RecordingControllerInterruptionTests.swift
git commit -m "feat(recording): handle audio interruption with stop-and-notify"
```

---

### Task 4: Wire the callback in PipelineProvider

**Files:**
- Modify: `NemoNoise/App/PipelineProvider.swift:172` (`makeGatedMicSource`)
- Test: `NemoNoiseTests/PipelineProviderTests.swift` (must stay green)

- [ ] **Step 1: Inject the callback into MicAudioSource**

In `makeGatedMicSource()`, replace the final return line:

```swift
        return VADGatedSource(inner: MicAudioSource(), detector: detector)
```

with:

```swift
        let micSource = MicAudioSource(onInterruption: { [weak recordingController] reason in
            Task { @MainActor in
                recordingController?.handleAudioInterruption(reason)
            }
        })
        return VADGatedSource(inner: micSource, detector: detector)
```

(`recordingController` is the existing `private weak var` on `PipelineProvider` at line 23. Capturing it `[weak …]` in the `@Sendable` callback avoids a retain cycle: controller → pipeline → VADGatedSource → MicAudioSource → callback.)

- [ ] **Step 2: Build + run the provider tests**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/PipelineProviderTests`
Expected: PASS — project compiles, existing provider behavior unchanged.

- [ ] **Step 3: Run the full suite to confirm no regressions**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS'`
Expected: PASS — all tests, including the new `AudioStallWatchdogTests` and `RecordingControllerInterruptionTests`.

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/App/PipelineProvider.swift
git commit -m "feat(audio): wire MicAudioSource interruption callback to RecordingController"
```

---

## Manual QA (after Task 4)

These exercise the AVAudioEngine paths that unit tests can't reach. Run the app and, for each, confirm the recording stops, a warning toast appears, and any already-recognized text is injected/dispatched (not discarded):

1. **R1 — default device change:** Start dictation with the built-in mic, then connect/switch to AirPods (or switch default input in System Settings) mid-recording.
2. **R1 — pinned device disconnect:** In Settings, pin a specific USB/Bluetooth mic; start dictation; unplug/disconnect that device mid-recording.
3. **R2 — hardware stall:** Start dictation, then disconnect the active input device in a way that stops buffers without a clean config change (e.g. yank a USB mic). Expect the `.audioStalled` toast within ~2–2.5s.
4. **No false positives:** Record normally for 30s including several seconds of pure silence (VAD-gated). Confirm **no** interruption toast fires — the raw tap keeps the watchdog alive through silence.
5. **One-shot:** Confirm only a single toast appears per interruption (not both a config-change and a stall toast).

---

## Notes / deferred

- **Auto-reconnect** (the alternative R1 behavior) is intentionally out of scope — this implements stop-and-notify per the design decision. If auto-reconnect is wanted later, it would rebuild the tap on the new device inside `MicAudioSource` instead of calling `fireInterruptionOnce`.
- **Stall threshold (2.0s)** is a starting value: the raw tap fires every ~85ms (48 kHz) to ~256ms (16 kHz), so 2s of total silence is an unambiguous hardware stall. Tune during manual QA if false positives appear on slower devices.
