# Real-time Streaming Text + Persistent Overlay

## Problem

1. Apple Speech ASR engine does not display text while speaking — text only appears after releasing Option
2. Overlay disappears immediately after releasing Option — user cannot review the recognized text

## Solution

Two changes, minimal scope:

### 1. Rewrite AppleSpeechASREngine for streaming

Rewrite `AppleSpeechASREngine.swift` to use Apple's real-time streaming API instead of accumulating audio and processing at the end.

**Protocol unchanged** (`ASRService` stays the same).

**Internal architecture:**

- `request: SFSpeechAudioBufferRecognitionRequest` — created lazily on first `feedChunk()` call, persists throughout recording
- `task: SFSpeechRecognitionTask` — single ongoing recognition task with `shouldReportPartialResults = true`
- `latestPartial: String` — updated by recognition task callback on each partial result
- `finishContinuation` — used by `finish()` to await the final result

**Lifecycle:**

1. First `feedChunk()` — lazily create request + recognition task. Recognition task callback updates `latestPartial` on each partial result
2. Subsequent `feedChunk()` — append audio to request, return current `latestPartial`
3. `finish()` — call `request.endAudio()`, await final result via continuation
4. `reset()` — cancel task, clear all state

### 2. Overlay persists after recording

Remove auto-hide in `RecordingController.stopRecording()`. The `defer` block currently calls `hideOverlay()` when `showCopyButton` is false — remove this so overlay always stays visible after recording ends.

Overlay closes via existing UI: close button or copy button. Next recording naturally resets content.

## Files Changed

| File | Change |
|------|--------|
| `AppleSpeechASREngine.swift` | Full rewrite to streaming mode |
| `RecordingController.swift` | Remove auto-hide in `stopRecording()` defer block (~1 line) |

## Not Changed

- `ASRService` protocol
- `RecordingController.feedChunk` call pattern
- Other ASR engines (Sherpa, Paraformer)
- Overlay UI (`OverlayView.swift`)
- Push-to-talk interaction model
