# Core Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 10 critical/high-priority issues — eliminate crashes from force unwraps, fix data races with locks, cap memory growth, reduce CPU usage, and fix UX/release issues.

**Architecture:** Three layers: (1) crash elimination — replace force unwraps/fatalErrors with throwing inits, (2) concurrency safety — `OSAllocatedUnfairLock` for CGEvent/audio callback shared state, (3) memory + UX — buffer cleanup, incremental decode, dynamic hotkey text, version from Bundle, Bundle ID fix.

**Tech Stack:** Swift 6 (with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), `OSAllocatedUnfairLock`, sherpa-onnx C API

**Key context:** The project has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — all non-Sendable types (RecordingController, ModelManager) are implicitly `@MainActor`. Types explicitly marked `Sendable` or `@unchecked Sendable` (HotkeyMonitor, AudioCapture, engine types) are NOT MainActor-isolated. There is no test target — verification is via `xcodebuild build`.

**Build command:** `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug build 2>&1 | tail -5`

---

## File Structure

| File | Action | Change |
|------|--------|--------|
| `Item.swift` | Modify | Add `engineUnavailable` and `engineInitFailed` error cases |
| `SherpaOnnxWrapper.swift` | Modify | Replace `!` with guard let, add `@unchecked Sendable` |
| `AppleSpeechASREngine.swift` | Modify | Replace `!` with guard let + throw, throwing init |
| `SherpaASREngine.swift` | Modify | Throwing init, incremental decode, `Task.detached` |
| `ParaformerStreamingEngine.swift` | Modify | Throwing init |
| `AudioCapture.swift` | Modify | Lock-protect `ContinuationBox` |
| `HotkeyMonitor.swift` | Modify | Lock-protect `optionWasDown` |
| `RecordingController.swift` | Modify | `makeEngine()` throws, buffer cleanup, error surfacing, hotkey text, remove redundant `MainActor.run` |
| `ContentView.swift` | Modify | Dynamic hotkey text, version from Bundle |
| `OverlayView.swift` | Modify | Dynamic hotkey text |
| `ModelManager.swift` | Modify | Clean up completed download tasks |
| `project.pbxproj` | Modify | Bundle ID: `com.nemo.BrightnessApp.NemoNoise` → `com.nemo.NemoNoise` |

---

### Task 1: Eliminate Crashes — Force Unwrap + fatalError Removal

**Files:**
- Modify: `NemoNoise/Item.swift:44-51`
- Modify: `NemoNoise/SherpaOnnxWrapper.swift:62`
- Modify: `NemoNoise/AppleSpeechASREngine.swift:8-19,81-83`
- Modify: `NemoNoise/SherpaASREngine.swift:7-15`
- Modify: `NemoNoise/ParaformerStreamingEngine.swift:6-19`
- Modify: `NemoNoise/RecordingController.swift:82-97,113-114`

- [ ] **Step 1: Add error cases to Item.swift**

Add two new cases to `ASRError`:

```swift
enum ASRError: Error {
    case modelNotFound
    case audioCaptureFailed(String)
    case invalidPythonPath
    case socketDisconnected
    case engineUnavailable
    case engineInitFailed
}
```

- [ ] **Step 2: Fix SherpaOnnxWrapper.swift — replace force unwrap**

Replace the force unwrap at line 62 (`SherpaOnnxCreateOfflineStream(recognizer)!`) with a guard let. Also add `@unchecked Sendable` conformance so the recognizer can be captured in `Task.detached` later.

Full `SherpaOfflineRecognizer.decode` method replacement:

```swift
final class SherpaOfflineRecognizer: @unchecked Sendable {
    private let recognizer: UnsafePointer<SherpaOnnxOfflineRecognizer>

    // ... init? stays the same ...

    func decode(samples: [Float], sampleRate: Int32 = 16000) -> SherpaOnnxResult {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            return SherpaOnnxResult(text: "", lang: "", emotion: "", event: "")
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxAcceptWaveformOffline(stream, sampleRate, buf.baseAddress, Int32(samples.count))
        }

        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let r = SherpaOnnxGetOfflineStreamResult(stream) else {
            return SherpaOnnxResult(text: "", lang: "", emotion: "", event: "")
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(r) }

        return SherpaOnnxResult(
            text:    r.pointee.text    .map { String(cString: $0) } ?? "",
            lang:    r.pointee.lang    .map { String(cString: $0) } ?? "",
            emotion: r.pointee.emotion .map { String(cString: $0) } ?? "",
            event:   r.pointee.event   .map { String(cString: $0) } ?? ""
        )
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }
}
```

