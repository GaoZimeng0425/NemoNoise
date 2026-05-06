# NemoNoise V1 Completion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete all remaining V1 features for NemoNoise — engine wiring, missing states, toggle mode, waveform animation, hotkey config, language preference, and polish.

**Architecture:** Build on existing modular structure. Each task touches 1-3 files max. The `RecordingController` is the central orchestrator; most changes fan out from there into overlay, settings, and hotkey. New files only for language preference storage.

**Tech Stack:** SwiftUI 6, macOS 15+, `@Observable` macro, `MenuBarExtra`, `NSPanel`, `CGEventTap`, `AVAudioEngine`, sherpa-onnx C API via bridging header.

---

## File Map

| File | Role | Tasks that modify |
|------|------|-------------------|
| `RecordingController.swift` | Orchestrator: state, engine lifecycle, audio loop | 1, 3, 4, 6, 7 |
| `ContentView.swift` | Settings UI + menu bar popover | 2, 8, 9 |
| `OverlayView.swift` | Floating transcript overlay | 4, 5, 7 |
| `OverlayWindowController.swift` | NSPanel management | 4 |
| `HotkeyMonitor.swift` | Global key monitoring | 8 |
| `ModelManager.swift` | Model download/cache | 2 |
| `Item.swift` | Data models, enums | 3, 4, 7, 8 |
| `NemoNoiseApp.swift` | App entry point | 5 |
| `MenuBarLabel` (in OverlayView.swift) | Menu bar icon | 5 |
| `TextInjector.swift` | AXUIElement injection | 3 |
| `LanguagePreference.swift` | **NEW** — language pref storage | 9 |

---

## Task 1: Wire Up Paraformer Engine

**Why:** `ParaformerStreamingEngine` is fully implemented but unreachable. `makeEngine()` only handles `"apple"` and `"sensevoice"`. The Paraformer model is already in `ModelDescriptor.paraformer`.

**Files:**
- Modify: `RecordingController.swift` — `makeEngine()` method (line 44-50)
- Modify: `ContentView.swift` — engine picker section (line 88-106) and model section logic (line 76-78)

- [ ] **Step 1: Update `makeEngine()` to handle "paraformer"**

In `RecordingController.swift`, replace `makeEngine()`:

```swift
private func makeEngine() -> any ASRService {
    let choice = UserDefaults.standard.string(forKey: "engineType") ?? "apple"
    switch choice {
    case "sensevoice":
        if let dir = modelManager.modelPath(for: .senseVoice) {
            return SherpaASREngine(modelDir: dir)
        }
    case "paraformer":
        if let dir = modelManager.modelPath(for: .paraformer) {
            return ParaformerStreamingEngine(modelDir: dir)
        }
    default:
        break
    }
    return AppleSpeechASREngine()
}
```

Note: The current `modelManager.modelPath` is a computed property that only checks sensevoice. We need to use `modelManager.modelPath(for: ModelDescriptor)` which already exists in `ModelManager.swift:69`.

- [ ] **Step 2: Add Paraformer to the engine picker in Settings**

In `ContentView.swift`, update the `engineSection` picker (line 90-93) to add a third radio option:

```swift
Picker("Engine", selection: $engineType) {
    Label("Apple Speech", systemImage: "apple.logo").tag("apple")
    Label("SenseVoice (offline)", systemImage: "cpu").tag("sensevoice")
    Label("Paraformer (streaming)", systemImage: "waveform").tag("paraformer")
}
.pickerStyle(.radioGroup)
```

- [ ] **Step 3: Update engine description text for all 3 engines**

In `ContentView.swift`, replace the engine description `if/else` (line 96-104) with a switch:

```swift
switch engineType {
case "apple":
    Text("Uses Apple's on-device/cloud recognition. No download required.")
        .font(.caption).foregroundStyle(.secondary)
case "sensevoice":
    Text("SenseVoice — fully offline. Chinese + 5 languages. Emotion detection. Requires ~60 MB download.")
        .font(.caption).foregroundStyle(.secondary)
case "paraformer":
    Text("Paraformer — streaming Chinese ASR with real-time partial results. Requires ~50 MB download.")
        .font(.caption).foregroundStyle(.secondary)
default: EmptyView()
}
```

- [ ] **Step 4: Show Paraformer model section when selected**

In `ContentView.swift`, update the condition for showing the model section (line 76):

