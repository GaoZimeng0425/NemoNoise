# Ralph Progress Log

This file tracks progress across iterations. Agents update this file
after each iteration and it's included in prompts for context.

## Codebase Patterns (Study These First)

- **RecordingState enum**: Cases are `.ready`, `.recording`, `.processing`, `.failed(String)` — NOT `.idle`. All switch statements must handle `.failed`.
- **ASRService.isStreaming**: Protocol extension defaults to `true`; only `SherpaASREngine` overrides to `false`. Overlay uses `controller.isStreaming` to decide display mode.

---

## 2026-05-12 - US-001
- Added `isStreaming: Bool { get }` property to `ASRService` protocol with default extension returning `true`.
- `SherpaASREngine` overrides to return `false` (offline/batch engine).
- `ParaformerStreamingEngine` and `AppleSpeechASREngine` use default `true`.
- Files changed:
  - `NemoNoise/Services/ASR/ASRService.swift` — added protocol property + default extension
  - `NemoNoise/Services/ASR/SherpaASREngine.swift` — added `let isStreaming = false`
- **Learnings:**
  - Protocol extensions with defaults work well for opt-out properties — most conformers need no changes.
  - Pre-existing build errors exist in `MenubarView.swift` (RecordingState enum mismatch) — unrelated to ASR work.
  - `RecordingState` enum has cases: `.ready`, `.recording`, `.processing`, `.failed(String)` — NOT `.idle`.

## 2026-05-12 - US-002
- Overlay waveform-only mode for non-streaming (batch) ASR engines.
- `SpeechOrchestrator` exposes `isStreaming` computed property (reads engine or falls back to UserDefaults-based heuristic).
- `RecordingController` stores `isStreaming` and sets it from orchestrator at recording start.
- `OverlayView` hides transcript area during recording when `isStreaming=false`, showing only the header with waveform.
- After recording ends, transcript area reappears with final transcription text in one shot.
- Fixed pre-existing `RecordingState.idle` → `.ready` errors in `OverlayView.swift` and `MenubarView.swift`.
- Added `.failed` case handling to all `RecordingState` switches for exhaustiveness.
- Files changed:
  - `NemoNoise/Services/ASR/SpeechOrchestrator.swift` — added `isStreaming` computed property
  - `NemoNoise/App/RecordingController.swift` — added `isStreaming` stored property, set in `startRecording()`
  - `NemoNoise/UI/Overlay/OverlayView.swift` — conditional transcript visibility via `shouldShowTranscript`, fixed `.idle`→`.ready`, added `.failed` cases
  - `NemoNoise/UI/Menubar/MenubarView.swift` — fixed `.idle`→`.ready`, added `.failed` cases
- **Learnings:**
  - For properties that need to be known before async engine creation, a UserDefaults-based heuristic is a clean fallback in the computed property.
  - Pre-existing `.idle`/`.ready` enum mismatch was blocking builds — now fixed.
  - SwiftUI conditional view rendering (if/else around VStack children) works cleanly for mode-dependent layouts.
---

## 2026-05-12 - US-003
- Engine auto-fallback: when the active ASR engine throws during `feedChunk`, SpeechOrchestrator silently switches to AppleSpeechASREngine and continues recording.
- Non-intrusive toast notification ("Switched to local engine") shown at bottom of overlay for 3 seconds after fallback.
- Fallback events logged via LogService with original engine name and error description.
- One-shot fallback only — if the Apple fallback engine also fails, error propagates normally.
- `isStreaming` updated to `true` on fallback (Apple engine is streaming).
- Files changed:
  - `NemoNoise/Services/ASR/SpeechOrchestrator.swift` — inner do/catch around `feedChunk` with `catch where !hasFallenBack`, creates AppleSpeechASREngine, calls `onEngineFallback` callback
  - `NemoNoise/App/RecordingController.swift` — added `showToast`/`toastMessage`/`toastTask`, wired `onEngineFallback` callback with 3-second auto-dismiss
  - `NemoNoise/UI/Overlay/OverlayView.swift` — added `showFallbackToast` state, toast overlay with capsule background at bottom, `.onChange` bridge from controller state
- **Learnings:**
  - `catch where condition` in Swift lets you selectively handle errors inside a loop — unhandled errors propagate to outer catch naturally. Useful for one-shot fallback patterns.
  - Using `self.engine` (instance property) instead of a local `let` for the engine reference allows mid-loop engine replacement without restructuring the loop.
  - Toast animation bridging: controller drives `showToast` (Bool), view uses `.onChange` to animate its own `@State` copy — decouples model updates from animation timing.
---