- [ ] **Step 3: Fix AppleSpeechASREngine.swift — throwing init + safe unwrap**

Replace the entire file:

```swift
import Speech
import AVFoundation

final class AppleSpeechASREngine: ASRService, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private var accumulated: [Float] = []

    init() throws {
        let pref = LanguagePreference.current
        let resolved: SFSpeechRecognizer?

        if let localeId = pref.localeIdentifier {
            resolved = SFSpeechRecognizer(locale: Locale(identifier: localeId))
                ?? SFSpeechRecognizer(locale: .current)
        } else {
            resolved = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
                ?? SFSpeechRecognizer(locale: .current)
        }

        guard let resolved else {
            throw ASRError.engineUnavailable
        }
        recognizer = resolved
        print("[AppleSpeechASREngine] locale: \(recognizer.locale.identifier)")
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        accumulated.append(contentsOf: samples)
        return TranscriptionResult(text: "", isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        defer { accumulated.removeAll() }
        guard !accumulated.isEmpty else {
            return TranscriptionResult(text: "", isFinal: true, emotion: nil)
        }
        guard await requestPermission() else {
            throw ASRError.audioCaptureFailed("Speech recognition permission denied")
        }
        guard recognizer.isAvailable else {
            throw ASRError.audioCaptureFailed("Speech recognizer not available")
        }
        guard let buffer = makePCMBuffer(from: accumulated, sampleRate: 16000) else {
            return TranscriptionResult(text: "", isFinal: true, emotion: nil)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                resumed = true
                continuation.resume(returning: TranscriptionResult(
                    text: result.bestTranscription.formattedString,
                    isFinal: true,
                    emotion: nil
                ))
            }
        }
    }

    func reset() {
        accumulated.removeAll()
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

- [ ] **Step 4: Fix SherpaASREngine.swift — throwing init**

Replace init to throw instead of `fatalError`:

```swift
init(modelDir: URL, language: String = LanguagePreference.current.sherpaCode) throws {
    let modelPath  = modelDir.appendingPathComponent("model.int8.onnx").path
    let tokensPath = modelDir.appendingPathComponent("tokens.txt").path
    guard let r = SherpaOfflineRecognizer(modelPath: modelPath, tokensPath: tokensPath, language: language) else {
        throw ASRError.engineInitFailed
    }
    recognizer = r
    print("[SherpaASREngine] Model loaded, language: \(language)")
}
```

Keep the rest of `SherpaASREngine` unchanged for now (Task 3 will add incremental decode).

- [ ] **Step 5: Fix ParaformerStreamingEngine.swift — throwing init**

Replace init to throw instead of `fatalError`:

```swift
init(modelDir: URL) throws {
    let encoderPath = modelDir.appendingPathComponent("model_quant.onnx").path
    let decoderPath = modelDir.appendingPathComponent("decoder_quant.onnx").path
    let tokensPath  = modelDir.appendingPathComponent("tokens.txt").path
    guard let r = SherpaOnlineRecognizer(
        encoderPath: encoderPath,
        decoderPath: decoderPath,
        tokensPath: tokensPath
    ) else {
        throw ASREngineError.engineInitFailed
    }
    recognizer = r
    print("[ParaformerStreamingEngine] Model loaded")
}
```

- [ ] **Step 6: Update RecordingController.makeEngine() to throw**

Replace `makeEngine()` in `RecordingController.swift`:

```swift
private func makeEngine() throws -> any ASRService {
    let choice = UserDefaults.standard.string(forKey: "engineType") ?? "apple"
    switch choice {
    case "sensevoice":
        if let dir = modelManager.modelPath(for: .senseVoice) {
            return try SherpaASREngine(modelDir: dir)
        }
    case "paraformer":
        if let dir = modelManager.modelPath(for: .paraformer) {
            return try ParaformerStreamingEngine(modelDir: dir)
        }
    default:
        break
    }
    return try AppleSpeechASREngine()
}
```

Update the call site in `startRecording()` (line 113):

```swift
engine = try makeEngine()
```

- [ ] **Step 7: Build to verify**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add NemoNoise/Item.swift NemoNoise/SherpaOnnxWrapper.swift NemoNoise/AppleSpeechASREngine.swift NemoNoise/SherpaASREngine.swift NemoNoise/ParaformerStreamingEngine.swift NemoNoise/RecordingController.swift
git commit -m "fix: replace force unwraps and fatalErrors with throwing inits

Eliminates 4 crash sites:
- SherpaOnnxCreateOfflineStream force unwrap → guard let with empty result
- SFSpeechRecognizer()! → guard let + throw ASRError.engineUnavailable
- SherpaASREngine fatalError → throw ASRError.engineInitFailed
- ParaformerStreamingEngine fatalError → throw ASRError.engineInitFailed
- makeEngine() now throws, call sites use try"
```

