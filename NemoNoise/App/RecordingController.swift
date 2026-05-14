import SwiftUI
import AVFoundation
import ApplicationServices
import KeyboardShortcuts

@MainActor @Observable
final class RecordingController: OverlayWriter {
    // MARK: - UI state (observed by SwiftUI)

    var recordingState: RecordingState = .ready
    var confirmedSegments: [TranscriptionSegment] = []
    var partialText: String = ""
    var isStreaming: Bool = true
    var micLevel: Float = 0
    var isListeningSilence: Bool = false
    var recordingDuration: TimeInterval = 0

    var recordingMode: RecordingMode {
        didSet { UserDefaults.standard.set(recordingMode.rawValue, forKey: AppDefaults.Keys.recordingMode) }
    }

    var hotkeyDisplayText: String {
        let keyName: String
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            keyName = shortcut.description
        } else {
            keyName = "Not set"
        }
        switch recordingMode {
        case .pushToTalk: return "Hold \(keyName) to record"
        case .toggle:     return "Press \(keyName) to start/stop"
        }
    }

    // MARK: - Dependencies

    let modelManager = ModelManager()
    let hotkeyMonitor = HotkeyMonitor()
    private let textInjector = TextInjector()

    private var pipeline: TranscriptionPipeline?
    private var mutex: RecordingMutex?
    private var overlayController: OverlayWindowController?

    /// Exposes the text injector so `NemoNoiseApp` can wire it into the
    /// dictation pipeline's `TextInjectorSink`.
    var injector: any TextInjecting { textInjector }

    /// Capture the AX target at hotkey DOWN before the pipeline starts.
    func captureInjectionTarget() {
        textInjector.captureTarget()
    }

    // MARK: - Internal state

    private var silenceTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private let maxRecordingDuration: TimeInterval = 120
    private var timerTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var escMonitor: Any?

    // MARK: - Init

    init() {
        let raw = UserDefaults.standard.string(forKey: AppDefaults.Keys.recordingMode) ?? AppDefaults.Defaults.recordingMode
        self.recordingMode = RecordingMode(rawValue: raw) ?? .pushToTalk

        hotkeyMonitor.onKeyDown = { [weak self] in
            Task { @MainActor [weak self] in self?.handleHotkeyDown() }
        }
        hotkeyMonitor.onKeyUp = { [weak self] in
            Task { @MainActor [weak self] in self?.handleHotkeyUp() }
        }
        HotkeyMigration.run()
        hotkeyMonitor.start()
    }

    func bind(pipeline: TranscriptionPipeline, mutex: RecordingMutex) {
        self.pipeline = pipeline
        self.mutex = mutex
        self.isStreaming = pipeline.isStreaming
    }

    // MARK: - Hotkey handlers

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

    // MARK: - Recording lifecycle

    private func startRecording() {
        guard recordingState == .ready, let pipeline, let mutex else { return }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized: break
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if granted { self.startRecording() }
            }
            return
        case .denied, .restricted:
            MicPermissionAlert.present()
            return
        @unknown default:
            return
        }

        guard mutex.tryAcquire(.dictation) else { return }

        // Lock the AX target at hotkey DOWN to avoid cursor-move races.
        textInjector.captureTarget()
        _ = LogService.startSession()
        LogService.info("Recording started, mode: \(recordingMode.rawValue), engine streaming: \(pipeline.isStreaming)", category: "Recording")

        recordingState = .recording
        confirmedSegments = []
        partialText = ""
        isStreaming = pipeline.isStreaming
        showOverlay()
        startTimer()
        startEscMonitor()

        pipelineTask = Task { [weak self, pipeline] in
            guard let self else { return }
            do {
                self.resetSilenceTimer()
                for try await event in pipeline.start() {
                    switch event {
                    case .partial(_, let rms):
                        self.micLevel = rms
                        self.isListeningSilence = false
                        self.resetSilenceTimer()
                    case .rms(let level):
                        self.micLevel = level
                    case .engineFallback(let from):
                        self.isStreaming = pipeline.isStreaming
                        LogService.info("Engine fallback from \(from)", category: "Recording")
                        ToastWindowController.show("Switched to local engine", style: .info)
                    case .final:
                        break // handled in stopRecording via finalize()
                    }
                }
            } catch {
                self.handlePipelineError(error)
            }
        }
    }

    private func stopRecording() {
        guard recordingState == .recording, let pipeline, let mutex else { return }

        LogService.info("Recording stopped, duration: \(String(format: "%.1f", recordingDuration))s", category: "Recording")

        recordingState = .processing
        stopTimer()
        invalidateSilenceTimer()
        stopEscMonitor()

        Task { [weak self, pipeline, mutex] in
            defer { mutex.release(.dictation) }
            guard let self else { return }
            do {
                let final = try await pipeline.finalize()
                self.partialText = ""
                if !final.text.isEmpty {
                    let segment = TranscriptionSegment(text: final.text, emotion: final.emotion)
                    self.confirmedSegments.append(segment)
                    LogService.info("Transcription complete, length: \(final.text.count) chars", category: "Recording")
                } else {
                    LogService.info("Transcription complete, no text produced", category: "Recording")
                }
                self.scheduleOverlayHide(after: 2)
                self.recordingState = .ready
                LogService.endSession()
            } catch {
                self.handlePipelineError(error)
            }
        }
    }

    private func handlePipelineError(_ error: Error) {
        LogService.error("Recording error: \(error.localizedDescription)", category: "Recording")
        SentryService.capture(error: error)

        mutex?.release(.dictation)

        if let pipelineErr = error as? PipelineError {
            switch pipelineErr {
            case .sourceUnavailable:
                MicPermissionAlert.present()
            case .engineFailedFatally(let underlying):
                if let cloud = underlying as? CloudASRError, case .authenticationFailed = cloud {
                    ToastWindowController.show("API key invalid. Please update in Settings.", style: .error, duration: 5)
                } else {
                    presentAlert(title: "Engine Error", message: pipelineErr.localizedDescription)
                }
            case .finalizeFailed(let underlying):
                presentAlert(title: "Recognition Error", message: underlying.localizedDescription)
            }
        } else {
            presentAlert(title: "Error", message: error.localizedDescription)
        }

        recordingState = .ready
        pipeline?.stop()
        stopEscMonitor()
        hideOverlay()
        LogService.endSession()
    }

    // MARK: - Overlay + timer + ESC

    private func showOverlay() {
        if overlayController == nil {
            overlayController = OverlayWindowController(controller: self)
        }
        overlayController?.show()
    }

    private func hideOverlay() { overlayController?.hide() }

    private func scheduleOverlayHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hideOverlay()
        }
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
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
                if self.recordingDuration >= self.maxRecordingDuration {
                    LogService.info("Max recording duration reached, auto-stopping", category: "Recording")
                    ToastWindowController.show("Recording stopped at \(Int(self.maxRecordingDuration))s limit", style: .warning)
                    self.stopRecording()
                    return
                }
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
}
