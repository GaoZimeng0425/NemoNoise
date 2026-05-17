# Engine Badge + Rapid-Tap Bug Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display the active ASR engine as a small chip in the overlay's top-right, and fix three rapid-tap bugs (overlay flicker, transcript leftover, second-press unresponsiveness).

**Architecture:** Add one observable `currentEngineLabel` on `RecordingController` populated by `PipelineProvider` at build time and updated on mid-session fallback. Add a glass-capsule chip beside the existing status capsule in `OverlayView`. Fix bugs in `RecordingController` with three targeted edits: cancel `hideTask` on start, cancel `pipelineTask` on stop, and add an `abortRecording()` fast path for push-to-talk taps shorter than 300 ms.

**Tech Stack:** Swift 5.9+, SwiftUI, `@Observable`, Swift concurrency, XCTest. Build/test with `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS'`.

**Design doc:** `docs/superpowers/specs/2026-05-17-engine-badge-and-rapid-tap-fix-design.md`

---

## Task 1: Engine label state + PipelineProvider mapping

Adds the observable property on `RecordingController`, the display-name mapping on `PipelineProvider`, and the assignment inside `applyDictation`. TDD via `PipelineProviderTests`.

**Files:**
- Modify: `NemoNoise/App/RecordingController.swift` (add stored property)
- Modify: `NemoNoise/App/PipelineProvider.swift` (add helper + assignment)
- Modify: `NemoNoiseTests/PipelineProviderTests.swift` (add 2 tests)

- [ ] **Step 1: Add the observable property to `RecordingController`**

Open `NemoNoise/App/RecordingController.swift`. In the `// MARK: - UI state (observed by SwiftUI)` block, add a new property after `recordingDuration`:

```swift
var recordingDuration: TimeInterval = 0
var currentEngineLabel: String = "Apple"
```

- [ ] **Step 2: Write failing test — user-choice label**

Open `NemoNoiseTests/PipelineProviderTests.swift`. After the last test (`testRebuildDictationReachesReadyAgain`), add:

```swift
    func testApplyDictation_setsLabelFromUserChoice() async throws {
        UserDefaults.standard.set("sensevoice", forKey: AppDefaults.Keys.engineType)
        defer { UserDefaults.standard.removeObject(forKey: AppDefaults.Keys.engineType) }

        let (provider, recording, _) = makeProvider()
        provider.bootstrap()
        try await waitUntilReady(provider)

        XCTAssertEqual(recording.currentEngineLabel, "SenseVoice")
    }
```

- [ ] **Step 3: Run test to verify it fails**

```bash
xcodebuild test \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/PipelineProviderTests/testApplyDictation_setsLabelFromUserChoice 2>&1 | tail -30
```

Expected: FAIL — `currentEngineLabel` is still the default `"Apple"`, not `"SenseVoice"`.

- [ ] **Step 4: Implement display-name mapping + assignment**

Open `NemoNoise/App/PipelineProvider.swift`. At the bottom of the class (after `makePunctuator`), add the helper:

```swift
    private static func engineDisplayName(for choice: String) -> String {
        switch choice {
        case "apple":      return "Apple"
        case "sensevoice": return "SenseVoice"
        case "paraformer": return "Paraformer"
        case "qwen3":      return "Qwen3"
        case "cloud":      return "Cloud"
        default:           return "Apple"
        }
    }
```

In `applyDictation(...)`, inside the `.success(let build)` branch, after `recordingController.bind(pipeline: pipeline, mutex: mutex)` (still inside the `if let recordingController` block), add:

```swift
                let label: String
                if build.fallbackReason != nil {
                    label = "Apple"
                } else {
                    let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType)
                                 ?? AppDefaults.Defaults.engineType
                    label = Self.engineDisplayName(for: choice)
                }
                recordingController.currentEngineLabel = label
```

- [ ] **Step 5: Run test to verify it passes**