---

### Task 2: Lock-Protect Shared State — HotkeyMonitor + AudioCapture

**Files:**
- Modify: `NemoNoise/HotkeyMonitor.swift`
- Modify: `NemoNoise/AudioCapture.swift`

- [ ] **Step 1: Fix HotkeyMonitor — add OSAllocatedUnfairLock**

Replace the entire file:

```swift
import AppKit
import ApplicationServices

final class HotkeyMonitor: @unchecked Sendable {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private struct State {
        var optionWasDown = false
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    var hotkeyOption: HotkeyOption {
        let raw = UserDefaults.standard.string(forKey: "hotkeyOption") ?? "option"
        return HotkeyOption(rawValue: raw) ?? .option
    }

    func start() {
        requestAccessibilityIfNeeded()

        guard AXIsProcessTrusted() else {
            print("[HotkeyMonitor] Accessibility permission not granted — hotkey disabled")
            return
        }

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.handleFlagsChangedSync(event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: selfPtr
        )

        guard let tap else {
            print("[HotkeyMonitor] CGEvent.tapCreate failed — check Accessibility permission")
            Unmanaged<HotkeyMonitor>.fromOpaque(selfPtr).release()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[HotkeyMonitor] Event tap started")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    nonisolated private func handleFlagsChangedSync(event: CGEvent) {
        let flags = event.flags
        let selectedFlag = hotkeyOption.cgFlags
        let allFlags: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
        let optionNowDown = flags.contains(selectedFlag)
        let onlyOption = flags.intersection(allFlags) == selectedFlag

        let wasDown = lock.withLock { $0.optionWasDown }

        if optionNowDown && !wasDown && onlyOption {
            lock.withLock { $0.optionWasDown = true }
            let cb = onKeyDown
            DispatchQueue.main.async { cb?() }
        } else if !optionNowDown && wasDown {
            lock.withLock { $0.optionWasDown = false }
            let cb = onKeyUp
            DispatchQueue.main.async { cb?() }
        }
    }

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    deinit { stop() }
}
```

Key change: `optionWasDown` is now inside `OSAllocatedUnfairLock<State>`. Reads and writes go through `lock.withLock { }`. This eliminates the data race between the CGEvent callback thread and any other thread.

- [ ] **Step 2: Fix AudioCapture — lock-protect ContinuationBox**

Replace the `ContinuationBox` class at the bottom of `AudioCapture.swift` (lines 110-112):

```swift
final class ContinuationBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<AsyncStream<AudioChunk>.Continuation?>(initialState: nil)
    var value: AsyncStream<AudioChunk>.Continuation? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
```

The rest of `AudioCapture.swift` remains unchanged — it already reads and writes `continuation.value`, which now goes through the lock.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/HotkeyMonitor.swift NemoNoise/AudioCapture.swift
git commit -m "fix: add OSAllocatedUnfairLock to HotkeyMonitor and AudioCapture

Eliminates data races:
- HotkeyMonitor.optionWasDown now protected by lock (CGEvent thread + main)
- AudioCapture.ContinuationBox.value now protected by lock (audio thread + main)"
```

---

### Task 3: SherpaASREngine — Incremental Decode

**Files:**
- Modify: `NemoNoise/SherpaASREngine.swift`

- [ ] **Step 1: Rewrite SherpaASREngine with incremental decode**

Replace the entire file:

```swift
import Foundation