```swift
if engineType == "sensevoice" {
    modelSection(for: .senseVoice)
} else if engineType == "paraformer" {
    modelSection(for: .paraformer)
}
```

This requires parameterizing the `modelSection` view. Change its signature to accept a `ModelDescriptor`:

```swift
private func modelSection(for descriptor: ModelDescriptor) -> some View {
    Section("\(descriptor.displayName) Model") {
        let mm = controller.modelManager
        switch mm.state(for: descriptor) {
        case .notDownloaded:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.displayName).font(.subheadline)
                    Text("\(descriptor.downloadSize) · \(descriptor.detail)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download") { mm.startDownload(descriptor) }
                    .buttonStyle(.borderedProminent)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading…").font(.subheadline)
                    Spacer()
                    Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { mm.cancelDownload(descriptor) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                ProgressView(value: progress)
            }
        case .downloaded:
            HStack {
                Label("Model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("Delete", role: .destructive) { mm.deleteModel(descriptor) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Download failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { mm.startDownload(descriptor) }.buttonStyle(.bordered)
            }
        }
    }
}
```

- [ ] **Step 5: Update `activeEngineLabel` for paraformer**

In `ContentView.swift`, update `activeEngineLabel` (line 181-188):

```swift
private var activeEngineLabel: String {
    switch engineType {
    case "sensevoice":
        return controller.modelManager.state(for: .senseVoice) == .downloaded
            ? "SenseVoice (local)" : "Apple Speech (model not downloaded)"
    case "paraformer":
        return controller.modelManager.state(for: .paraformer) == .downloaded
            ? "Paraformer (streaming)" : "Apple Speech (model not downloaded)"
    default:
        return "Apple Speech"
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add NemoNoise/RecordingController.swift NemoNoise/ContentView.swift
git commit -m "feat: wire up Paraformer engine in settings and makeEngine()"
```

---

## Task 2: Engine Fallback + Model Path Fix

**Why:** If user selects SenseVoice/Paraformer but model isn't downloaded, the app should fall back gracefully to Apple Speech and show a hint. Also, `ModelManager` needs a convenience `modelPath` property for the current engine.

**Files:**
- Modify: `RecordingController.swift` — add `currentEngineLabel` computed property
- Modify: `ContentView.swift` — show fallback warning in popover

- [ ] **Step 1: Add engine fallback warning to menu bar popover**

In `ContentView.swift`, inside `MenuBarPopoverView.body`, after the status text (line 29), add:

```swift
if let warning = engineFallbackWarning {
    Text(warning)
        .font(.caption2)
        .foregroundStyle(.orange)
}
```

And add a computed property:

```swift
private var engineFallbackWarning: String? {
    let choice = UserDefaults.standard.string(forKey: "engineType") ?? "apple"
    switch choice {
    case "sensevoice" where controller.modelManager.state(for: .senseVoice) != .downloaded:
        return "SenseVoice model not downloaded — using Apple Speech"
    case "paraformer" where controller.modelManager.state(for: .paraformer) != .downloaded:
        return "Paraformer model not downloaded — using Apple Speech"
    default:
        return nil
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add NemoNoise/ContentView.swift
git commit -m "feat: show engine fallback warning when model not downloaded"
```

---

## Task 3: Missing States — Error Handling in RecordingController

**Why:** Plan section 6.5 requires 8 states. This task covers: ASR engine error, no microphone access, text injection failure, and listening silence.

**Files:**
- Modify: `RecordingController.swift` — add error state properties, update `startRecording`/`stopRecording`
- Modify: `Item.swift` — extend `ASRError` enum if needed

- [ ] **Step 1: Add error display properties to RecordingController**

In `RecordingController.swift`, add after line 11 (`var showCopyButton`):

```swift
var showErrorAlert: Bool = false
var errorMessage: String = ""
var showAccessibilityGuide: Bool = false
var isListeningSilence: Bool = false
private var silenceTimer: Timer?
private let maxRecordingDuration: TimeInterval = 120
private var recordingStartTime: Date?
```

- [ ] **Step 2: Handle ASR engine errors in the audio loop**

In `RecordingController.swift`, inside `startRecording()`, replace the `feedChunk` call (lines 72-77) to catch and display errors:

```swift
do {
    let result = try await engine?.feedChunk(chunk.samples, sampleRate: 16000)
    if let result, !result.text.isEmpty {
        partialText = result.text
        isListeningSilence = false
        resetSilenceTimer()
    }
} catch {
    await MainActor.run {
        errorMessage = "ASR engine error: \(error.localizedDescription)"
        showErrorAlert = true
        recordingState = .idle
    }
    hideOverlay()
    break
}
```

