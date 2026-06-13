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
    var spectrum: [Float] = Array(repeating: 0, count: 16)
    var isListeningSilence: Bool = false
    var recordingDuration: TimeInterval = 0
    var currentEngineLabel: String = "Apple"

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
    let historyStore = TranscriptHistoryStore()
    let hotkeyMonitor = HotkeyMonitor()
    private let textInjector = TextInjector()

    private var pipeline: TranscriptionPipeline?
    private var mutex: RecordingMutex?
    private var overlayController: OverlayWindowController?

    /// Exposes the text injector so `NemoNoiseApp` can wire it into the
    /// dictation pipeline's `TextInjectorSink`.
    var injector: any TextInjecting { textInjector }

    // MARK: - Internal state

    private var silenceTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private let maxRecordingDuration: TimeInterval = 120
    private var timerTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var escMonitor: Any?
    private var recordingStartedAt: Date?

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

    /// OverlayWriter conformance — called by OverlayProgressSink when the
    /// engine starts a new utterance (segment reset), so the previous partial
    /// becomes a confirmed segment instead of being overwritten.
    func appendConfirmedSegment(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        confirmedSegments.append(TranscriptionSegment(text: trimmed, emotion: nil))
        LogService.info("Segment promoted (count=\(confirmedSegments.count)): \"\(trimmed.prefix(40))\"", category: "Recording")
    }

    /// Closure that rebuilds the dictation pipeline using whatever the user has
    /// currently picked in Settings. Set by `NemoNoiseApp` once wiring is done.
    var pipelineRebuildHandler: (@MainActor () -> Void)?

    /// Triggered from Settings when the user changes engine selection. Rebuilds
    /// the dictation pipeline so the new choice (and any fallback toast) takes
    /// effect immediately — except while a recording is in progress, where we
    /// defer to avoid orphaning the active session.
    func requestPipelineRebuild() {
        guard recordingState == .ready else {
            ToastWindowController.show(
                "Engine change will apply after the current recording",
                style: .info
            )
            return
        }
        pipelineRebuildHandler?()
    }

    // MARK: - Hotkey handlers

    func handleHotkeyDown() {
        LogService.info("HotkeyDown — mode=\(recordingMode.rawValue) state=\(recordingState)", category: "Recording")
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
                LogService.info("HotkeyDown ignored — state=\(recordingState) is neither .ready nor .recording", category: "Recording")
                break
            }
        }
    }

    func handleHotkeyUp() {
        LogService.info("HotkeyUp — mode=\(recordingMode.rawValue) state=\(recordingState)", category: "Recording")
        if recordingMode == .pushToTalk && recordingState == .recording {
            performHaptic()
            let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            if elapsed < 0.3 {
                abortRecording()
            } else {
                stopRecording()
            }
        }
    }

    private func performHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    // MARK: - Recording lifecycle

    private func startRecording() {
        guard recordingState == .ready else { return }
        hideTask?.cancel()

        guard AXIsProcessTrusted() else {
            AccessibilityAlert.present()
            return
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized: break
        case .notDetermined:
            Task { @MainActor in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if granted {
                    self.startRecording()
                } else {
                    MicPermissionAlert.present()
                }
            }
            return
        case .denied, .restricted:
            MicPermissionAlert.present()
            return
        @unknown default:
            return
        }

        guard let pipeline, let mutex else {
            if pipeline == nil {
                ToastWindowController.show("Engines warming up…", style: .info, duration: 1.5)
            }
            return
        }
        guard mutex.tryAcquire(.dictation) else { return }

        // Lock the AX target at hotkey DOWN to avoid cursor-move races.
        textInjector.captureTarget()
        _ = LogService.startSession()
        LogService.info("Recording started, mode: \(recordingMode.rawValue), engine streaming: \(pipeline.isStreaming)", category: "Recording")

        recordingStartedAt = Date()
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
                    case .partial(_, let rms, let spectrum):
                        self.micLevel = rms
                        self.applyEnvelope(spectrum)
                        self.isListeningSilence = false
                        self.resetSilenceTimer()
                    case .level(let rms, let spectrum):
                        self.micLevel = rms
                        self.applyEnvelope(spectrum)
                    case .engineFallback(let from):
                        self.isStreaming = pipeline.isStreaming
                        self.currentEngineLabel = "Apple (fallback)"
                        LogService.info("Engine fallback from \(from)", category: "Recording")
                        ToastWindowController.show("Switched to local engine", style: .info)
                    case .final:
                        break
                    }
                }
            } catch {
                self.handlePipelineError(error)
            }
        }
    }

    private func stopRecording() {
        LogService.info("stopRecording invoked — state=\(recordingState), pipeline=\(pipeline != nil), mutex=\(mutex != nil)", category: "Recording")
        guard recordingState == .recording, let pipeline, let mutex else {
            LogService.warn("stopRecording guard failed — bailing out", category: "Recording")
            return
        }

        LogService.info("Recording stopped, duration: \(String(format: "%.1f", recordingDuration))s", category: "Recording")

        recordingState = .processing
        pipelineTask?.cancel()
        pipelineTask = nil
        stopTimer()
        invalidateSilenceTimer()
        stopEscMonitor()

        Task { [weak self, pipeline, mutex] in
            defer { mutex.release(.dictation) }
            guard let self else { return }
            LogService.info("stopRecording Task started — calling pipeline.finalize()", category: "Recording")
            do {
                let final = try await pipeline.finalize()
                LogService.info("pipeline.finalize() returned — final.text length=\(final.text.count), partialText length=\(self.partialText.count), confirmedSegments count=\(self.confirmedSegments.count)", category: "Recording")

                // pipeline.finalize() calls sink.deliver(isFinal=true), which
                // OverlayProgressSink now handles by appending final.text to
                // confirmedSegments. So the trailing piece is already there
                // when final.text is non-empty. The fallback below covers the
                // case where engine.finish() returned empty but a partial is
                // still on screen (engines that flush entirely via partials).
                let lastPartial = self.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.partialText = ""
                if final.text.isEmpty, !lastPartial.isEmpty {
                    self.confirmedSegments.append(TranscriptionSegment(text: lastPartial, emotion: final.emotion))
                }

                let pieces = self.confirmedSegments.map(\.text).filter { !$0.isEmpty }
                let dispatchText = TranscriptJoin.sentences(pieces)
                LogService.info("Dispatch text assembled — \(pieces.count) segments, total length=\(dispatchText.count)", category: "Recording")

                let engineLabel = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType)
                await OutputDispatcher.dispatch(
                    text: dispatchText,
                    injector: self.textInjector,
                    historyStore: self.historyStore,
                    engineLabel: engineLabel
                )

                self.scheduleOverlayHide(after: 2)
                self.micLevel = 0
                self.spectrum = Array(repeating: 0, count: 16)
                self.recordingState = .ready
                LogService.endSession()
            } catch {
                LogService.error("stopRecording Task threw: \(error)", category: "Recording")
                self.handlePipelineError(error)
            }
        }
    }

    /// Abort an in-flight recording without finalizing. Used when a
    /// push-to-talk press is shorter than the minimum useful duration:
    /// audio is discarded, the mutex is released synchronously, and state
    /// returns to `.ready` in the same MainActor tick (no `.processing`
    /// window). Toggle mode never triggers this path.
    private func abortRecording() {
        guard recordingState == .recording, let pipeline, let mutex else { return }
        LogService.info("Aborting recording (too short)", category: "Recording")

        pipelineTask?.cancel()
        pipelineTask = nil
        pipeline.stop()
        mutex.release(.dictation)
        stopTimer()
        invalidateSilenceTimer()
        stopEscMonitor()

        confirmedSegments = []
        partialText = ""
        micLevel = 0
        spectrum = Array(repeating: 0, count: 16)
        recordingState = .ready
        LogService.endSession()
        hideOverlay()
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
                if let apple = underlying as? AppleSpeechError, apple == .siriDisabled {
                    ToastWindowController.show("请启用 Siri：系统设置 → Siri 与听写", style: .warning, duration: 5)
                } else {
                    ToastWindowController.show("Engine error: \(underlying.localizedDescription)", style: .error, duration: 4)
                }
            case .finalizeFailed(let underlying):
                ToastWindowController.show("Recognition failed: \(underlying.localizedDescription)", style: .warning, duration: 4)
            }
        } else {
            ToastWindowController.show("Recording error: \(error.localizedDescription)", style: .error, duration: 4)
        }

        recordingState = .ready
        pipeline?.stop()
        stopEscMonitor()
        hideOverlay()
        LogService.endSession()
    }

    /// Called (on the MainActor) when `MicAudioSource` detects a mid-recording
    /// audio interruption. Behavior: stop-and-notify — gracefully finalize the
    /// current session (keeping recognized text) via `stopRecording()`, and
    /// show a toast explaining why. No-op unless actively recording.
    func handleAudioInterruption(_ reason: AudioInterruptionReason) {
        guard recordingState == .recording else { return }
        let message: String
        switch reason {
        case .deviceConfigurationChanged:
            message = "输入设备已变化，录音已停止"
        case .audioStalled:
            message = "未检测到音频输入，录音已停止"
        }
        LogService.warn("Audio interruption (\(reason)) — finalizing session", category: "Recording")
        ToastWindowController.show(message, style: .warning, duration: 4)
        stopRecording()
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

    private func applyEnvelope(_ target: [Float]) {
        let dt: Float = 0.085
        let attackTau: Float = 0.06
        let releaseTau: Float = 0.20
        if spectrum.count != target.count {
            spectrum = Array(repeating: 0, count: target.count)
        }
        for i in 0..<spectrum.count {
            let tau = target[i] > spectrum[i] ? attackTau : releaseTau
            let alpha = 1 - exp(-dt / tau)
            spectrum[i] += (target[i] - spectrum[i]) * alpha
        }
    }

}