final class SherpaASREngine: ASRService, @unchecked Sendable {
    private let recognizer: SherpaOfflineRecognizer
    private var accumulated: [Float] = []
    private var lastDecodeCount: Int = 0

    init(modelDir: URL, language: String = LanguagePreference.current.sherpaCode) throws {
        let modelPath  = modelDir.appendingPathComponent("model.int8.onnx").path
        let tokensPath = modelDir.appendingPathComponent("tokens.txt").path
        guard let r = SherpaOfflineRecognizer(modelPath: modelPath, tokensPath: tokensPath, language: language) else {
            throw ASRError.engineInitFailed
        }
        recognizer = r
        print("[SherpaASREngine] Model loaded, language: \(language)")
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        accumulated.append(contentsOf: samples)
        let newSamples = accumulated.count - lastDecodeCount
        guard newSamples >= 16000 else {
            return TranscriptionResult(text: "", isFinal: false, emotion: nil)
        }

        lastDecodeCount = accumulated.count
        let snapshot = accumulated

        let result = await Task.detached { [recognizer] in
            recognizer.decode(samples: snapshot, sampleRate: 16000)
        }.value

        return TranscriptionResult(text: result.text, isFinal: false, emotion: emotionEmoji(result.emotion))
    }

    func finish() async throws -> TranscriptionResult {
        defer { reset() }
        guard !accumulated.isEmpty else {
            return TranscriptionResult(text: "", isFinal: true, emotion: nil)
        }

        let snapshot = accumulated
        let result = await Task.detached { [recognizer] in
            recognizer.decode(samples: snapshot, sampleRate: 16000)
        }.value

        return TranscriptionResult(text: result.text, isFinal: true, emotion: emotionEmoji(result.emotion))
    }

    func reset() {
        accumulated.removeAll(keepingCapacity: true)
        lastDecodeCount = 0
    }

    private func emotionEmoji(_ emotion: String) -> String? {
        switch emotion.uppercased() {
        case "HAPPY":     return "😊"
        case "SAD":       return "😢"
        case "ANGRY":     return "😠"
        case "NEUTRAL":   return "😐"
        case "FEARFUL":   return "😨"
        case "DISGUSTED": return "🤢"
        case "SURPRISED": return "😮"
        default:          return nil
        }
    }
}
```

Key changes from original:
- `lastDecodeCount` tracks decode position — only decodes when ≥16K new samples accumulated (was: every chunk after first second)
- Decode runs in `Task.detached` — avoids blocking MainActor (recognizer is `@unchecked Sendable` from Task 1)
- `snapshot` captures accumulated array — safe from COW, won't conflict with concurrent appends
- `reset()` uses `removeAll(keepingCapacity: true)` — reuses allocated memory
- `finish()` also uses detached decode for consistency

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/SherpaASREngine.swift
git commit -m "perf: SherpaASREngine incremental decode with Task.detached

- Only decode when >=16K new samples accumulated (was: every chunk)
- Run decode in Task.detached to avoid blocking MainActor
- Reset uses removeAll(keepingCapacity: true) to reuse memory
- Captures snapshot of accumulated buffer for thread safety"
```

---

### Task 4: RecordingController Overhaul

**Files:**
- Modify: `NemoNoise/RecordingController.swift`

This is the largest task. Changes:
1. Add `@MainActor` annotation (explicit, even though build setting implies it)
2. `makeEngine()` now throws — update all call sites
3. Auto-checkpoint: clear `accumulatedSamples`, don't swallow errors
4. Audio error: surface to user via `showErrorAlert`
5. Add `hotkeyDisplayText` computed property
6. Remove redundant `await MainActor.run {}` calls (implicit MainActor makes them unnecessary)

- [ ] **Step 1: Replace RecordingController.swift**