- [ ] **Step 3: Add silence detection timer**

Add helper methods to `RecordingController`:

```swift
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
```

Call `resetSilenceTimer()` at the start of the audio loop in `startRecording()`. Call `invalidateSilenceTimer()` in `stopRecording()`.

- [ ] **Step 4: Handle long recording auto-checkpoint**

In the audio loop inside `startRecording()`, add after the `feedChunk` block:

```swift
// Auto-checkpoint for long recordings (>120s)
if let startTime = recordingStartTime, Date().timeIntervalSince(startTime) > maxRecordingDuration {
    if let result = try? await engine?.finish(), !result.text.isEmpty {
        let segment = TranscriptionSegment(text: result.text, emotion: result.emotion)
        await MainActor.run { confirmedSegments.append(segment) }
    }
    engine?.reset()
    recordingStartTime = Date()
}
```

Set `recordingStartTime = Date()` at the beginning of `startRecording()`.

- [ ] **Step 5: Handle text injection failure with accessibility guide**

In `RecordingController.swift`, update `injectText`:

```swift
private func injectText(_ text: String) async {
    let success = await textInjector.inject(text)
    if !success {
        showCopyButton = true
        // Check if it's an accessibility permission issue
        if !AXIsProcessTrusted() {
            showAccessibilityGuide = true
        }
    }
}
```

Add `import ApplicationServices` at top of file if not already present.

- [ ] **Step 6: Commit**

```bash
git add NemoNoise/RecordingController.swift
git commit -m "feat: add error states — engine error, silence detection, long recording checkpoint, injection failure"
```

---

## Task 4: Recording Timer + Overlay Improvements

**Why:** The overlay header shows "Listening..." but no elapsed time. The plan requires a timer display and polished overlay states.

**Files:**
- Modify: `RecordingController.swift` — add `recordingDuration` property
- Modify: `OverlayView.swift` — show elapsed time, silence indicator, accessibility guide
- Modify: `OverlayWindowController.swift` — add accessibility guide panel

- [ ] **Step 1: Add recording timer to RecordingController**

In `RecordingController.swift`, add:

```swift
var recordingDuration: TimeInterval = 0
private var timerTask: Task<Void, Never>?
```

Add timer start/stop methods:

```swift
private func startTimer() {
    recordingDuration = 0
    let startTime = Date()
    timerTask = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }
}

private func stopTimer() {
    timerTask?.cancel()
    timerTask = nil
}
```

Call `startTimer()` in `startRecording()` after `showOverlay()`. Call `stopTimer()` in `stopRecording()`.

- [ ] **Step 2: Update overlay timer display**

In `OverlayView.swift`, replace `timerLabel` (line 38-42):

```swift
private var timerLabel: some View {
    Text(timerText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
}

private var timerText: String {
    switch controller.recordingState {
    case .recording:
        let minutes = Int(controller.recordingDuration) / 60
        let seconds = Int(controller.recordingDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    case .processing:
        return "Processing…"
    case .idle:
        return "Ready"
    }
}
```

- [ ] **Step 3: Add silence indicator to overlay**

In `OverlayView.swift`, inside `transcriptArea` (line 67), after the partial text block, add:

```swift
if controller.isListeningSilence && controller.confirmedSegments.isEmpty && controller.partialText.isEmpty {
    HStack(spacing: 6) {
        Image(systemName: "ear")
            .foregroundStyle(.secondary)
        Text("Listening… speak now")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding(.top, 4)
}
```

- [ ] **Step 4: Add accessibility guide alert**

In `OverlayView.swift`, add an `.alert` modifier to the main VStack:

```swift
.alert("Accessibility Permission Required", isPresented: Binding(
    get: { controller.showAccessibilityGuide },
    set: { controller.showAccessibilityGuide = $0 }
)) {
    Button("Open System Settings") {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("NemoNoise needs Accessibility permission to inject text into other apps.\n\nGo to System Settings → Privacy & Security → Accessibility, then enable NemoNoise.")
}
```

Also add an `.alert` for general errors:

