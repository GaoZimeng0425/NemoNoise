# Real-time Audio Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real-time system audio translation (English → Chinese) with bilingual subtitle overlay to NemoNoise.

**Architecture:** ScreenCaptureKit captures system audio → AppleSpeechASREngine (en-US locale) recognizes English → Apple Translation framework translates to Chinese → SubtitleOverlay displays bilingual subtitles. TranslationController coordinates the pipeline. Translation mode is toggled via menu bar or keyboard shortcut, mutually exclusive with dictation mode.

**Tech Stack:** ScreenCaptureKit (system framework, macOS 12.3+), Apple Translation framework (system framework, macOS 15+), SwiftUI, existing ASR infrastructure

---

## File Structure

**New files:**

| File | Responsibility |
|------|---------------|
| `NemoNoise/Models/TranslationModels.swift` | TranslationState enum, TranslationError enum |
| `NemoNoise/Services/Translation/TranslationService.swift` | Translation protocol + AppleTranslationService |
| `NemoNoise/Services/Audio/SystemAudioCapture.swift` | ScreenCaptureKit audio capture → 16kHz AudioChunk stream |
| `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift` | Bilingual subtitle SwiftUI view |
| `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayController.swift` | NSPanel controller for subtitle bar |
| `NemoNoise/App/TranslationController.swift` | Pipeline coordinator: audio → ASR → translation → UI |

**Modified files:**

| File | Change |
|------|--------|
| `NemoNoise/Services/Input/HotkeyShortcuts.swift` | Add `.translationMode` shortcut name |
| `NemoNoise/UI/Menubar/MenubarView.swift` | Add translation mode toggle button |
| `NemoNoise/App/NemoNoiseApp.swift` | Add TranslationController to SwiftUI environment |
| `NemoNoise/App/RecordingController.swift` | Mutual exclusion with translation mode |
| `NemoNoise/Services/ASR/AppleSpeechASREngine.swift` | Add optional locale parameter to init |
| `NemoNoise/UI/Settings/SettingsView.swift` | Add translation shortcut recorder |

**Note:** Add all new `.swift` files to the NemoNoise target in Xcode (drag into project navigator under the appropriate group).

---

### Task 1: Translation Models

**Files:**
- Create: `NemoNoise/Models/TranslationModels.swift`

- [ ] **Step 1: Create TranslationModels.swift**

```swift
import Foundation

enum TranslationState: Equatable {
    case idle
    case capturing
    case error(String)
}

enum TranslationError: Error, LocalizedError {
    case screenRecordingDenied
    case noDisplay
    case translationUnavailable
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            "Screen recording permission required. Enable in System Settings → Privacy & Security → Screen Recording."
        case .noDisplay:
            "No display found for audio capture."
        case .translationUnavailable:
            "Translation unavailable. Check that language packs are downloaded in System Settings."
        case .captureFailed(let message):
            "Audio capture failed: \(message)"
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme NemoNoise -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/Models/TranslationModels.swift
git commit -m "feat(translation): add translation state and error models"
```

---

### Task 2: TranslationService

**Files:**
- Create: `NemoNoise/Services/Translation/TranslationService.swift`

The Apple Translation framework's `TranslationSession` is provided via SwiftUI's `.translationTask` modifier. The service stores a reference to the session (set by the view) and provides a `translate()` method.

**API verification note:** The exact `TranslationSession` API (`session.translate(_:)` returning a response with `.targetText`) should be verified against the macOS 15 SDK documentation. If the API differs, adjust the implementation accordingly.

- [ ] **Step 1: Create TranslationService.swift**

```swift
import Foundation
import Translation

protocol TranslationService {
    func translate(_ text: String) async throws -> String
}

@available(macOS 15.0, *)
final class AppleTranslationService: TranslationService {
    private var session: TranslationSession?

    func setSession(_ session: TranslationSession) {
        self.session = session
    }

    func translate(_ text: String) async throws -> String {
        guard let session else {
            throw TranslationError.translationUnavailable
        }
        let response = try await session.translate(text)
        return response.targetText
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme NemoNoise -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**If build fails** with "Cannot find type 'TranslationSession' in scope":
- Verify the macOS deployment target is 15.0+
- Add `import Translation` at the top of the file
- If `TranslationSession` still not found, check Xcode SDK version (requires Xcode 16+)

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/Services/Translation/TranslationService.swift
git commit -m "feat(translation): add TranslationService protocol and Apple implementation"
```

---

### Task 3: SystemAudioCapture

**Files:**
- Create: `NemoNoise/Services/Audio/SystemAudioCapture.swift`