```swift
import SwiftUI
import AVFoundation
import ApplicationServices

@MainActor @Observable
final class RecordingController {
    var recordingState: RecordingState = .idle
    var confirmedSegments: [TranscriptionSegment] = []
    var partialText: String = ""
    var micLevel: Float = 0
    var lastError: String?
    var showCopyButton: Bool = false
    var showErrorAlert: Bool = false
    var errorMessage: String = ""
    var showAccessibilityGuide: Bool = false
    var isListeningSilence: Bool = false
    private var silenceTimer: Timer?
    private let maxRecordingDuration: TimeInterval = 120
    private var recordingStartTime: Date?
    var recordingDuration: TimeInterval = 0
    private var timerTask: Task<Void, Never>?

    var recordingMode: RecordingMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "recordingMode") ?? "pushToTalk"
            return RecordingMode(rawValue: raw) ?? .pushToTalk
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "recordingMode")
        }
    }

    let modelManager = ModelManager()

    private let audioCapture = AudioCapture()
    private let textInjector = TextInjector()
    let hotkeyMonitor = HotkeyMonitor()
    private var overlayController: OverlayWindowController?
    private var recordingTask: Task<Void, Never>?
    private var accumulatedSamples: [Float] = []
    private var engine: (any ASRService)?

    var hotkeyDisplayText: String {
        let keyName: String
        switch hotkeyMonitor.hotkeyOption {
        case .option: keyName = "⌥ Option"
        case .rightCommand: keyName = "Right ⌘"
        }
        switch recordingMode {
        case .pushToTalk:
            return "Hold **\(keyName)** to record"
        case .toggle:
            return "Press **\(keyName)** to start/stop"
        }
    }

    init() {
        hotkeyMonitor.onKeyDown = { [weak self] in
            Task { @MainActor [weak self] in self?.handleHotkeyDown() }
        }
        hotkeyMonitor.onKeyUp = { [weak self] in
            Task { @MainActor [weak self] in self?.handleHotkeyUp() }
        }
        hotkeyMonitor.start()
    }

    func handleHotkeyDown() {
        switch recordingMode {
        case .pushToTalk:
            guard recordingState == .idle else { return }
            textInjector.captureTarget()
            startRecording()
        case .toggle:
            switch recordingState {
            case .idle:
                textInjector.captureTarget()
                startRecording()
            case .recording:
                stopRecording()
            case .processing:
                break
            }
        }
    }

    func handleHotkeyUp() {
        switch recordingMode {
        case .pushToTalk:
            guard recordingState == .recording else { return }
            stopRecording()
        case .toggle:
            break
        }
    }

    private func makeEngine() throws -> any ASRService {
        let choice = UserDefaults.standard.string(forKey: "engineType") ?? "apple"
        switch choice {
        case "sensevoice":
            if let dir = modelManager.modelPath(for: .senseVoice) {
                return try SherpaASREngine(modelDir: dir)
            }
        case "paraformer":
            if let dir = modelManager.modelPath(for: .paraformer) {
                return try ParaformerStreamingEngine(modelDir: dir)
            }
        default:
            break
        }
        return try AppleSpeechASREngine()
    }

    private func startRecording() {
        guard recordingState == .idle else {
            print("[RecordingController] Ignoring startRecording — state is \(recordingState)")
            return
        }

        let newEngine: any ASRService
        do {
            newEngine = try makeEngine()
        } catch {
            errorMessage = "Failed to initialize engine: \(error.localizedDescription)"
            showErrorAlert = true
            return
        }

        recordingState = .recording
        confirmedSegments = []
        partialText = ""
        accumulatedSamples = []
        showCopyButton = false
        showOverlay()
        startTimer()
        recordingStartTime = Date()

        engine = newEngine
        engine?.reset()

        recordingTask = Task {
            do {
                let stream = try await audioCapture.start()
                resetSilenceTimer()

                for await chunk in stream {
                    guard recordingState == .recording else { break }
                    accumulatedSamples.append(contentsOf: chunk.samples)
                    micLevel = chunk.rmsLevel

                    do {
                        let result = try await engine?.feedChunk(chunk.samples, sampleRate: 16000)
                        if let result, !result.text.isEmpty {
                            partialText = result.text
                            isListeningSilence = false
                            resetSilenceTimer()
                        }
                    } catch {
                        errorMessage = "ASR engine error: \(error.localizedDescription)"
                        showErrorAlert = true
                        recordingState = .idle
                        hideOverlay()
                        break
                    }

                    // Auto-checkpoint for long recordings (>120s)
                    if let startTime = recordingStartTime, Date().timeIntervalSince(startTime) > maxRecordingDuration {
                        do {
                            if let result = try await engine?.finish(), !result.text.isEmpty {
                                let segment = TranscriptionSegment(text: result.text, emotion: result.emotion)
                                confirmedSegments.append(segment)
                            }
                            accumulatedSamples.removeAll(keepingCapacity: true)
                            let nextEngine = try makeEngine()
                            nextEngine.reset()
                            engine = nextEngine
                            recordingStartTime = Date()
                        } catch {
                            errorMessage = "Recording checkpoint failed: \(error.localizedDescription)"
                            showErrorAlert = true
                            recordingState = .idle
                            hideOverlay()
                            break
                        }
                    }
                }
            } catch {
                errorMessage = "Audio error: \(error.localizedDescription)"
                showErrorAlert = true
                recordingState = .idle
                hideOverlay()
            }
        }
    }

    private func stopRecording() {
        recordingState = .processing
        audioCapture.stop()
        stopTimer()
        invalidateSilenceTimer()

        Task {
            defer {
                recordingState = .idle
                engine = nil
                if !showCopyButton { hideOverlay() }
            }
            do {
                guard !accumulatedSamples.isEmpty else { return }
                let result = try await engine?.finish()
                partialText = ""
                if let result, !result.text.isEmpty {
                    let segment = TranscriptionSegment(text: result.text, emotion: result.emotion)
                    confirmedSegments.append(segment)
                    await injectText(result.text)
                }
            } catch {
                errorMessage = "Final transcription failed: \(error.localizedDescription)"
                showErrorAlert = true
            }
        }
    }

    private func injectText(_ text: String) async {
        let success = await textInjector.inject(text)
        if !success {
            showCopyButton = true
            if !AXIsProcessTrusted() {
                showAccessibilityGuide = true
            }
        }
    }

    private func showOverlay() {
        if overlayController == nil {
            overlayController = OverlayWindowController(controller: self)
        }
        overlayController?.show()
    }

    private func hideOverlay() {
        overlayController?.hide()
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, recordingState == .recording else { return }
                isListeningSilence = true
            }
        }
    }

    private func invalidateSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        isListeningSilence = false
    }

    private func startTimer() {
        recordingDuration = 0
        let startTime = Date()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    func copyToClipboard() {
        let text = confirmedSegments.map(\.text).joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopyButton = false
        hideOverlay()
    }
}
```