```bash
xcodebuild test \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/PipelineProviderTests/testApplyDictation_setsLabelFromUserChoice 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 6: Add the fallback-reason test**

Back in `NemoNoiseTests/PipelineProviderTests.swift`, add after the previous test:

```swift
    func testApplyDictation_labelFallsBackToAppleWhenBuildHasFallbackReason() async throws {
        UserDefaults.standard.set("sensevoice", forKey: AppDefaults.Keys.engineType)
        defer { UserDefaults.standard.removeObject(forKey: AppDefaults.Keys.engineType) }

        let factory = StubFactory()
        factory.primaryResult = .success(.init(engine: StubEngine(), fallbackReason: "model missing"))
        let (provider, recording, _) = makeProvider(factory: factory)
        provider.bootstrap()
        try await waitUntilReady(provider)

        XCTAssertEqual(recording.currentEngineLabel, "Apple")
    }
```

- [ ] **Step 7: Run both new tests, verify both pass**

```bash
xcodebuild test \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/PipelineProviderTests 2>&1 | tail -30
```

Expected: all `PipelineProviderTests` PASS (existing + 2 new).

- [ ] **Step 8: Commit**

```bash
git add NemoNoise/App/RecordingController.swift NemoNoise/App/PipelineProvider.swift NemoNoiseTests/PipelineProviderTests.swift
git commit -m "$(cat <<'EOF'
feat(overlay): track current engine label on RecordingController

Add observable currentEngineLabel set by PipelineProvider after each
dictation build. Falls back to "Apple" when the factory itself fell
back (e.g. selected model missing). Covered by two new tests in
PipelineProviderTests.
EOF
)"
```

---

## Task 2: Render engine chip in the overlay

Adds the chip view beside the status capsule. Visual change, verified by running the app.

**Files:**
- Modify: `NemoNoise/UI/Overlay/OverlayView.swift`

- [ ] **Step 1: Wrap header in HStack and add `engineChip`**

Open `NemoNoise/UI/Overlay/OverlayView.swift`. Replace the `body` (currently lines ~13–33) with:

```swift
    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    headerBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(statusGlass, in: .capsule)
                        .glassEffectID("status", in: glassNS)
                        .layoutPriority(1)

                    engineChip
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("engineChip", in: glassNS)
                }

                if shouldShowTranscript {
                    transcriptArea
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        .glassEffectID("transcript", in: glassNS)
                        .transition(.opacity)
                }
            }
        }
        .frame(minWidth: 360, maxWidth: 520)
        .animation(.smooth(duration: 0.4), value: controller.recordingState)
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

`layoutPriority(1)` ensures the status capsule keeps its preferred width and the chip hugs its content on the right.

- [ ] **Step 2: Build the app and verify it compiles**

```bash
xcodebuild build \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual visual check**

Launch the app from Xcode (or run `./build.sh` and open the built artifact). Trigger the overlay (push-to-talk). Verify:
- A small chip appears to the right of the RECORDING capsule.
- Chip text matches the engine selected in Settings (e.g. "Apple", "SenseVoice").
- Status capsule and chip both have the glass effect and are visually balanced.

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/UI/Overlay/OverlayView.swift
git commit -m "$(cat <<'EOF'
feat(overlay): show engine chip beside status capsule

A small glass capsule to the right of the status capsule displays the
currently active ASR engine. Reads RecordingController.currentEngineLabel.
EOF
)"
```

---

## Task 3: Mid-session fallback relabels chip

Updates the `.engineFallback` case in `RecordingController`'s pipeline event loop so the chip flips to `"Apple (fallback)"` when the runtime fallback path is taken.

**Files:**
- Modify: `NemoNoise/App/RecordingController.swift` (`startRecording` event loop)

- [ ] **Step 1: Add label assignment in the fallback case**

In `NemoNoise/App/RecordingController.swift`, locate the event loop inside `startRecording()` (currently around lines 200–223). The `.engineFallback` case looks like:

