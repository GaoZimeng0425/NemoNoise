# Real-time Audio Translation Design

## Overview

Turn NemoNoise into a real-time voice translation tool. Capture system audio (e.g. YouTube, Zoom), recognize English speech via ASR, translate to Chinese locally, and display bilingual subtitles in a floating overlay bar at the bottom of the screen.

**Scope**: English → Chinese only, fully local/offline, no cloud services.

## Architecture & Data Flow

```
System Audio → ScreenCaptureKit → Audio Format Conversion (16kHz mono)
                                           │
                                           ▼
                                 ASR Engine (English) → English Text
                                                              │
                                                              ▼
                                                   Apple Translation (en→zh)
                                                              │
                                                              ▼
                                                   Subtitle Overlay UI
                                                  (English + Chinese)
```

**New modules:**

1. **SystemAudioCapture** — Wraps ScreenCaptureKit, captures system audio, converts to 16kHz mono PCM, outputs `AsyncStream<AudioChunk>` (same interface as existing `AudioCapture`)
2. **TranslationService** — Wraps Apple Translation framework, translates English text to Chinese
3. **SubtitleOverlay** — New subtitle bar UI, replaces the overlay during translation mode, shows bilingual scrolling text
4. **TranslationController** — Orchestrates audio capture → ASR → translation → display pipeline

**Reused modules:**

- ASR engines (Paraformer streaming or Apple Speech, configured for English)
- HotkeyMonitor (toggle mode trigger)
- MenubarView (new translation mode menu item)

**Permission changes:**

- New: Screen Recording permission (required by ScreenCaptureKit)
- Existing: Accessibility (kept for dictation mode), Microphone (kept for dictation mode)

## SystemAudioCapture

**Responsibility**: Capture system audio, output 16kHz mono float32 `AsyncStream<AudioChunk>`, matching existing `AudioCapture` interface so ASR engines need no changes.

**Implementation:**

1. **Permission**: ScreenCaptureKit requires Screen Recording permission (`CGPreflightScreenCaptureAccess()`). First-time use triggers system dialog guiding user to authorize.

2. **Capture flow**:
   - Get `SCShareableContent` for current displays
   - Create `SCStreamConfiguration`: `capturesAudio = true`, `sampleRate = 48000`, `channelCount = 1`
   - `SCStream` with `SCStreamDelegate`, receive audio in `didOutputSampleBuffer` callback
   - `AVAudioConverter` to resample 48kHz → 16kHz (same logic as existing `AudioCapture`)

3. **Audio source**: Captures system audio output only (no microphone). ScreenCaptureKit's audio capture is the system audio output stream.

4. **Lifecycle**:
   - `start()` → request permission → create stream → begin capture
   - `stop()` → stop stream → clean up resources
   - Supports repeated start/stop (translation mode toggle)

5. **Relationship to AudioCapture**: Independent class, but outputs same `AsyncStream<AudioChunk>` type. ASR engines consume via protocol, unaware of audio source.

**Edge cases:**
- User denies screen recording permission → prompt and guide to System Settings
- No audio playing → ASR receives silence frames, no error
- Bluetooth headset latency → no special handling, translation naturally has latency

## TranslationService

**Responsibility**: Receive English text, return Chinese translation.

**Interface:**

```swift
protocol TranslationService {
    func translate(_ text: String) async throws -> String
}
```

**Implementation:**

1. Apple Translation framework: `import Translation`, `TranslationSession` with `TranslationConfiguration(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))`

2. **Language pack handling**: Apple Translation checks for downloaded language packs on first use. If not downloaded, guide user through download via system dialog or Settings UI prompt.

3. **Invocation timing**:
   - Translate only on ASR final results (not partial/streaming results)
   - Translation is async, does not block ASR from continuing to process audio

4. **Degradation**: Translation failure → subtitle bar shows English only, Chinese line displays "—". No cloud fallback (fully local).

5. **Performance**: Apple Translation runs on-device, typically 100-500ms latency. No throttling or batching needed.

## SubtitleOverlay

**Responsibility**: Display bilingual subtitles at the bottom of the screen, updating in real-time.

**Visual layout:**

```
┌─────────────────────────────────────────────────┐
│  The weather is really nice today.               │  ← English, smaller font
│  今天天气真的很好。                                 │  ← Chinese, larger font
└─────────────────────────────────────────────────┘
         (semi-transparent dark background, rounded corners, bottom-center)
```

