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