```swift
.alert("Error", isPresented: Binding(
    get: { controller.showErrorAlert },
    set: { controller.showErrorAlert = $0 }
)) {
    Button("OK") { controller.showErrorAlert = false }
} message: {
    Text(controller.errorMessage)
}
```

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/RecordingController.swift NemoNoise/OverlayView.swift
git commit -m "feat: recording timer, silence indicator, and error/accessibility alerts in overlay"
```

---

## Task 5: Animated Waveform in Menu Bar

**Why:** Plan requires animated waveform in menu bar icon during dictation. Currently `MenuBarLabel` uses `mic.fill` with `.symbolEffect(.pulse)`.

**Files:**
- Modify: `OverlayView.swift` — `MenuBarLabel` struct (line 113-120)
- Modify: `RecordingController.swift` — expose `micLevel` for menu bar

- [ ] **Step 1: Replace MenuBarLabel with waveform bars**

In `OverlayView.swift`, replace `MenuBarLabel`:

```swift
struct MenuBarLabel: View {
    @Environment(RecordingController.self) private var controller

    var body: some View {
        if controller.recordingState == .recording {
            HStack(spacing: 1.5) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(.primary)
                        .frame(width: 2.5, height: menuBarHeight(index: i))
                }
            }
            .frame(height: 16)
            .animation(.easeOut(duration: 0.1), value: controller.micLevel)
        } else {
            Image(systemName: "waveform")
        }
    }

    private func menuBarHeight(index: Int) -> CGFloat {
        let level = CGFloat(controller.micLevel)
        let base: CGFloat = 4
        let maxExtra: CGFloat = 12
        // Each bar reacts to a different portion of the level range
        let threshold = CGFloat(index) * 0.3
        let active = max(0, level - threshold) / 0.3
        return base + active * maxExtra
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add NemoNoise/OverlayView.swift
git commit -m "feat: animated waveform bars in menu bar during recording"
```

---

## Task 6: Toggle Mode

**Why:** Plan requires both push-to-talk (hold ⌥) and toggle mode (press ⌥ to start, press again to stop). Currently only push-to-talk works.

**Files:**
- Modify: `Item.swift` — add `RecordingMode` enum
- Modify: `RecordingController.swift` — add mode-aware hotkey handling
- Modify: `HotkeyMonitor.swift` — expose tap mode for re-registration
- Modify: `ContentView.swift` — add mode toggle in Settings → Shortcuts (new tab later, for now in General section)

- [ ] **Step 1: Add RecordingMode enum to Item.swift**

```swift
enum RecordingMode: String, CaseIterable, Codable {
    case pushToTalk = "Push to Talk"
    case toggle = "Toggle"
}
```

- [ ] **Step 2: Add recording mode to RecordingController**

In `RecordingController.swift`, add:

```swift
var recordingMode: RecordingMode {
    get {
        let raw = UserDefaults.standard.string(forKey: "recordingMode") ?? "pushToTalk"
        return RecordingMode(rawValue: raw) ?? .pushToTalk
    }
    set {
        UserDefaults.standard.set(newValue.rawValue, forKey: "recordingMode")
    }
}
```

- [ ] **Step 3: Update hotkey handling for toggle mode**

In `RecordingController.swift`, update `handleHotkeyDown`:

```swift
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
```

Update `handleHotkeyUp`:

```swift
func handleHotkeyUp() {
    switch recordingMode {
    case .pushToTalk:
        guard recordingState == .recording else { return }
        stopRecording()
    case .toggle:
        break // ignore key-up in toggle mode
    }
}
```

- [ ] **Step 4: Add recording mode picker to Settings**

In `ContentView.swift`, add a new section to `SettingsView.body` after the engine section:

```swift
Section("Recording Mode") {
    Picker("Mode", selection: Binding(
        get: { controller.recordingMode },
        set: { controller.recordingMode = $0 }
    )) {
        Text("Push to Talk (hold ⌥)").tag(RecordingMode.pushToTalk)
        Text("Toggle (press ⌥ to start/stop)").tag(RecordingMode.toggle)
    }
    .pickerStyle(.radioGroup)

    Text(controller.recordingMode == .pushToTalk
         ? "Hold Option key to record. Release to stop."
         : "Press Option key to start recording. Press again to stop.")
        .font(.caption).foregroundStyle(.secondary)
}
```

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/Item.swift NemoNoise/RecordingController.swift NemoNoise/ContentView.swift
git commit -m "feat: add toggle mode — press ⌥ to start/stop (alternative to push-to-talk)"
```

---

## Task 7: Long Recording Checkpoint — Fix and Wire Up

**Why:** Task 3 step 4 added the long-recording checkpoint logic, but it needs the engine to be re-created after `finish()` + `reset()`. Also need to persist partial confirmed segments properly.

**Files:**
- Modify: `RecordingController.swift` — re-initialize engine after checkpoint

- [ ] **Step 1: Re-create engine after checkpoint**

In `RecordingController.swift`, inside the long-recording checkpoint block (added in Task 3 step 4), after `engine?.reset()`, add:

```swift
engine = makeEngine()
engine?.reset()
recordingStartTime = Date()
```

This ensures the engine gets a fresh stream after the old one was finalized.

- [ ] **Step 2: Commit**

```bash
git add NemoNoise/RecordingController.swift
git commit -m "fix: re-create engine after long recording checkpoint"
```

---

## Task 8: Hotkey Configuration UI

**Why:** Plan requires configurable hotkey in Preferences → Shortcuts. Currently hardcoded to Option key.

**Files:**
- Modify: `HotkeyMonitor.swift` — make hotkey key configurable
- Modify: `ContentView.swift` — add Shortcuts section
- Modify: `Item.swift` — add `HotkeyOption` enum

- [ ] **Step 1: Add HotkeyOption enum to Item.swift**

```swift
enum HotkeyOption: String, CaseIterable, Codable {
    case option = "⌥ Option"
    case fn = "🌐 fn"
    case rightCommand = "⌘ Right Command"

    var cgFlags: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .fn: return []  // fn key is not a flag; special handling needed
        case .rightCommand: return .maskCommand
        }
    }

    var keyCode: CGKeyCode? {
        switch self {
        case .fn: return 0x3F  // kVK_Function
        default: return nil    // detected via flagsChanged
        }
    }
}
```

- [ ] **Step 2: Make HotkeyMonitor configurable**

In `HotkeyMonitor.swift`, add a property and use it in `handleFlagsChangedSync`:

```swift
var hotkeyOption: HotkeyOption {
    let raw = UserDefaults.standard.string(forKey: "hotkeyOption") ?? "option"
    return HotkeyOption(rawValue: raw) ?? .option
}
```

Update `handleFlagsChangedSync` to use `hotkeyOption`:

```swift
nonisolated private func handleFlagsChangedSync(event: CGEvent) {
    let flags = event.flags
    let selectedFlag = hotkeyOption.cgFlags
    let optionNowDown: Bool
    let onlyOption: Bool

    if hotkeyOption == .fn {
        // fn key handling via keyCode would need a different event mask
        // For now, fall back to flags-based detection
        optionNowDown = flags.contains(.maskAlternate)
        onlyOption = flags.intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate]) == .maskAlternate
    } else {
        optionNowDown = flags.contains(selectedFlag)
        let allFlags: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
        onlyOption = flags.intersection(allFlags) == selectedFlag
    }

    var wasDown = optionWasDown

    if optionNowDown && !wasDown && onlyOption {
        optionWasDown = true
        let cb = onKeyDown
        DispatchQueue.main.async { cb?() }
    } else if !optionNowDown && wasDown {
        optionWasDown = false
        let cb = onKeyUp
        DispatchQueue.main.async { cb?() }
    }
}
```

- [ ] **Step 3: Add Shortcuts section to Settings**

In `ContentView.swift`, add a new section in `SettingsView.body`:

```swift
Section("Shortcuts") {
    Picker("Activation Key", selection: Binding(
        get: { controller.hotkeyMonitor.hotkeyOption },
        set: { _ in
            UserDefaults.standard.set(
                controller.hotkeyMonitor.hotkeyOption.rawValue,
                forKey: "hotkeyOption"
            )
            // HotkeyMonitor reads from UserDefaults, so next key event picks it up
        }
    )) {
        ForEach(HotkeyOption.allCases, id: \.self) { option in
            Text(option.rawValue).tag(option)
        }
    }

    if !AXIsProcessTrusted() {
        Label("Accessibility permission required for global hotkey", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.caption)
        Button("Open System Settings") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        .font(.caption)
    }
}
```

Note: `HotkeyMonitor` needs to be accessible from `RecordingController`. Currently `hotkeyMonitor` is `private`. Change it to `private(set)` or expose via a computed property. Simplest: change `private let hotkeyMonitor` to `let hotkeyMonitor` (internal access).

In `RecordingController.swift`, change line 17:
```swift
let hotkeyMonitor = HotkeyMonitor()
```

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/Item.swift NemoNoise/HotkeyMonitor.swift NemoNoise/RecordingController.swift NemoNoise/ContentView.swift
git commit -m "feat: configurable hotkey — Option, fn, or Right Command"
```

---

## Task 9: Language Preference

**Why:** Plan requires language auto-detection with user preference. SenseVoice supports `language="auto"` in its config. Apple Speech uses locale.

**Files:**
- Create: `NemoNoise/LanguagePreference.swift` — language enum + storage
- Modify: `SherpaOnnxWrapper.swift` — accept language parameter
- Modify: `SherpaASREngine.swift` — pass language to wrapper
- Modify: `AppleSpeechASREngine.swift` — use preferred locale
- Modify: `ContentView.swift` — add language picker to Settings

- [ ] **Step 1: Create LanguagePreference.swift**

```swift
import Foundation

enum LanguagePreference: String, CaseIterable, Codable, Identifiable {
    case auto = "Auto-detect"
    case zh = "Chinese (中文)"
    case en = "English"
    case ja = "Japanese (日本語)"
    case ko = "Korean (한국어)"
    case yue = "Cantonese (粤语)"

    var id: String { rawValue }

    /// sherpa-onnx language code
    var sherpaCode: String {
        switch self {
        case .auto: return "auto"
        case .zh:   return "zh"
        case .en:   return "en"
        case .ja:   return "ja"
        case .ko:   return "ko"
        case .yue:  return "yue"
        }
    }

    /// Apple Speech locale identifier
    var localeIdentifier: String? {
        switch self {
        case .auto: return nil  // use system locale
        case .zh:   return "zh-CN"
        case .en:   return "en-US"
        case .ja:   return "ja-JP"
        case .ko:   return "ko-KR"
        case .yue:  return "zh-HK"
        }
    }

    static var current: LanguagePreference {
        let raw = UserDefaults.standard.string(forKey: "languagePreference") ?? "auto"
        return LanguagePreference(rawValue: raw) ?? .auto
    }
}
```

- [ ] **Step 2: Update SherpaOfflineRecognizer to accept language**

In `SherpaOnnxWrapper.swift`, update the `SherpaOfflineRecognizer.init` to accept a language parameter:

```swift
init?(modelPath: String, tokensPath: String, language: String = "auto") {
    // ... same as before, but replace:
    //   "auto".withCString { cLang in
    // with:
    //   language.withCString { cLang in
```

Change line 26 from `"auto".withCString` to `language.withCString`.

- [ ] **Step 3: Update SherpaASREngine to use language preference**

In `SherpaASREngine.swift`, update the init:

```swift
init(modelDir: URL, language: String = LanguagePreference.current.sherpaCode) {
    let modelPath = modelDir.appendingPathComponent("model.int8.onnx").path
    let tokensPath = modelDir.appendingPathComponent("tokens.txt").path
    guard let r = SherpaOfflineRecognizer(modelPath: modelPath, tokensPath: tokensPath, language: language) else {
        fatalError("[SherpaASREngine] Failed to load model from \(modelDir.path)")
    }
    recognizer = r
    print("[SherpaASREngine] Model loaded, language: \(language)")
}
```

- [ ] **Step 4: Update AppleSpeechASREngine to use language preference**

In `AppleSpeechASREngine.swift`, update init:

```swift
init() {
    let pref = LanguagePreference.current
    if let localeId = pref.localeIdentifier {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
            ?? SFSpeechRecognizer(locale: .current)
            ?? SFSpeechRecognizer()!
    } else {
        // auto: prefer zh-CN, then current, then system
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: .current)
            ?? SFSpeechRecognizer()!
    }
    print("[AppleSpeechASREngine] locale: \(recognizer.locale.identifier)")
}
```

- [ ] **Step 5: Add language picker to Settings**

In `ContentView.swift`, add a section in `SettingsView.body`:

```swift
Section("Language") {
    Picker("Recognition Language", selection: Binding(
        get: { LanguagePreference.current },
        set: { UserDefaults.standard.set($0.rawValue, forKey: "languagePreference") }
    )) {
        ForEach(LanguagePreference.allCases) { lang in
            Text(lang.rawValue).tag(lang)
        }
    }

    Text("Auto-detect works best for mixed Chinese/English content. Select a specific language for faster, more accurate results.")
        .font(.caption).foregroundStyle(.secondary)
}
```

Add `@AppStorage("languagePreference") private var languagePreference = "Auto-detect"` to `SettingsView` for live updates.

- [ ] **Step 6: Pass language to Paraformer engine**

In `RecordingController.swift`, update the paraformer case in `makeEngine()`:

```swift
case "paraformer":
    if let dir = modelManager.modelPath(for: .paraformer) {
        return ParaformerStreamingEngine(modelDir: dir)
    }
```

Paraformer streaming uses its own config and doesn't have a language parameter in the current wrapper, so it stays as-is. The Paraformer model is already Chinese-specific.

- [ ] **Step 7: Commit**

```bash
git add NemoNoise/LanguagePreference.swift NemoNoise/SherpaOnnxWrapper.swift NemoNoise/SherpaASREngine.swift NemoNoise/AppleSpeechASREngine.swift NemoNoise/ContentView.swift
git commit -m "feat: language preference — auto-detect, Chinese, English, Japanese, Korean, Cantonese"
```

---

## Task 10: Polish — Reduced Motion, Animations, Edge Cases

**Why:** Plan section 7 requires accessibility (reduced motion), and Week 3 calls for polish.

**Files:**
- Modify: `OverlayView.swift` — reduced motion support, "REC" label
- Modify: `OverlayWindowController.swift` — smooth show/hide animation
- Modify: `RecordingController.swift` — cleanup edge cases

- [ ] **Step 1: Add reduced motion support to overlay waveform**

In `OverlayView.swift`, update `micLevelView`:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

private var micLevelView: some View {
    if reduceMotion {
        Text("● REC")
            .font(.caption.monospaced())
            .foregroundStyle(.red)
    } else {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(index: i))
                    .frame(width: 3, height: barHeight(index: i))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.05), value: controller.micLevel)
    }
}
```

- [ ] **Step 2: Add reduced motion to menu bar label**

In `OverlayView.swift`, update `MenuBarLabel`:

```swift
struct MenuBarLabel: View {
    @Environment(RecordingController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if controller.recordingState == .recording {
            if reduceMotion {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 1.5) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(.primary)
                            .frame(width: 2.5, height: menuBarHeight(index: i))
                    }
                }
                .frame(height: 16)
                .animation(.easeOut(duration: 0.1), value: controller.micLevel)
            }
        } else {
            Image(systemName: "waveform")
        }
    }
    // ... menuBarHeight stays the same
}
```

- [ ] **Step 3: Add smooth overlay show/hide animation**

In `OverlayWindowController.swift`, update `show()` and `hide()`:

```swift
func show() {
    if panel == nil {
        panel = makePanel()
    }
    positionOnActiveScreen()
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.2
        panel?.animator().alphaValue = 1.0
        panel?.orderFrontRegardless()
    })
}

func hide() {
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.15
        panel?.animator().alphaValue = 0.0
    }, completionHandler: { [weak self] in
        self?.panel?.orderOut(nil)
    })
}
```

Set initial alpha to 0 in `makePanel()` after creating the panel:
```swift
panel.alphaValue = 0.0
```

- [ ] **Step 4: Handle recording state edge cases**

In `RecordingController.swift`, in `stopRecording()`, ensure we handle the case where `accumulatedSamples` is empty but `confirmedSegments` has content from a checkpoint:

```swift
guard !accumulatedSamples.isEmpty else {
    // Even with no new samples, finalize may have been called
    // during a checkpoint — just clean up
    recordingState = .idle
    engine = nil
    if !showCopyButton { hideOverlay() }
    return
}
```

Also, in `startRecording()`, guard against starting while already recording:

```swift
private func startRecording() {
    guard recordingState == .idle else {
        print("[RecordingController] Ignoring startRecording — state is \(recordingState)")
        return
    }
    // ... rest of existing code
}
```

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/OverlayView.swift NemoNoise/OverlayWindowController.swift NemoNoise/RecordingController.swift
git commit -m "feat: polish — reduced motion, smooth overlay animation, edge case handling"
```

---

## Task 11: Settings Tabs Restructure

**Why:** Plan requires 4 tabs: General, Engine, Shortcuts, Display. Currently everything is in one Form.

**Files:**
- Modify: `ContentView.swift` — restructure SettingsView with `TabView`

- [ ] **Step 1: Restructure SettingsView with TabView**

Replace the `SettingsView.body` in `ContentView.swift`:

```swift
var body: some View {
    TabView {
        generalTab
            .tabItem { Label("General", systemImage: "gear") }

        engineTab
            .tabItem { Label("Engine", systemImage: "cpu") }

        shortcutsTab
            .tabItem { Label("Shortcuts", systemImage: "keyboard") }

        displayTab
            .tabItem { Label("Display", systemImage: "paintbrush") }
    }
    .formStyle(.grouped)
    .frame(width: 460, height: 380)
    .navigationTitle("NemoNoise")
}
```

Move existing sections into the appropriate tabs:
- **General**: launch at login (placeholder for now), recording max duration
- **Engine**: engine picker + model sections (existing)
- **Shortcuts**: hotkey config + recording mode (existing from Tasks 6, 8)
- **Display**: overlay position, font size, emotion tags toggle

- [ ] **Step 2: Implement display tab**

```swift
@AppStorage("showEmotionTags") private var showEmotionTags = true

private var displayTab: some View {
    Form {
        Section("Overlay") {
            Toggle("Show emotion tags", isOn: $showEmotionTags)
            Text("Display 😊😢😠 emotion indicators from SenseVoice after each sentence.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: Wire emotion toggle to overlay**

In `OverlayView.swift`, read the preference:

```swift
@AppStorage("showEmotionTags") private var showEmotionTags = true
```

In `transcriptArea`, wrap the emotion display:

```swift
if showEmotionTags, let emotion = segment.emotion {
    Text(emotion).font(.system(size: 18))
}
```

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/ContentView.swift NemoNoise/OverlayView.swift
git commit -m "feat: restructure settings into 4 tabs — General, Engine, Shortcuts, Display"
```

---

## Task 12: Final Verification and Cleanup

**Why:** Ensure all features work together, no regressions.

**Files:**
- Review: all modified files

- [ ] **Step 1: Verify all engine paths**

Check that `makeEngine()` handles all 3 engines with proper fallback:
- "apple" → `AppleSpeechASREngine()` (always works)
- "sensevoice" → `SherpaASREngine` if model downloaded, else fallback to Apple
- "paraformer" → `ParaformerStreamingEngine` if model downloaded, else fallback to Apple

- [ ] **Step 2: Verify all 8 missing states are handled**

| State | Check |
|-------|-------|
| Model downloading | `modelSection` shows progress with cancel |
| No microphone access | `AudioCapture.requestMicrophoneAccess()` throws → caught in `startRecording` |
| No accessibility access | `TextInjector.inject` returns false → `showAccessibilityGuide` alert |
| Hotkey conflict | Settings shows AX trust warning |
| Listening silence | `isListeningSilence` + 3s timer → "Listening… speak now" |
| ASR engine error | `feedChunk` catch → `showErrorAlert` |
| Long recording | 120s auto-checkpoint with engine re-creation |
| Text injection failed | `showCopyButton = true` + accessibility guide |

- [ ] **Step 3: Verify plan section 4 Must-Have checklist**

| Feature | Status |
|---------|--------|
| Menu bar app (NSStatusItem, no Dock) | ✅ existing |
| Push-to-talk via global hotkey | ✅ existing |
| Toggle mode | ✅ Task 6 |
| Real-time streaming overlay | ✅ existing + Task 4 timer |
| Text injection | ✅ existing |
| SenseVoice model | ✅ existing |
| Language auto-detection | ✅ Task 9 |
| Preferences window | ✅ Task 11 tabs |
| Model download UI | ✅ existing |
| Recording status waveform | ✅ Task 5 |

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "chore: final verification and cleanup for V1 completion"
```

---

## Execution Order Summary

1. **Task 1** — Wire up Paraformer engine (foundation, no dependencies)
2. **Task 2** — Engine fallback warning (builds on Task 1)
3. **Task 3** — Error states in RecordingController (core logic, needed by Tasks 4, 7)
4. **Task 4** — Recording timer + overlay improvements (builds on Task 3)
5. **Task 5** — Animated waveform in menu bar (independent)
6. **Task 6** — Toggle mode (independent)
7. **Task 7** — Long recording checkpoint fix (builds on Task 3)
8. **Task 8** — Hotkey configuration UI (independent)
9. **Task 9** — Language preference (independent)
10. **Task 10** — Polish (builds on Tasks 4, 5)
11. **Task 11** — Settings tabs restructure (builds on Tasks 1, 6, 8, 9)
12. **Task 12** — Final verification (builds on all)
