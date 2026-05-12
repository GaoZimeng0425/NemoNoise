# Ralph Progress Log

This file tracks progress across iterations. Agents update this file
after each iteration and it's included in prompts for context.

## Codebase Patterns (Study These First)

*Add reusable patterns discovered during development here.*

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
---