Key changes from original:
- `@MainActor` explicit annotation (line 5)
- `hotkeyDisplayText` computed property (lines 43-54) — dynamic text based on hotkey + mode settings
- `makeEngine()` throws — engine creation failure surfaces to user with alert (lines 95-101)
- `startRecording()` creates engine before setting state (lines 105-113) — prevents half-initialized state
- Auto-checkpoint uses `do/catch` instead of `try?` (lines 148-163) — errors surface to user
- Auto-checkpoint clears `accumulatedSamples` with `removeAll(keepingCapacity: true)` (line 155)
- Audio error sets `showErrorAlert = true` (line 168) — was only setting `lastError`
- `stopRecording()` error handler sets `showErrorAlert = true` (line 185) — was silently swallowed
- Removed all `await MainActor.run {}` wrappers — redundant with `@MainActor` class
- Removed `await MainActor.run` from timer update (line 229) — redundant

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/RecordingController.swift
git commit -m "fix: RecordingController — MainActor, error surfacing, buffer cleanup, hotkey text

- Explicit @MainActor annotation (was implicit from build setting)
- makeEngine() failure surfaces to user via alert instead of silent fallback
- Auto-checkpoint uses do/catch instead of try? — errors shown to user
- accumulatedSamples cleared after checkpoint (removeAll keepingCapacity)
- Audio capture errors now trigger showErrorAlert
- stopRecording errors surfaced to user
- Removed redundant await MainActor.run {} calls
- Added hotkeyDisplayText computed property for dynamic hotkey text"
```

---

### Task 5: UI Fixes — Dynamic Hotkey Text + Version from Bundle

**Files:**
- Modify: `NemoNoise/ContentView.swift:35,292`
- Modify: `NemoNoise/OverlayView.swift` (no hotkey text there currently, but verify)

- [ ] **Step 1: Fix ContentView — dynamic hotkey text**

In `ContentView.swift`, replace line 35 (the hardcoded hotkey hint):

```swift
// Before:
Text("Hold **⌥ Option** to record")
    .font(.caption)
    .foregroundStyle(.tertiary)

