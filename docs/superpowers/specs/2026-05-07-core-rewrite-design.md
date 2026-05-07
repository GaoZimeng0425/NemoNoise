# NemoNoise Core Rewrite — Stability & Performance

**Date:** 2026-05-07
**Scope:** Fix 10 critical/high-priority issues via core module rewrite
**Status:** Approved

---

## Problem Statement

NemoNoise has 5 crash-level issues (force unwraps, data races), 2 memory/performance issues (unbounded buffer growth, O(n) decoding), and 3 UX/release issues (hardcoded strings, wrong version, wrong bundle ID). These must be fixed before the app is safe for daily use.

---

## Design

### Layer 1: Concurrency Architecture Rewrite

**RecordingController → @MainActor @Observable class**

Add `@MainActor` annotation to `RecordingController`. All `@Observable` properties (`recordingState`, `micLevel`, `partialText`, `confirmedSegments`, `showErrorAlert`, `errorMessage`) will be main-actor isolated automatically. The recording loop (`startRecording()` method) runs as a `Task` on the main actor, so mutations to UI state no longer need explicit `await MainActor.run {}` dispatches. The `engine` property is also managed on the main actor, eliminating cross-thread references.

Key constraint: `RecordingController` must remain a `class` (not an `actor`) because `@Observable` macro requires it. `@MainActor` provides the same serialization guarantee for our purposes.

**HotkeyMonitor → OSAllocatedUnfairLock for shared state**

Wrap `optionWasDown` and `lastKeyTime` in a struct protected by `OSAllocatedUnfairLock<State>`. The CGEvent tap callback is a C function pointer context — it cannot use `await` or actor isolation. `OSAllocatedUnfairLock` is lightweight, works from any thread context, and is the standard Swift concurrency pattern for C callback interop.

```swift
private struct State {
    var optionWasDown = false
    var lastKeyTime: TimeInterval = 0
}
private let lock = OSAllocatedUnfairLock(initialState: State())
```

**AudioCapture.ContinuationBox → OSAllocatedUnfairLock**

Replace the bare `var value` with a lock-protected property. The audio tap callback writes from the audio thread; `stop()` reads from the main thread. `os_unfair_lock` is safe from any thread context including audio realtime threads.

```swift
private final class ContinuationBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<AsyncStream<AudioChunk>.Continuation?>(initialState: nil)
    var value: AsyncStream<AudioChunk>.Continuation? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
```

**AppleSpeechASREngine → Eliminate force unwrap**

Replace `SFSpeechRecognizer()!` with `guard let` + throwing an `ASRError.engineUnavailable`. The initializer chain tries the preferred locale, then the current locale, then the default. If all fail, throw rather than crash.

**SherpaOnnxWrapper → Eliminate force unwrap**

Replace `SherpaOnnxCreateOfflineStream(recognizer)!` with `guard let` + returning `nil` from the stream factory. The caller (`SherpaASREngine`) handles nil by throwing `ASRError.engineInitFailed`.

### Layer 2: Memory & Performance

**accumulatedSamples cleanup after checkpoint**

In `RecordingController.startRecording()`, after the auto-checkpoint at 120 seconds:
1. Call `finish()` on the current engine to get final text
2. Clear `accumulatedSamples` with `removeAll(keepingCapacity: true)` — reuses allocated memory
3. Create a new engine instance
4. Continue recording

This caps memory at ~30MB per checkpoint cycle instead of growing unbounded.

**SherpaASREngine incremental decode scheduling**

Add `lastDecodeCount: Int` tracking. Only invoke `recognizer.decode()` when at least 16,000 new samples have accumulated (~1 second). Run the decode in `Task.detached` to avoid blocking the cooperative thread pool.

The offline model still requires full-buffer decoding (no incremental mode available), but reducing decode frequency from every-chunk to every-second significantly reduces CPU usage. Combined with the 120s auto-checkpoint reset, buffer size is bounded.

**ModelManager.downloadTasks cleanup**

After a download task completes (success or failure), remove it from the `downloadTasks` dictionary. Use a `defer` block in the task body to ensure cleanup on all exit paths.

### Layer 3: UX & Release Fixes

**Dynamic hotkey display text**

Add a computed property that returns the correct hotkey name based on `hotkeyOption` setting. Use it in `ContentView` popover text and `OverlayView` hint text.

- Push-to-talk mode: "Hold **Option** to record" / "Hold **Right ⌘** to record"
- Toggle mode: "Press **Option** to start/stop" / "Press **Right ⌘** to start/stop"

**Version from Bundle**

Replace hardcoded `"0.1.0"` with `Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"`.

**Bundle ID correction**

Change `com.nemo.BrightnessApp.NemoNoise` to `com.nemo.NemoNoise` in `project.pbxproj`.

**Audio error surfacing**

When audio capture fails (catch block in `startRecording()`), set `showErrorAlert = true` and `errorMessage` in addition to `lastError`, so the user sees an alert instead of silent failure.

**Auto-checkpoint error handling**

Replace `try?` with `do/catch`. On failure, set `showErrorAlert = true` with a descriptive message. Don't abort the recording — checkpoint failure is non-fatal.

---

## Files Changed

| File | Changes |
|------|---------|
| `RecordingController.swift` | Add `@MainActor`, fix checkpoint cleanup, fix error handling, add dynamic hotkey text |
| `HotkeyMonitor.swift` | Add `OSAllocatedUnfairLock<State>`, protect shared state |
| `AudioCapture.swift` | Lock-protect `ContinuationBox.value` |
| `SherpaASREngine.swift` | Incremental decode scheduling, `Task.detached` for decode |
| `SherpaOnnxWrapper.swift` | Replace force unwrap with `guard let` |
| `AppleSpeechASREngine.swift` | Replace force unwrap with `guard let` + throw |
| `ModelManager.swift` | Clean up completed download tasks |
| `ContentView.swift` | Dynamic hotkey text, version from Bundle |
| `OverlayView.swift` | Dynamic hotkey text |
| `NemoNoise.xcodeproj/project.pbxproj` | Fix Bundle ID |

---

## Out of Scope

- Transcription history/persistence
- Auto-start at login
- UI localization
- Overlay appearance customization
- Auto-update mechanism (Sparkle)
- Custom vocabulary
- System notifications
- CI/CD pipeline

These are valid improvements but separate from the stability fix scope.