```swift
                    case .engineFallback(let from):
                        self.isStreaming = pipeline.isStreaming
                        LogService.info("Engine fallback from \(from)", category: "Recording")
                        ToastWindowController.show("Switched to local engine", style: .info)
```

Insert one line:

```swift
                    case .engineFallback(let from):
                        self.isStreaming = pipeline.isStreaming
                        self.currentEngineLabel = "Apple (fallback)"
                        LogService.info("Engine fallback from \(from)", category: "Recording")
                        ToastWindowController.show("Switched to local engine", style: .info)
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/App/RecordingController.swift
git commit -m "$(cat <<'EOF'
feat(overlay): relabel engine chip on mid-session fallback

When the pipeline emits .engineFallback, swap currentEngineLabel to
"Apple (fallback)" so the overlay reflects the actually-running engine.
EOF
)"
```

---

## Task 4: Cancel `hideTask` on new recording

Prevents the 2 s post-stop hide from firing during a follow-up recording.

**Files:**
- Modify: `NemoNoise/App/RecordingController.swift` (`startRecording`)

- [ ] **Step 1: Add hideTask cancel at top of startRecording**

In `NemoNoise/App/RecordingController.swift`, find `private func startRecording()`. After the `guard recordingState == .ready else { return }` line, insert:

```swift
    private func startRecording() {
        guard recordingState == .ready else { return }
        hideTask?.cancel()
```

(everything else in `startRecording` stays as-is)

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/App/RecordingController.swift
git commit -m "$(cat <<'EOF'
fix(recording): cancel pending hideTask when starting a new recording

The 2-second post-stop hide could fire mid-session if the user started
a new recording quickly. Cancel it on every startRecording.
EOF
)"
```

---

## Task 5: Cancel `pipelineTask` on stop

Prevents late partials from the previous session from contaminating UI state after stop.

**Files:**
- Modify: `NemoNoise/App/RecordingController.swift` (`stopRecording`)

- [ ] **Step 1: Cancel pipelineTask after setting state to .processing**

In `NemoNoise/App/RecordingController.swift`, find `private func stopRecording()`. After `recordingState = .processing` and before `stopTimer()`, insert two lines:

```swift
        recordingState = .processing
        pipelineTask?.cancel()
        pipelineTask = nil
        stopTimer()
```

The rest of `stopRecording` is unchanged. The `pipeline.finalize()` call inside the spawned Task is unaffected — it stops the audio source itself and waits on the pipeline's own detached task, not ours.

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/App/RecordingController.swift
git commit -m "$(cat <<'EOF'
fix(recording): cancel pipelineTask on stop to prevent stale events

The controller's pipelineTask consumes pipeline.start()'s event stream.
Without cancellation, late partials from the old session could land in
partialText / confirmedSegments after stopRecording was invoked.
EOF
)"
```

---

## Task 6: Push-to-talk minimum duration + `abortRecording`

The largest change. Adds `recordingStartedAt`, branches `handleHotkeyUp` on elapsed time, and introduces an `abortRecording()` fast path that skips finalize.

**Files:**
- Modify: `NemoNoise/App/RecordingController.swift`

- [ ] **Step 1: Add `recordingStartedAt` stored property**

In `NemoNoise/App/RecordingController.swift`, in the `// MARK: - Internal state` block (around lines 53–58), add a new private var:

```swift
    private var silenceTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private let maxRecordingDuration: TimeInterval = 120
    private var timerTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var escMonitor: Any?
    private var recordingStartedAt: Date?
```

- [ ] **Step 2: Set `recordingStartedAt` in `startRecording`**

Still in `startRecording()`, locate the block where state transitions to `.recording`:

```swift
        recordingState = .recording
        confirmedSegments = []
        partialText = ""
```

Insert `recordingStartedAt = Date()` right before:

```swift
        recordingStartedAt = Date()
        recordingState = .recording
        confirmedSegments = []
        partialText = ""
```

