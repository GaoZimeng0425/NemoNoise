# NemoNoise Commercial Readiness Design

**Date:** 2026-05-12
**Status:** Approved
**Target user:** Programmers / technical users
**Distribution:** GitHub Releases (open source), Mac App Store later

---

## 1. ASR Engine Upgrade

**Keep Paraformer as primary. No WhisperKit.**

### Local engines (free)
- **Paraformer (streaming)** — Chinese real-time transcription via sherpa-onnx, primary engine
- **Apple Speech** — fallback / multi-language supplement
- **SenseVoice (offline batch)** — retained but not promoted; during recording show volume waveform only, output text + emotion tags after recording ends

### Cloud engine
- **Alibaba Cloud Paraformer API** — strongest Chinese accuracy, low latency, consistent experience with local Paraformer
- Optional: OpenAI Whisper API for English/multi-language later

### Behavior change for non-streaming engines
- Non-real-time engines (SenseVoice): overlay shows volume waveform animation only during recording, no text
- Real-time engines (Paraformer / Apple Speech / cloud): overlay streams text as usual
- On recording end: batch engine results replace waveform area in one shot

### Architecture changes
- Add `isStreaming: Bool` property to `ASRService` protocol
- `SpeechOrchestrator` reads `isStreaming` to decide overlay behavior: streaming → real-time text, batch → waveform only
- Add `CloudASREngine` wrapping Alibaba Cloud API calls
- Existing engine code stays mostly unchanged

---

## 2. UX Redesign

**Target: Minimalist "press and speak → text appears → auto-inject" experience, inspired by Superwhisper.**

### First launch
3-step onboarding: grant microphone → select engine (default Paraformer) → show hotkey

### Daily use
Press hotkey → overlay appears (waveform/real-time text) → release → text injected into active app → overlay fades out (2 seconds)

### Overlay changes
- Remove manual close button; auto-fade after injection
- Injection failure: show "copied to clipboard" toast, no big button
- Waveform area more compact, positioned near menu bar

### Settings simplification
Reduce to 2 tabs:
- **Engine tab:** local Paraformer (default) / cloud Paraformer (API Key required), one-click switch
- **Hotkey tab:** keep existing

Remove:
- Language selection (auto-detect)
- Recording mode toggle (push-to-talk only for V1)
- Emotion tag display toggle
- General settings tab (merged into engine tab)

---

## 3. Engineering Quality

### Testing
New test target covering:
- `ASRService` protocol mock tests
- `SpeechOrchestrator` engine switching logic
- `AudioCapture` lifecycle (start/stop/re-entry)
- `TextInjector` injection + clipboard fallback
- `ModelManager` download state machine

Priority: state transitions and error paths over coverage percentage.

### Crash reporting
- Integrate **Sentry** (free tier sufficient for macOS)
- Capture crashes + non-fatal errors (engine init failure, audio session exceptions)
- User opt-out supported

### Auto-update
- **Sparkle 2** for GitHub Releases distribution
- Switch to App Store built-in updates when上架

### Error handling
- ASR engine crash during recording → auto fallback to Apple Speech, toast notification
- Cloud API timeout / auth failure → local engine takes over, toast "switched to local engine"
- Audio device disconnected → stop recording, prompt reconnect

### Logging system
Keep CocoaLumberjack, add structured logging standards.

**Log levels:**
- `Error` — crashes, engine init failure, audio session interruption, API auth failure
- `Warn` — fallback triggered, injection failed → clipboard, model download retry, cloud timeout
- `Info` — engine switch, recording start/end, text injection success, API Key status change
- `Debug` — audio buffer state, ASR partial results, API request/response summary

**Session-based correlation:**
- Each recording session gets a unique session ID
- All logs for a session are correlated for easy per-session debugging

**Mandatory logging points:**
- Audio capture: device change, sample rate, buffer size, start/stop
- ASR engine: init duration, recognition duration, result length, error codes
- Text injection: target app, injection method (AX/clipboard), duration
- Cloud API: request latency, token count, HTTP status, retry count
- Cloud API Key: validation result, expiry events

**Log file management:**
- Single file max 5MB, retain 7 days max, auto-rotate
- One-click export for user bug reports (sanitized: remove target app names and other PII)

---

## 4. Distribution & Cloud ASR

### Distribution
- GitHub Releases + Sparkle 2 auto-update, open source
- Mac App Store and paid tiers later

### Cloud ASR (no subscription, user provides key)
- Alibaba Cloud Paraformer API direct connection
- API Key stored in Keychain
- User enters API Key in settings (like API client tools)
- Has Key → cloud engine available; no Key → local only
- No server-side key distribution, no subscription validation

### Privacy
- README states: primarily local processing, cloud mode sends audio to Alibaba Cloud
- No audio storage, transport only (ephemeral)

### Pre-release checklist
- App icon (professional design or placeholder)
- README: features + screenshots + install guide
- GitHub Actions CI: auto-build on every PR
- dmg packaging for distribution

---

## 5. Implementation Roadmap

### Phase 1 — ASR Quality
- Strengthen Paraformer integration
- Add `isStreaming` to `ASRService` protocol
- Non-real-time engines show waveform only during recording
- Engine auto-fallback on crash
- Enhanced logging for engine lifecycle

### Phase 2 — UX Redesign
- First-launch onboarding (3 steps)
- Overlay simplification: auto-fade, toast for injection failure
- Settings reduced to 2 tabs
- Remove emotion UI, toggle mode, language selection

### Phase 3 — Engineering Quality
- New test target, key path coverage
- Integrate Sentry (opt-out)
- Integrate Sparkle 2
- Full logging system (session ID, mandatory log points, file rotation, one-click export)

### Phase 4 — Release Preparation
- Cloud ASR integration (Alibaba Cloud Paraformer API, user-provided key)
- GitHub Actions CI
- dmg packaging + Sparkle distribution
- README + screenshots + app icon
- GitHub Releases v1.0

**Phase dependency:** 1 → 2 → 3 → 4, sequential. Verify each phase before proceeding.
