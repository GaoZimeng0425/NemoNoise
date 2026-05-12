import SwiftUI
import AVFoundation
import ApplicationServices

@MainActor @Observable
final class RecordingController {
    var recordingState: RecordingState = .ready
    var confirmedSegments: [TranscriptionSegment] = []
    var partialText: String = ""
    var isStreaming: Bool = true
    var micLevel: Float = 0
    var showCopyButton: Bool = false
    var showErrorAlert: Bool = false
    var errorMessage: String = ""
    var showAccessibilityGuide: Bool = false
    var isListeningSilence: Bool = false
    var recordingDuration: TimeInterval = 0
    
    private var silenceTimer: Timer?
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
        self.orchestrator = SpeechOrchestrator(modelManager: modelManager)
        
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
        recordingState = .recording
        confirmedSegments = []
        partialText = ""
        isStreaming = orchestrator.isStreaming
        showCopyButton = false
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
                    await injectText(finalResult.text)
                }
                recordingState = .ready
            } catch {
                handleError(error)
            }
        }
    }

    private func handleError(_ error: Error) {
        errorMessage = error.localizedDescription
        showErrorAlert = true
        recordingState = .ready
        orchestrator.stop()
        hideOverlay()
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

    func dismissOverlay() {
        guard recordingState == .ready else { return }
        confirmedSegments = []
        partialText = ""
        showCopyButton = false
        hideOverlay()
    }
}
