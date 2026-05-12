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

## 2026-05-12 - US-004
- Structured logging with session ID correlation across all services.
- `LogService` gained `startSession()` / `endSession()` — generates UUID, prepends `session:XXXXXXXX` prefix (first 8 chars) to all log messages while active.
- Added `DDFileLogger.maximumFileSize = 5MB` for CocoaLumberjack file rotation config.
- `RecordingController`: logs recording start/stop with duration, mode, streaming flag; logs transcription result length; logs injection method/duration; logs errors with session end.
- `AudioCapture`: logs device info (sampleRate, channels, bufferSize) at capture start, conversion path, and stop.
- `SpeechOrchestrator.makeEngine()`: logs engine selection choice, init failures with error descriptions, model-not-found fallbacks.
- ASR engines: `SherpaASREngine` logs init duration and per-decode timing/char count; `ParaformerStreamingEngine` logs init duration; `AppleSpeechASREngine` logs init duration, locale, recognition result length, and error descriptions.
- `TextInjector`: logs target capture (debug), injection method (AX vs clipboard) with text length, AX error codes on fallback.
- Log categories used: `Recording`, `AudioCapture`, `ASR`, `TextInjection`, `SherpaASREngine`, `ParaformerStreamingEngine`, `AppleSpeechASREngine`.
- Files changed:
  - `NemoNoise/Utils/LogService.swift` — session ID support, 5MB max file size, formatted log messages
  - `NemoNoise/App/RecordingController.swift` — session lifecycle + injection logging
  - `NemoNoise/Services/Audio/AudioCapture.swift` — device info + buffer size logging
  - `NemoNoise/Services/ASR/SpeechOrchestrator.swift` — engine selection + error logging
  - `NemoNoise/Services/ASR/SherpaASREngine.swift` — init duration + decode timing
  - `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift` — init duration
  - `NemoNoise/Services/ASR/AppleSpeechASREngine.swift` — init duration + result logging
  - `NemoNoise/Services/Output/TextInjector.swift` — injection method + AX error codes
- **Learnings:**
  - `ContinuousClock.now` and `Duration` (Swift 5.7+) work well for lightweight timing — no import needed, `Duration.description` is human-readable.
  - Using a static `currentSessionID` on the singleton LogService lets any service's log calls automatically pick up the session context without passing IDs around — minimal coupling.
  - `DDLog*` string-based macros are deprecated in CocoaLumberjack 3.9.1 in favor of `DDLogMessageFormat` — still compile but produce warnings. Not addressed per CLAUDE.md surgical changes policy.
---

## 2026-05-12 - US-005
- First-launch onboarding flow: 3-step wizard shown on first app launch.
- Step 1: microphone permission request with visual feedback.
- Step 2: engine selection — Paraformer (default) or Apple Speech, using selectable cards.
- Step 3: hotkey display (Option / Right Cmd) with push-to-talk explanation.
- Each step has Back/Next/Skip; final step has "Get Started" button.
- On completion: `hasCompletedOnboarding` saved to UserDefaults — never shows again.
- `OnboardingGate` wrapper view bridges `.onAppear` into `MenuBarExtra` content, since `MenuBarExtra` scene doesn't support `.onAppear` directly.
- `OnboardingWindowController` uses a static `activePanel` to manage the onboarding window lifecycle outside the struct-based `App`.
- Files changed:
  - `NemoNoise/UI/Onboarding/OnboardingView.swift` — 3-step onboarding SwiftUI view
  - `NemoNoise/UI/Onboarding/OnboardingWindowController.swift` — NSPanel-based window controller
  - `NemoNoise/App/NemoNoiseApp.swift` — added OnboardingGate wrapper + onboarding trigger
- **Learnings:**
  - `MenuBarExtra` scene doesn't support `.onAppear` — need a wrapper view inside the content closure instead.
  - `NemoNoiseApp` is a struct (SwiftUI `App` protocol), so you can't store mutable reference types or use `[weak self]`. Use a static property on a helper class instead.
  - `.accentColor` is not a valid `ShapeStyle` member in newer SwiftUI — use `Color.accentColor` explicitly.
  - `PBXFileSystemSynchronizedRootGroup` in Xcode project means new files are auto-discovered — no manual pbxproj edits needed.
---

## 2026-05-12 - US-006
- Simplified overlay: removed manual close button and Copy to Clipboard button; overlay auto-fades after text injection.
- On AX injection success: overlay auto-fades out after 2 seconds.
- On AX injection failure: text copies to clipboard, toast "Copied to clipboard" shows for 3 seconds, then overlay fades.
- When no text produced: overlay auto-fades after 2 seconds (no close button otherwise).
- Toast text now uses `controller.toastMessage` (dynamic) instead of hardcoded string, so engine fallback and clipboard toast share the same UI.
- `TextInjector.inject()` replaced with `injectAX()` (sync, AX-only, no clipboard paste fallback). Removed `pasteViaPasteboard`.
- Removed from RecordingController: `showCopyButton`, `copyToClipboard()`, `dismissOverlay()`.
- Files changed:
  - `NemoNoise/Services/Output/TextInjector.swift` — replaced `inject()` with `injectAX()`, removed `pasteViaPasteboard`
  - `NemoNoise/App/RecordingController.swift` — rewrote `injectText` for auto-fade/toast flow, removed unused properties/methods
  - `NemoNoise/UI/Overlay/OverlayView.swift` — removed close button, removed Copy to Clipboard button, dynamic toast text