**Window properties:**

- `NSPanel`, `.floating` level (always on top)
- Semi-transparent dark background (`.ultraThickMaterial`, wider and flatter than existing overlay)
- Non-activating window (doesn't steal focus)
- Width: 60-80% of screen width, max 900px
- Position: bottom of screen, 80px from bottom edge (above Dock)

**Content layout:**

- Top line: English original, gray text, 14pt
- Bottom line: Chinese translation, white text, 16pt
- 4px spacing between lines, 12px padding overall
- Text left-aligned, auto-wrapping (max 3 lines, truncate beyond)

**Update behavior:**

- Each ASR final result replaces current content (no append/scroll)
- New result directly replaces old content

**Status indicators:**

- Left dot: green = listening, gray = paused
- During translation: Chinese line shows loading animation (bouncing dots)

**Interaction:**

- Not draggable, not clickable (display only)
- `ignoresMouseEvents = true` (mouse events pass through to underlying windows)
- Toggle via keyboard shortcut or menu bar

**Relationship to OverlayWindowController:**

- Independent `SubtitleOverlayController`
- Translation mode and dictation mode are mutually exclusive — translation mode active means dictation overlay doesn't appear

## TranslationController & User Interaction

**Responsibility**: Coordinate the translation mode lifecycle.

**States (user-visible):** Off → Listening → Translating

**Internal state machine:**

```
IDLE → (start) → REQUESTING_PERMISSION → CAPTURING → TRANSLATING → (stop) → IDLE
                       │                      │             │
                       ▼                      ▼             ▼
                  PERMISSION_DENIED        ASR_ERROR    TRANSLATION_ERROR
                       │                      │             │
                       ▼                      ▼             ▼
                     IDLE                  CAPTURING     CAPTURING
                                         (continue)   (show original only)
```

**Activation:**

1. **Menu bar**: New "Translation Mode" toggle item in MenubarView with status icon
2. **Keyboard shortcut**: New `KeyboardShortcuts.Name.translationMode`, toggle (press once to start, again to stop)

**Start flow:**

1. User triggers translation mode
2. Check Screen Recording permission → prompt if not granted
3. Check Apple Translation language pack → prompt download if needed
4. Create SystemAudioCapture, start capture
5. ASR engine (Apple Speech `en-US` preferred, Paraformer streaming fallback) begins recognition
6. Show SubtitleOverlay
7. ASR final result → TranslationService.translate → update subtitle bar

**Stop flow:**

1. User triggers again (menu bar or hotkey)
2. Stop SystemAudioCapture
3. Hide SubtitleOverlay
4. Return to IDLE

**ASR engine choice for translation mode:**

- Prefer Apple Speech (`en-US` locale) — native English streaming recognition, no extra model download
- Fallback to Paraformer streaming (bilingual zh+en) if Apple Speech unavailable

**Relationship to dictation mode:**

- Translation mode and dictation mode are mutually exclusive
- Translation mode active → dictation hotkey ignored (or auto-stop translation first)
- Menu bar clearly shows current mode to avoid confusion

## Permissions, Error Handling & Testing

**Permission checks (on first use):**

1. Screen Recording (new) → `CGPreflightScreenCaptureAccess()`, `CGRequestScreenCaptureAccess()` if not granted
2. Accessibility (existing) → reuse existing check
3. Microphone (existing, not needed in translation mode) → skip in translation mode

Settings UI: new "Translation Mode Permissions" section showing authorization status for each permission.

**Error handling:**

| Scenario | Response |
|----------|----------|
| Screen Recording not authorized | Dialog guiding to System Settings, don't enter translation mode |
| Apple Translation language pack not downloaded | System auto-prompts download on first translation |
| ASR recognition failure | Silent skip, wait for next audio segment |
| Translation failure | Show English only, Chinese line shows "—" |
| No system audio output | Normal operation, ASR processes silence, no text produced |
| Permission revoked mid-session | Detect capture failure, auto-stop translation mode, toast notification |

**Testing strategy:**

- **SystemAudioCapture**: Mock `SCStream` callbacks, verify audio format conversion
- **TranslationService**: Mock `TranslationSession`, verify translation calls and degradation logic
- **TranslationController**: State machine tests, verify start/stop/error paths
- **SubtitleOverlay**: SwiftUI Preview for layout verification
- **Integration**: Manual testing — play English video → see Chinese subtitles
