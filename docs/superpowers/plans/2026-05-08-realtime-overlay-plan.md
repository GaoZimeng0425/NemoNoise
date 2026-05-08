# Real-time Streaming + Persistent Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Apple Speech ASR display text in real-time while speaking, and keep the overlay visible after releasing Option.

**Architecture:** Rewrite `AppleSpeechASREngine` to use Apple's streaming recognition API (`shouldReportPartialResults = true`, live audio appending). Remove overlay auto-hide so it persists until manually closed.

**Tech Stack:** Swift, Speech framework (SFSpeechRecognizer), SwiftUI

---

### Task 1: Rewrite AppleSpeechASREngine for streaming

**Files:**
- Rewrite: `NemoNoise/AppleSpeechASREngine.swift` (full file)

- [ ] **Step 1: Rewrite AppleSpeechASREngine.swift**

Replace the entire file with the streaming implementation. Key changes:
- Remove `accumulated` array — no longer buffering audio
- Add `request: SFSpeechAudioBufferRecognitionRequest?` — lazily created on first `feedChunk()`
- Add `task: SFSpeechRecognitionTask?` — ongoing recognition task
- Add `latestPartial: String` — thread-safe, updated by recognition callback
- Add `finishContinuation: CheckedContinuation<TranscriptionResult, Error>?` — for awaiting final result
- `feedChunk()`: On first call, create request with `shouldReportPartialResults = true` and start recognition task. On every call, append audio to request and return current `latestPartial`.
- `finish()`: Call `request.endAudio()`, await final result via continuation.
- `reset()`: Cancel task, nil out request/task/continuation, clear partial.
- Use `OSAllocatedUnfairLock` for thread-safe access to `latestPartial`.

```swift
import Speech
import AVFoundation

final class AppleSpeechASREngine: ASRService, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishContinuation: CheckedContinuation<TranscriptionResult, Error>?
    private let partialLock = OSAllocatedUnfairLock(initialState: "")
    private var finalResult: TranscriptionResult?

    init() throws {
        let pref = LanguagePreference.current
        let resolved: SFSpeechRecognizer?

        if let localeId = pref.localeIdentifier {
            resolved = SFSpeechRecognizer(locale: Locale(identifier: localeId))
                ?? SFSpeechRecognizer(locale: .current)
                ?? SFSpeechRecognizer()
        } else {
            resolved = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
                ?? SFSpeechRecognizer(locale: .current)
                ?? SFSpeechRecognizer()
        }

        guard let resolved else {
            throw ASRError.engineUnavailable
        }
        recognizer = resolved
        LogService.info("locale: \(recognizer.locale.identifier)", category: "AppleSpeechASREngine")
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        // Lazily start recognition on first chunk
        guard recognizer.isAvailable else {
            throw ASRError.audioCaptureFailed("Speech recognizer not available")
        }

        if request == nil {
            guard await requestPermission() else {
                throw ASRError.audioCaptureFailed("Speech recognition permission denied")
            }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req

            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    self.partialLock.withLock { _ in }
                    if let cont = self.finishContinuation {
                        self.finishContinuation = nil
                        cont.resume(throwing: error)
                    }
                    return
                }
                if let result {
                    if result.isFinal {
                        let transcription = TranscriptionResult(
                            text: result.bestTranscription.formattedString,
                            isFinal: true,
                            emotion: nil
                        )
                        self.finalResult = transcription
                        if let cont = self.finishContinuation {
                            self.finishContinuation = nil
                            cont.resume(returning: transcription)
                        }
                    } else {
                        self.partialLock.withLock { partial in
                            partial = result.bestTranscription.formattedString
                        }
                    }
                }
            }
        }

        // Append audio to the live request
        if let buffer = makePCMBuffer(from: samples, sampleRate: sampleRate) {
            request?.append(buffer)
        }

        // Return current partial text
        let partial = partialLock.withLock { $0 }
        return TranscriptionResult(text: partial, isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        // If we already got a final result (e.g. from auto-checkpoint), return it
        if let final = finalResult {
            finalResult = nil
            return final
        }

        request?.endAudio()

        // If there's an active task, wait for its final callback
        if task != nil {
            return try await withCheckedThrowingContinuation { continuation in
                self.finishContinuation = continuation
            }
        }

        // No task was started (no audio received)
        return TranscriptionResult(text: "", isFinal: true, emotion: nil)
    }

    func reset() {
        task?.cancel()
        task = nil
        request = nil
        finishContinuation = nil
        finalResult = nil
        partialLock.withLock { $0 = "" }
    }

    private func makePCMBuffer(from samples: [Float], sampleRate: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }
        let count = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        buffer.frameLength = count
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress, let channelData = buffer.floatChannelData else { return }
            channelData[0].update(from: base, count: samples.count)
        }
        return buffer
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
```

- [ ] **Step 2: Build and verify compilation**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug build`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/AppleSpeechASREngine.swift
git commit -m "feat: rewrite AppleSpeechASREngine for real-time streaming partial results"
```

---

### Task 2: Fix overlay persistence + wire up close button

**Files:**
- Modify: `NemoNoise/RecordingController.swift` (line 203 — remove auto-hide)
- Modify: `NemoNoise/OverlayView.swift` (line 99-106 — wire close button action)

- [ ] **Step 1: Remove auto-hide in stopRecording**

In `RecordingController.swift`, change the `defer` block in `stopRecording()` (line 200-204) from:

```swift
defer {
    recordingState = .idle
    engine = nil
    if !showCopyButton { hideOverlay() }
}
```

to:

```swift
defer {
    recordingState = .idle
    engine = nil
}
```

This removes the automatic `hideOverlay()` call. The overlay now stays visible after recording ends.

- [ ] **Step 2: Wire up close button in OverlayView**

In `OverlayView.swift`, change the close button action (line 99) from an empty closure to call a dismiss action. Add a `dismissOverlay()` method to `RecordingController` and call it from the button.

First, add this method to `RecordingController.swift` (after the `copyToClipboard()` method):

```swift
func dismissOverlay() {
    confirmedSegments = []
    partialText = ""
    showCopyButton = false
    hideOverlay()
}
```

Then, in `OverlayView.swift`, update the close button action (line 99-101):

```swift
private var closeButton: some View {
    Button {
        controller.dismissOverlay()
    } label: {
        Image(systemName: "xmark")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
}
```

- [ ] **Step 3: Build and verify compilation**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug build`
Expected: Build succeeds with no errors.

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/RecordingController.swift NemoNoise/OverlayView.swift
git commit -m "fix: keep overlay visible after recording, wire up close button"
```

---

## Manual Testing Checklist

After implementing both tasks, verify manually:

1. **Hold Option and speak** — text should appear in overlay in real-time, character by character
2. **Release Option** — overlay should remain visible with final text
3. **Text injected into target app** — check the focused text field has the recognized text
4. **Close button works** — click X button, overlay disappears
5. **New recording resets** — hold Option again, previous text clears, new text streams in
6. **Copy button still works** — if injection fails, "Copy to Clipboard" button appears and works
7. **Toggle mode** — press Option to start, press again to stop, overlay stays visible
