import SwiftUI
import AVFoundation
import ApplicationServices
import KeyboardShortcuts

@MainActor @Observable
final class RecordingController {
    var recordingState: RecordingState = .ready
    var confirmedSegments: [TranscriptionSegment] = []
    var partialText: String = ""
    var isStreaming: Bool = true
    var micLevel: Float = 0
    var isListeningSilence: Bool = false
    var recordingDuration: TimeInterval = 0
    var onTranslationActiveCheck: (() -> Bool)?

    private var silenceTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private let maxRecordingDuration: TimeInterval = 120
    private var timerTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var escMonitor: Any?
    
    let modelManager = ModelManager()
    private let orchestrator: SpeechOrchestrator
    private let textInjector = TextInjector()
    let hotkeyMonitor = HotkeyMonitor()
    private var overlayController: OverlayWindowController?

    var recordingMode: RecordingMode {
        didSet { UserDefaults.standard.set(recordingMode.rawValue, forKey: "recordingMode") }
    }

    var hotkeyDisplayText: String {
        let keyName: String
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            keyName = shortcut.description
        } else {
            keyName = "Not set"
        }
        switch recordingMode {
        case .pushToTalk:
            return "Hold \(keyName) to record"
        case .toggle:
            return "Press \(keyName) to start/stop"
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: "recordingMode") ?? "pushToTalk"
        self.recordingMode = RecordingMode(rawValue: raw) ?? .pushToTalk
        self.orchestrator = SpeechOrchestrator(modelManager: modelManager)

        orchestrator.onEngineFallback = { [weak self] _ in
            guard let self else { return }
            self.isStreaming = true
            ToastWindowController.show("Switched to local engine", style: .info)
        }

        hotkeyMonitor.onKeyDown = { [weak self] in
            Task { @MainActor [weak self] in self?.handleHotkeyDown() }
        }
        hotkeyMonitor.onKeyUp = { [weak self] in
            Task { @MainActor [weak self] in self?.handleHotkeyUp() }
        }
        HotkeyMigration.run()
        hotkeyMonitor.start()
    }

    func handleHotkeyDown() {
        switch recordingMode {
        case .pushToTalk:
            guard recordingState == .ready else { return }
            performHaptic()
            startRecording()
        case .toggle:
            switch recordingState {
            case .ready:
                performHaptic()
                startRecording()
            case .recording:
                performHaptic()
                stopRecording()
            default:
                break
            }
        }
    }

    func handleHotkeyUp() {
        if recordingMode == .pushToTalk && recordingState == .recording {
            performHaptic()
            stopRecording()
        }
    }
    
    private func performHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    private func startRecording() {
        guard recordingState == .ready else { return }
        guard !(onTranslationActiveCheck?() ?? false) else { return }

        textInjector.captureTarget()
        _ = LogService.startSession()
        LogService.info("Recording started, mode: \(recordingMode.rawValue), engine streaming: \(orchestrator.isStreaming)", category: "Recording")

        recordingState = .recording
        confirmedSegments = []
        partialText = ""
        isStreaming = orchestrator.isStreaming
        showOverlay()
        startTimer()
        startEscMonitor()

        transcriptionTask = Task {
            let stream = orchestrator.startTranscription()
            resetSilenceTimer()

            do {
                for try await result in stream {
                    self.micLevel = result.rmsLevel
                    if !result.text.isEmpty {
                        self.partialText = result.text
                        self.isListeningSilence = false
                        resetSilenceTimer()
                    }
                }
            } catch {
                handleError(error)
            }
        }
    }

    private func stopRecording() {
        guard recordingState == .recording else { return }

        LogService.info("Recording stopped, duration: \(String(format: "%.1f", recordingDuration))s", category: "Recording")

        recordingState = .processing
        stopTimer()
        invalidateSilenceTimer()
        stopEscMonitor()

        Task {
            do {
                let finalResult = try await orchestrator.finalize()
                self.partialText = ""
                if !finalResult.text.isEmpty {
                    let segment = TranscriptionSegment(text: finalResult.text, emotion: finalResult.emotion)
                    self.confirmedSegments.append(segment)
                    LogService.info("Transcription complete, length: \(finalResult.text.count) chars", category: "Recording")
                    await injectText(finalResult.text)
                } else {
                    LogService.info("Transcription complete, no text produced", category: "Recording")
                    hideTask?.cancel()
                    hideTask = Task {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        hideOverlay()
                    }
                }
                recordingState = .ready
                LogService.endSession()
            } catch {
                handleError(error)
            }
        }
    }

    private func handleError(_ error: Error) {
        LogService.error("Recording error: \(error.localizedDescription)", category: "Recording")
        SentryService.capture(error: error)

        let message = error.localizedDescription

        if message.contains("Siri and Dictation are disabled") {
            ToastWindowController.show("请启用 Siri：系统设置 → Siri 与听写", style: .warning, duration: 5)
        } else if let cloudError = error as? CloudASRError, case .authenticationFailed = cloudError {
            ToastWindowController.show("API key invalid. Please update in Settings.", style: .error, duration: 5)
        } else {
            presentAlert(title: "Error", message: message)
        }

        recordingState = .ready
        orchestrator.stop()
        stopEscMonitor()
        hideOverlay()
        LogService.endSession()
    }

    private func injectText(_ text: String) async {
        let start = ContinuousClock.now
        let success = textInjector.injectAX(text)
        let elapsed = ContinuousClock.now - start

        if success {
            LogService.info("Text injected, duration: \(elapsed.description)", category: "TextInjection")
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                hideOverlay()
            }
        } else {
            LogService.warn("All injection methods failed, duration: \(elapsed.description)", category: "TextInjection")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ToastWindowController.show("Copied to clipboard", style: .success)
            if !AXIsProcessTrusted() {
                presentAccessibilityAlert()
            }
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                hideOverlay()
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

    private func startEscMonitor() {
        guard recordingMode == .toggle else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            if recordingState == .recording {
                performHaptic()
                stopRecording()
            }
            return nil
        }
    }

    private func stopEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert.runModal()
    }

    private func presentAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "NemoNoise needs Accessibility permission to inject text into other apps.\n\nGo to System Settings → Privacy & Security → Accessibility, then enable NemoNoise."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

}