This is the most complex new module. It wraps ScreenCaptureKit to capture system audio, converts to 16kHz mono float32, and outputs `AsyncStream<AudioChunk>` — the same type as `AudioCapture`, so ASR engines consume it without changes.

- [ ] **Step 1: Create SystemAudioCapture.swift**

```swift
import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let continuationBox = ContinuationBox()
    private var stream: SCStream?
    private let targetSampleRate: Double = 16000

    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    func start() async throws -> AsyncStream<AudioChunk> {
        guard CGPreflightScreenCaptureAccess() else {
            throw TranslationError.screenRecordingDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw TranslationError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 1

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.nemonoise.audio-capture"))

        let audioStream = AsyncStream<AudioChunk> { [weak self] continuation in
            self?.continuationBox.value = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { [weak self] in
                    try? await self?.stream?.stopCapture()
                    self?.stream = nil
                }
            }
        }

        try await stream.startCapture()
        self.stream = stream
        LogService.info("System audio capture started", category: "SystemAudioCapture")
        return audioStream
    }

    func stop() {
        continuationBox.value?.finish()
        Task { [weak self] in
            try? await self?.stream?.stopCapture()
            self?.stream = nil
        }
        LogService.info("System audio capture stopped", category: "SystemAudioCapture")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let samples = extractFloatSamples(from: sampleBuffer) else { return }
        guard let resampled = resample(samples, sourceRate: 48000) else { return }

        let rms = sqrt(resampled.reduce(0) { $0 + $1 * $1 } / Float(max(resampled.count, 1)))
        continuationBox.value?.yield(AudioChunk(samples: resampled, rmsLevel: rms))
    }

    // MARK: - Audio Processing

    private func extractFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        let sampleCount = length / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return nil }

        var samples = [Float](repeating: 0, count: sampleCount)
        let status = samples.withUnsafeMutableBufferPointer { buffer in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        guard status == kCMBlockBufferSuccess else { return nil }
        return samples
    }

    private func resample(_ samples: [Float], sourceRate: Double) -> [Float]? {
        let srcFormat: AVAudioFormat
        let dstFormat: AVAudioFormat

        guard let sf = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let df = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sf, to: df) else {
            return nil
        }

        let srcFrameCount = AVAudioFrameCount(samples.count)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: sf, frameCapacity: srcFrameCount) else { return nil }
        srcBuffer.frameLength = srcFrameCount
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress, let channelData = srcBuffer.floatChannelData else { return }
            channelData[0].initialize(from: base, count: samples.count)
        }

        let ratio = targetSampleRate / sourceRate
        let dstFrameCount = AVAudioFrameCount(Double(samples.count) * ratio) + 1
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: df, frameCapacity: dstFrameCount) else { return nil }

        var inputConsumed = false
        let status = converter.convert(to: dstBuffer, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        guard status != .error, let channelData = dstBuffer.floatChannelData else { return nil }
        let frameLength = Int(dstBuffer.frameLength)
        guard frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme NemoNoise -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**If build fails** with ScreenCaptureKit errors:
- Verify macOS deployment target is 12.3+ (our target is 15.0, so this should be fine)
- Ensure ScreenCaptureKit framework is linked (it's a system framework, should be auto-linked)

**If `ContinuationBox` is undefined**: It's already defined in `AudioCapture.swift`. Both files are in the same target, so it should be accessible. If not, move `ContinuationBox` to a shared location or duplicate it.

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/Services/Audio/SystemAudioCapture.swift
git commit -m "feat(translation): add ScreenCaptureKit-based system audio capture"
```

---

### Task 4: SubtitleOverlay UI

**Files:**
- Create: `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift`
- Create: `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayController.swift`

- [ ] **Step 1: Create SubtitleOverlayView.swift**

```swift
import SwiftUI
import Translation

struct SubtitleOverlayView: View {
    @Environment(TranslationController.self) private var controller
    @State private var translationSession: TranslationSession?
    @State private var dotOpacity: [Double] = [0.3, 0.3, 0.3]

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(controller.translationState == .capturing ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            // Bilingual text
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.englishText.isEmpty ? "Listening…" : controller.englishText)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.gray)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if controller.isTranslating {
                    translatingDots
                } else {
                    Text(controller.chineseText.isEmpty ? "—" : controller.chineseText)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()
        }
        .padding(12)
        .frame(minWidth: 400, maxWidth: 900)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThickMaterial)
        }
        .translationTask(.init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))) { session in
            translationSession = session
            controller.translationService.setSession(session)
        }
        .onChange(of: controller.englishText) { _, newText in
            guard !newText.isEmpty else { return }
            Task {
                controller.isTranslating = true
                do {
                    let result = try await controller.translationService.translate(newText)
                    controller.chineseText = result
                } catch {
                    LogService.warn("Translation failed: \(error.localizedDescription)", category: "Translation")
                    controller.chineseText = "—"
                }
                controller.isTranslating = false
            }
        }
    }

    private var translatingDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 5, height: 5)
                    .offset(y: sin(.init(Date().timeIntervalSince1970 * 3 + Double(i) * 0.5)) * 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 2: Create SubtitleOverlayController.swift**

```swift
import AppKit
import SwiftUI

