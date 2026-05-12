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
    var showErrorAlert: Bool = false
    var errorMessage: String = ""
    var showAccessibilityGuide: Bool = false
    var isListeningSilence: Bool = false
    var recordingDuration: TimeInterval = 0
    var showToast: Bool = false
    var toastMessage: String = ""

    private var silenceTimer: Timer?
    private var toastTask: Task<Void, Never>?
    private let maxRecordingDuration: TimeInterval = 120
    private var timerTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    
    let modelManager = ModelManager()
    private let orchestrator: SpeechOrchestrator
    private let textInjector = TextInjector()
    let hotkeyMonitor = HotkeyMonitor()
    private var overlayController: OverlayWindowController?

    var recordingMode: RecordingMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "recordingMode") ?? "pushToTalk"
            return RecordingMode(rawValue: raw) ?? .pushToTalk
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "recordingMode")
        }
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
            return "Hold **\(keyName)** to record"
        case .toggle:
            return "Press **\(keyName)** to start/stop"
        }
    }

    init() {
        self.orchestrator = SpeechOrchestrator(modelManager: modelManager)

        orchestrator.onEngineFallback = { [weak self] failedEngine in
            guard let self else { return }
            self.isStreaming = true
            self.toastMessage = "Switched to local engine"
            self.showToast = true
            self.toastTask?.cancel()
            self.toastTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self.showToast = false
            }
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

        textInjector.captureTarget()
        _ = LogService.startSession()
        LogService.info("Recording started, mode: \(recordingMode.rawValue), engine streaming: \(orchestrator.isStreaming)", category: "Recording")

        recordingState = .recording
        confirmedSegments = []
        partialText = ""
        isStreaming = orchestrator.isStreaming
        showOverlay()
        startTimer()

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
                    toastTask?.cancel()
                    toastTask = Task {
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

        if let cloudError = error as? CloudASRError, case .authenticationFailed = cloudError {
            toastMessage = "API key invalid. Please update in Settings."
            showToast = true
            toastTask?.cancel()
            toastTask = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                showToast = false
            }
        } else {
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }

        recordingState = .ready
        orchestrator.stop()
        hideOverlay()
        LogService.endSession()
    }

    private func injectText(_ text: String) async {
        let start = ContinuousClock.now
        let success = textInjector.injectAX(text)
        let elapsed = ContinuousClock.now - start

        if success {
            LogService.info("Text injected via AX, duration: \(elapsed.description)", category: "TextInjection")
            toastTask?.cancel()
            toastTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                hideOverlay()
            }
        } else {
            LogService.warn("AX injection failed, copying to clipboard, duration: \(elapsed.description)", category: "TextInjection")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            toastMessage = "Copied to clipboard"
            showToast = true
            if !AXIsProcessTrusted() {
                showAccessibilityGuide = true
            }
            toastTask?.cancel()
            toastTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                showToast = false
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

}