- **Learnings:**
  - When removing the only close/dismiss affordance from an overlay, handle the edge case of "no content produced" — otherwise the overlay hangs with no way to dismiss.
  - Sharing a single toast mechanism (showToast/toastMessage) across different features (engine fallback, clipboard copy) keeps the UI consistent and avoids duplicate overlay code.
  - Making `TextInjector.injectAX` synchronous is fine since AX calls are sync — no need for async when not doing clipboard paste with sleeps.
---

## 2026-05-12 - US-007
- Simplified settings from 4 tabs to 2: Engine and Shortcuts only.
- Removed: General tab (recording mode, language, about), Display tab (emotion tags).
- Engine picker: only Paraformer (default) and Apple Speech (removed SenseVoice option).
- Removed preferences: language selection (auto-detect), recording mode toggle (push-to-talk), emotion tag toggle (off).
- All removed prefs default to sensible values via existing UserDefaults fallbacks.
- OverlayView: removed `@AppStorage("showEmotionTags")` and emotion tag display code.
- MenubarView: removed SenseVoice fallback warning case.
- SpeechOrchestrator: default engine changed from "apple" to "paraformer".
- Files changed:
  - `NemoNoise/UI/Settings/SettingsView.swift` — rewrote to 2 tabs, removed General/Display/recordingMode/language/emotion
  - `NemoNoise/UI/Overlay/OverlayView.swift` — removed showEmotionTags AppStorage and emotion tag rendering
  - `NemoNoise/UI/Menubar/MenubarView.swift` — removed SenseVoice fallback warning
  - `NemoNoise/Services/ASR/SpeechOrchestrator.swift` — default engineType "apple" → "paraformer"
- **Learnings:**
  - When removing a user-facing toggle (emotion tags, recording mode), keep the underlying infrastructure in place — `RecordingMode` enum and `recordingMode` property in RecordingController still exist with hardcoded defaults, so the app logic is unchanged.
  - When simplifying a picker, also update all default values throughout the codebase (SpeechOrchestrator, MenubarView) to match the new default engine.
  - `@AppStorage` bindings in removed views need to be cleaned from the view file, but the UserDefaults key itself can remain for existing users — the fallback value handles it.
---

## 2026-05-12 - US-009
- Integrated Sentry crash reporting SDK (v8.58.2 via SPM).
- `SentryConfig` holds the DSN as a static constant (empty by default = Sentry disabled).
- `SentryService` manages initialization and error capture; checks `sentryEnabled` UserDefaults key before any Sentry call.
- Opt-out toggle (off by default) added as Privacy section in Engine tab of settings.
- Runtime enable/disable: enabling calls `SentrySDK.start()`, disabling calls `SentrySDK.close()`.
- Non-fatal errors captured: `RecordingController.handleError()` captures recording errors, `SpeechOrchestrator` captures engine fallback messages.
- Files changed:
  - `NemoNoise.xcodeproj/project.pbxproj` — added Sentry SPM package reference + product dependency
  - `NemoNoise/Services/Sentry/SentryConfig.swift` — DSN config constant (new file)
  - `NemoNoise/Services/Sentry/SentryService.swift` — init, opt-out, capture helpers (new file)
  - `NemoNoise/App/NemoNoiseApp.swift` — added `SentryService.initialize()` call in init
  - `NemoNoise/UI/Settings/SettingsView.swift` — added Privacy section with crash reporting toggle
  - `NemoNoise/App/RecordingController.swift` — added `SentryService.capture(error:)` in handleError
  - `NemoNoise/Services/ASR/SpeechOrchestrator.swift` — added `SentryService.capture(message:)` on engine fallback
- **Learnings:**
  - `PBXFileSystemSynchronizedRootGroup` means new Swift files in NemoNoise/ are auto-discovered — no pbxproj edits needed for source files, only for SPM package references.
  - Editing pbxproj requires exact tab characters; the Read tool renders tabs as variable-width spaces, making Edit unreliable for pbxproj. Use Python/sed scripts instead.
  - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set project-wide, but `enum` types with static methods don't cause issues for thread-safe SDKs like Sentry.
  - Sentry opt-out pattern: store `sentryEnabled` (Bool, default false) in UserDefaults. `SentryService.isEnabled` setter handles runtime enable/disable by calling `SentrySDK.start()`/`SentrySDK.close()`.
---