- [ ] **Step 3: Branch `handleHotkeyUp` on elapsed time**

Replace the body of `handleHotkeyUp()` (currently around lines 135–141):

```swift
    func handleHotkeyUp() {
        LogService.info("HotkeyUp — mode=\(recordingMode.rawValue) state=\(recordingState)", category: "Recording")
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
```

- [ ] **Step 4: Add the `abortRecording` method**

Add a new private method below `stopRecording()` (before `handlePipelineError`). The method must compile against the same `pipeline` / `mutex` fields:

```swift
    /// Abort an in-flight recording without finalizing. Used when a
    /// push-to-talk press is shorter than the minimum useful duration:
    /// audio is discarded, the mutex is released synchronously, and state
    /// returns to `.ready` in the same MainActor tick (no `.processing`
    /// window). Toggle mode never triggers this path.
    private func abortRecording() {
        guard recordingState == .recording, let pipeline, let mutex else { return }
        LogService.info("Aborting recording (too short)", category: "Recording")

        pipelineTask?.cancel()
        pipelineTask = nil
        pipeline.stop()
        mutex.release(.dictation)
        stopTimer()
        invalidateSilenceTimer()
        stopEscMonitor()

        confirmedSegments = []
        partialText = ""
        micLevel = 0
        spectrum = Array(repeating: 0, count: 16)
        recordingState = .ready
        hideOverlay()
    }
```

- [ ] **Step 5: Build to verify**

```bash
xcodebuild build \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add NemoNoise/App/RecordingController.swift
git commit -m "$(cat <<'EOF'
fix(recording): abort short push-to-talk taps instead of finalizing

Taps shorter than 300 ms walked the full .recording → .processing →
.ready transition, causing overlay flicker, holding the mutex during
finalize, and leaving the next press unresponsive. New abortRecording()
fast path discards audio, releases the mutex synchronously, and
returns to .ready without showing THINKING.
EOF
)"
```

---

## Task 7: Full suite + manual QA

Run the test suite and validate the four manual scenarios in the spec.

- [ ] **Step 1: Run full test suite**

```bash
xcodebuild test \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -40
```

Expected: all tests PASS. No new failures vs. before this branch.

- [ ] **Step 2: Manual — engine chip displays user choice**

1. Open Settings, select "Apple Speech" engine. Relaunch (or trigger a pipeline rebuild via the Settings change handler). Trigger overlay. Chip reads "Apple".
2. Select "SenseVoice" with the model installed. Chip reads "SenseVoice".
3. Select "Cloud" with a valid API key. Chip reads "Cloud".

- [ ] **Step 3: Manual — fallback at build time labels as "Apple"**

1. With SenseVoice selected, rename or delete `~/Library/Application Support/NemoNoise/models/sense-voice...` so the factory cannot find the model.
2. Relaunch. The overlay chip reads "Apple" (factory fell back) and a fallback toast appears.
3. Restore the model directory.

- [ ] **Step 4: Manual — rapid tap on push-to-talk**

Set mode to Push-to-Talk in Settings.

1. Tap the hotkey 5 times in rapid succession (each tap < 300 ms). Verify:
   - Overlay does NOT flicker between RECORDING → THINKING → READY.
   - No THINKING flash.
   - No transcript residue between taps.
2. Hold the hotkey for ~1 second, release. Normal finalize path runs, transcript appears, overlay hides after 2 s.
3. Immediately after a normal recording finishes, tap again. New recording starts cleanly with empty transcript.

- [ ] **Step 5: Manual — toggle mode regression check**

Set mode to Toggle. Press once to start, press again to stop. Verify the existing behavior is unchanged (no abort path, normal finalize).

- [ ] **Step 6: Final commit (if any cleanup) and summarize**

If everything passed, no further commits needed — Tasks 1–6 already left the branch in a complete state. Otherwise, file the failing observation as a follow-up issue, since the spec only commits to the manual checks above.