final class SubtitleOverlayController {
    private var panel: NSPanel?
    private let controller: TranslationController

    init(controller: TranslationController) {
        self.controller = controller
    }

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

    private func makePanel() -> NSPanel {
        let hostingView = NSHostingView(rootView:
            SubtitleOverlayView()
                .environment(controller)
        )
        hostingView.sizingOptions = .preferredContentSize
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        panel.contentView = hostingView
        panel.alphaValue = 0.0
        return panel
    }

    private func positionOnActiveScreen() {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        panel.layoutIfNeeded()
        let size = panel.frame.size
        let screenFrame = screen.visibleFrame

        // Center horizontally, 80px from bottom (above Dock)
        let targetWidth = min(screenFrame.width * 0.7, 900)
        let x = screenFrame.midX - targetWidth / 2
        let y = screenFrame.minY + 80
        panel.setFrame(NSRect(x: x, y: y, width: targetWidth, height: size.height), display: true)
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild build -scheme NemoNoise -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**If `.translationTask` is not found**: Verify macOS deployment target is 15.0+. The `Translation` framework requires macOS 15.

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift NemoNoise/UI/SubtitleOverlay/SubtitleOverlayController.swift
git commit -m "feat(translation): add bilingual subtitle overlay view and controller"
```

---

### Task 5: TranslationController

**Files:**
- Create: `NemoNoise/App/TranslationController.swift`

This is the pipeline coordinator. It manages the full lifecycle: permission check → system audio capture → ASR (English) → publish English text → SubtitleOverlayView handles translation via `.translationTask`.

- [ ] **Step 1: Modify AppleSpeechASREngine.swift to accept locale override**

In `NemoNoise/Services/ASR/AppleSpeechASREngine.swift`, change the `init()` to accept an optional locale parameter:

Replace:
```swift
init() throws {
    let pref = LanguagePreference.current
```

With:
```swift
init(locale: String? = nil) throws {
    let pref = LanguagePreference.current
```

Replace:
```swift
        if let localeId = pref.localeIdentifier {
            resolved = SFSpeechRecognizer(locale: Locale(identifier: localeId))
```

With:
```swift
        if let localeId = locale ?? pref.localeIdentifier {
            resolved = SFSpeechRecognizer(locale: Locale(identifier: localeId))
```

- [ ] **Step 2: Create TranslationController.swift**

```swift
import SwiftUI
import KeyboardShortcuts

@MainActor @Observable
final class TranslationController {
    var translationState: TranslationState = .idle
    var englishText: String = ""
    var chineseText: String = ""
    var isTranslating: Bool = false

    let translationService: AppleTranslationService = AppleTranslationService()
    private var audioCapture: SystemAudioCapture?
    private var asrEngine: AppleSpeechASREngine?
    private var captureTask: Task<Void, Never>?
    private var subtitleController: SubtitleOverlayController?

    private weak var recordingController: RecordingController?

    func setRecordingController(_ controller: RecordingController) {
        self.recordingController = controller
    }

    var isActive: Bool {
        translationState != .idle
    }

    // MARK: - Toggle

    func toggle() {
        if isActive {
            stopTranslation()
        } else {
            startTranslation()
        }
    }

    // MARK: - Start

    private func startTranslation() {
        guard translationState == .idle else { return }

        // Mutual exclusion: stop dictation if active
        if let rc = recordingController, rc.recordingState != .ready {
            return
        }

        _ = LogService.startSession()
        LogService.info("Translation mode starting", category: "Translation")

        // Check screen recording permission
        guard CGPreflightScreenCaptureAccess() else {
            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = "NemoNoise needs screen recording permission to capture system audio.\n\nGo to System Settings → Privacy & Security → Screen Recording, then enable NemoNoise."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            alert.window.level = .floating
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }

        // Create ASR engine with English locale
        let engine: AppleSpeechASREngine
        do {
            engine = try AppleSpeechASREngine(locale: "en-US")
            engine.reset()
        } catch {
            LogService.error("Failed to create English ASR engine: \(error.localizedDescription)", category: "Translation")
            translationState = .error(error.localizedDescription)
            return
        }
        self.asrEngine = engine

        translationState = .capturing
        englishText = ""
        chineseText = ""
        showSubtitle()

        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = SystemAudioCapture()
                self.audioCapture = capture
                let audioStream = try await capture.start()

                for await chunk in audioStream {
                    guard self.isActive else { break }
                    do {
                        let result = try await engine.feedChunk(chunk.samples, sampleRate: 16000)
                        if result.isFinal && !result.text.isEmpty {
                            self.englishText = result.text
                            LogService.info("ASR final: \(result.text.prefix(50))", category: "Translation")
                        }
                    } catch {
                        LogService.warn("ASR feedChunk error: \(error.localizedDescription)", category: "Translation")
                    }
                }
            } catch {
                LogService.error("System audio capture error: \(error.localizedDescription)", category: "Translation")
                self.translationState = .error(error.localizedDescription)
                self.hideSubtitle()
            }
        }
    }

    // MARK: - Stop

    func stopTranslation() {
        LogService.info("Translation mode stopping", category: "Translation")

        captureTask?.cancel()
        captureTask = nil
        audioCapture?.stop()
        audioCapture = nil

        // Finalize ASR
        if let engine = asrEngine {
            Task {
                _ = try? await engine.finish()
                engine.reset()
            }
        }
        asrEngine = nil

        hideSubtitle()
        translationState = .idle
        LogService.endSession()
    }

    // MARK: - Subtitle Overlay

    private func showSubtitle() {
        if subtitleController == nil {
            subtitleController = SubtitleOverlayController(controller: self)
        }
        subtitleController?.show()
    }

    private func hideSubtitle() {
        subtitleController?.hide()
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild build -scheme NemoNoise -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/App/TranslationController.swift NemoNoise/Services/ASR/AppleSpeechASREngine.swift
git commit -m "feat(translation): add TranslationController pipeline coordinator"
```

---

### Task 6: Integration

Wire the new translation feature into the existing app: keyboard shortcut, menu bar, app entry point, and mutual exclusion with dictation mode.

#### 6a: Add translation keyboard shortcut

**Files:**
- Modify: `NemoNoise/Services/Input/HotkeyShortcuts.swift`

- [ ] **Step 1: Add `.translationMode` shortcut name**

In `HotkeyShortcuts.swift`, add inside the `extension KeyboardShortcuts.Name`:

```swift
extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
    static let translationMode = Self("translationMode")
}
```

#### 6b: Add translation shortcut to Settings

**Files:**
- Modify: `NemoNoise/UI/Settings/SettingsView.swift`

- [ ] **Step 2: Add translation shortcut recorder to shortcuts tab**

In `SettingsView.swift`, inside `shortcutsSection`, add after the existing `KeyboardShortcuts.Recorder`:

```swift
KeyboardShortcuts.Recorder("Translation Key:", name: .translationMode)
```

And add a description after it:
```swift
Text("Toggle real-time translation mode. Captures system audio and displays bilingual subtitles.")
    .font(.caption).foregroundStyle(.secondary)
```

#### 6c: Add translation toggle to Menu Bar

**Files:**
- Modify: `NemoNoise/UI/Menubar/MenubarView.swift`

- [ ] **Step 3: Add translation mode toggle button**

In `MenuBarPopoverView`, add after the `Divider()` that follows `hotkeyDisplayText` (around line 38), before the "Check for Updates" section:

```swift
Divider()

HStack(spacing: 8) {
    Circle()
        .fill(translationStatusColor)
        .frame(width: 8, height: 8)
    Button(translationController.isActive ? "Stop Translation" : "Start Translation") {
        translationController.toggle()
    }
    .buttonStyle(.plain)
    .foregroundStyle(translationController.isActive ? .red : .primary)
}
```

Add the `TranslationController` environment and computed properties. At the top of `MenuBarPopoverView`, add:
```swift
@Environment(TranslationController.self) private var translationController
```

Add the computed property:
```swift
private var translationStatusColor: Color {
    switch translationController.translationState {
    case .idle: return .gray
    case .capturing: return .green
    case .error: return .red
    }
}
```

#### 6d: Wire TranslationController into app

**Files:**
- Modify: `NemoNoise/App/NemoNoiseApp.swift`

- [ ] **Step 4: Add TranslationController as app state**

In `NemoNoiseApp`, add a new `@State` property:
```swift
@State private var translationController = TranslationController()
```

In `init()`, after the existing setup, add:
```swift
// Wire translation ↔ recording mutual exclusion
```

In the `body`, pass the translation controller to all environments. Modify the `MenuBarExtra` content:
```swift
MenuBarPopoverView(updater: updaterController.updater)
    .environment(controller)
    .environment(translationController)
```

And the `Settings` content:
```swift
SettingsView()
    .environment(controller)
    .environment(controller.modelManager)
    .environment(translationController)
```

In `NemoNoiseApp.init()`, after creating the controller, wire the mutual exclusion:
```swift
// In init, after _ = CrashGuard.shared:
// We need to set up mutual exclusion after @State is initialized,
// so we do it lazily via .onAppear or .task in the body.
```

Actually, a simpler approach: do the wiring in the body using `.task`:

Add `.task` modifier to the `MenuBarExtra` content:
```swift
.task {
    translationController.setRecordingController(controller)
}
```

#### 6e: Add mutual exclusion in RecordingController

**Files:**
- Modify: `NemoNoise/App/RecordingController.swift`

- [ ] **Step 5: Guard dictation against active translation**

In `startRecording()` method, add a guard at the top (after `guard recordingState == .ready`):

```swift
// Don't start dictation if translation mode is active
// This is checked via a weak reference set up by the app
```

Since `RecordingController` doesn't have a reference to `TranslationController`, we'll use a different approach. Add a closure property:

In `RecordingController`, add:
```swift
var onTranslationActiveCheck: (() -> Bool)?
```

In `startRecording()`, after the first guard:
```swift
guard !(onTranslationActiveCheck?() ?? false) else { return }
```

Then in `NemoNoiseApp`'s `.task`:
```swift
controller.onTranslationActiveCheck = { [weak translationController] in
    translationController?.isActive ?? false
}
```

#### 6f: Add hotkey event handling for translation mode

**Files:**
- Modify: `NemoNoise/App/TranslationController.swift`

- [ ] **Step 6: Add hotkey monitoring to TranslationController**

Add to `TranslationController`:

```swift
private var hotkeyTask: Task<Void, Never>?

func startHotkeyMonitoring() {
    hotkeyTask = Task { [weak self] in
        for await event in KeyboardShortcuts.events(for: .translationMode) {
            guard let self, event == .keyDown else { return }
            self.toggle()
        }
    }
}

func stopHotkeyMonitoring() {
    hotkeyTask?.cancel()
    hotkeyTask = nil
}
```

Call `startHotkeyMonitoring()` in init or from the app startup. In `NemoNoiseApp`'s `.task`:
```swift
translationController.startHotkeyMonitoring()
```

- [ ] **Step 7: Build and verify**

Run: `xcodebuild build -scheme NemoNoise -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(translation): integrate translation mode into app UI, hotkeys, and menu bar"
```

---

### Task 7: Manual End-to-End Verification

- [ ] **Step 1: Build and run the app**

- [ ] **Step 2: Grant Screen Recording permission**
- Open System Settings → Privacy & Security → Screen Recording
- Enable NemoNoise
- Restart the app if needed

- [ ] **Step 3: Set up translation hotkey**
- Open Settings → Shortcuts tab
- Record a key for "Translation Key"

- [ ] **Step 4: Test translation mode**
- Play an English YouTube video or audio
- Press the translation hotkey (or use menu bar toggle)
- Verify: green dot appears in subtitle bar, English text appears as recognized
- Verify: Chinese translation appears below English text
- Verify: new results replace previous ones
- Press hotkey again to stop

- [ ] **Step 5: Test mutual exclusion**
- Start translation mode
- Try pressing dictation hotkey → should not start recording
- Stop translation mode
- Verify dictation works normally

- [ ] **Step 6: Test error states**
- Revoke screen recording permission in System Settings
- Try starting translation mode → should show permission alert
- Re-grant permission and verify recovery

- [ ] **Step 7: Final commit if any fixes needed**

---

## Self-Review

**Spec coverage:**
- [x] System audio capture via ScreenCaptureKit → Task 3
- [x] Translation via Apple Translation → Task 2 + Task 4 (SubtitleOverlayView)
- [x] Bilingual subtitle overlay → Task 4
- [x] TranslationController coordinator → Task 5
- [x] Menu bar toggle → Task 6c
- [x] Keyboard shortcut toggle → Task 6a + 6f
- [x] Mutual exclusion with dictation → Task 6e
- [x] Permission handling → Task 5 (startTranslation)
- [x] Error handling → Task 5 (startTranslation, capture errors)
- [x] Settings UI → Task 6b

**Placeholder scan:** No TBD, TODO, or "fill in details" patterns.

**Type consistency:** `AudioChunk` used consistently across SystemAudioCapture and ASR engines. `TranslationState` used in TranslationController and SubtitleOverlayView. `TranslationController` passed via `.environment()` consistently.