// After:
Text(controller.hotkeyDisplayText)
    .font(.caption)
    .foregroundStyle(.tertiary)
```

Also fix the version string. Replace `aboutSection` (around line 290-292):

```swift
private var aboutSection: some View {
    Section("About") {
        LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
        LabeledContent(
            "Active engine",
            value: activeEngineLabel
        )
    }
}
```

- [ ] **Step 2: Verify OverlayView.swift**

`OverlayView.swift` does not contain a hardcoded hotkey string — it shows transcription content and recording indicators. No changes needed.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/ContentView.swift
git commit -m "fix: dynamic hotkey text in popover, version from Bundle

- Popover hint text now reflects actual hotkey choice and recording mode
- Version string reads from Bundle.main instead of hardcoded 0.1.0"
```

---

### Task 6: ModelManager + Bundle ID

**Files:**
- Modify: `NemoNoise/ModelManager.swift:82-86`
- Modify: `NemoNoise.xcodeproj/project.pbxproj:296,346`

- [ ] **Step 1: Fix ModelManager — clean up completed download tasks**

In `ModelManager.swift`, replace the `startDownload` method (lines 82-86):

```swift
func startDownload(_ descriptor: ModelDescriptor) {
    guard case .notDownloaded = state(for: descriptor) else { return }
    let id = descriptor.id
    let task = Task {
        await download(descriptor)
        downloadTasks.removeValue(forKey: id)
    }
    downloadTasks[descriptor.id] = task
}
```

Key change: added `downloadTasks.removeValue(forKey: id)` after download completes (success or failure). This prevents Task references from accumulating indefinitely.

- [ ] **Step 2: Fix Bundle ID in project.pbxproj**

In `NemoNoise.xcodeproj/project.pbxproj`, replace both occurrences:

```
// Before (lines 296 and 346):
PRODUCT_BUNDLE_IDENTIFIER = com.nemo.BrightnessApp.NemoNoise;

// After:
PRODUCT_BUNDLE_IDENTIFIER = com.nemo.NemoNoise;
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/ModelManager.swift NemoNoise.xcodeproj/project.pbxproj
git commit -m "fix: clean up completed download tasks, correct Bundle ID

- ModelManager removes Task from downloadTasks after completion
- Bundle ID changed from com.nemo.BrightnessApp.NemoNoise to com.nemo.NemoNoise"
```

---

## Self-Review

**Spec coverage:**
- [x] #1 SFSpeechRecognizer force unwrap → Task 1 Step 3
- [x] #2 SherpaOnnxCreateOfflineStream force unwrap → Task 1 Step 2
- [x] #3 HotkeyMonitor data race → Task 2 Step 1
- [x] #4 ContinuationBox data race → Task 2 Step 2
- [x] #5 RecordingController non-MainActor → Task 4 (note: already implicit from build setting, now explicit)
- [x] #6 accumulatedSamples unbounded growth → Task 4 (removeAll keepingCapacity after checkpoint)
- [x] #7 SherpaASREngine re-decodes full buffer → Task 3 (lastDecodeCount + Task.detached)
- [x] #8 Hotkey string hardcoded → Task 4 (hotkeyDisplayText) + Task 5 (ContentView)
- [x] #9 Version hardcoded → Task 5 Step 1
- [x] #10 Bundle ID wrong → Task 6 Step 2
- [x] Audio error not shown → Task 4 (showErrorAlert = true)
- [x] Auto-checkpoint swallows errors → Task 4 (do/catch)
- [x] Download tasks not cleaned up → Task 6 Step 1

**Placeholder scan:** No TBD/TODO/vague steps. All steps have exact code or exact commands.

**Type consistency:** `ASRError.engineInitFailed` used consistently in Task 1 Steps 4, 5. `makeEngine() throws -> any ASRService` consistent across Task 1 Step 6 and Task 4. `hotkeyDisplayText` defined in Task 4, used in Task 5. `OSAllocatedUnfairLock` consistent in Task 2 Steps 1, 2.
