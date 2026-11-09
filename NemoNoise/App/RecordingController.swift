import SwiftUI
import AVFoundation
import ApplicationServices
import KeyboardShortcuts

/// UI state + orchestration for dictation. The per-recording work lives in
/// `DictationSession` (created per hotkey press, discarded afterwards); this
/// controller is the durable @Observable state the menubar/overlay read.
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
    /// Two-stage ESC (yap pattern): the first press only arms cancellation
    /// (the overlay shows a hint); a second press within the window stops.
    var isEscCancelArmed = false

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

    /// Builds a fresh per-session pipeline around the provider's resident
    /// engines. Nil while engines are loading/failed.
    private var pipelineFactory: (() -> TranscriptionPipeline?)?
    private var engineLabelProvider: (() -> String)?
    private var mutex: RecordingMutex?
    private var overlayController: OverlayWindowController?

    /// Exposes the text injector so `NemoNoiseApp` can wire it into the
    /// dictation pipeline's `TextInjectorSink`.
    var injector: any TextInjecting { textInjector }

    // MARK: - Internal state

    private var currentSession: DictationSession?
    private var hideTask: Task<Void, Never>?
    private var durationTicker: Task<Void, Never>?
    private var escArmTask: Task<Void, Never>?
    private var recordingStartedAt: Date?

    // MARK: - Wiring

    func bind(pipelineFactory: @escaping () -> TranscriptionPipeline?,
              engineLabel: @escaping () -> String,
              mutex: RecordingMutex) {
        self.pipelineFactory = pipelineFactory
        self.engineLabelProvider = engineLabel
        self.mutex = mutex
    }

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

    /// Closure that rebuilds the dictation engines using whatever the user has
    /// currently picked in Settings. Set by `NemoNoiseApp` once wiring is done.
    /// A rebuild never disturbs a running session — the session keeps its
    /// engine until it ends; the next session picks up the new one.
    var pipelineRebuildHandler: (@MainActor () -> Void)?

    func requestPipelineRebuild() {
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
                abortRecording(reason: "too short")
            } else {
                stopRecording()
            }
        }
    }

    private func performHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    private func disarmEscCancel() {
        escArmTask?.cancel()
        escArmTask = nil
        isEscCancelArmed = false
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
                    if self.recordingMode == .toggle {
                        // Toggle's single keypress gesture is complete —
                        // starting now is what the user asked for.
                        self.startRecording()
                    } else {
                        // Push-to-talk (#4): the key-up was swallowed by the
                        // permission dialog, so auto-starting now would record
                        // until the 120 s cap. Ask for a fresh press instead.
                        ToastWindowController.show(
                            "Microphone authorized — hold the hotkey to record",
                            style: .success,
                            duration: 3
                        )
                    }
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

        guard let mutex else { return }

        // A cheap per-session shell around the provider's resident engines.
        guard let pipeline = pipelineFactory?() else {
            ToastWindowController.show("Engines warming up…", style: .info, duration: 1.5)
            return
        }
        guard mutex.tryAcquire(.dictation) else {
            ToastWindowController.show("Audio is in use by another mode", style: .info, duration: 2)
            return
        }

        // Lock the AX target at hotkey DOWN to avoid cursor-move races.
        textInjector.captureTarget()
        _ = LogService.startSession()
        LogService.info("Recording started, mode: \(recordingMode.rawValue), engine streaming: \(pipeline.isStreaming)", category: "Recording")

        let session = DictationSession(pipeline: pipeline, mode: recordingMode)
        currentSession = session
        recordingStartedAt = Date()
        recordingState = .recording
        confirmedSegments = []
        partialText = ""
        isStreaming = pipeline.isStreaming
        currentEngineLabel = engineLabelProvider?() ?? currentEngineLabel
        showOverlay()
        wireCallbacks(session)
        session.start()

        durationTicker = Task { [weak self, weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let session else { return }
                self.recordingDuration = session.duration
            }
        }
    }

    private func wireCallbacks(_ session: DictationSession) {
        session.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .partial(_, let rms, let spectrum):
                self.micLevel = rms
                self.applyEnvelope(spectrum)
                self.isListeningSilence = false
            case .level(let rms, let spectrum):
                self.micLevel = rms
                self.applyEnvelope(spectrum)
            case .engineFallback(let from):
                self.isStreaming = session.pipeline.isStreaming
                self.currentEngineLabel = "Apple (fallback)"
                LogService.info("Engine fallback from \(from)", category: "Recording")
                ToastWindowController.show("Switched to local engine", style: .info)
            }
        }
        session.onSpeechSilence = { [weak self] in
            self?.isListeningSilence = true
        }
        session.onMaxDurationReached = { [weak self] in
            guard let self, self.recordingState == .recording else { return }
            LogService.info("Max recording duration reached, auto-stopping", category: "Recording")
            ToastWindowController.show("Recording stopped at 120s limit", style: .warning)
            self.stopRecording()
        }
        session.onEscPressed = { [weak self] in
            guard let self, self.recordingState == .recording else { return }
            if self.isEscCancelArmed {
                // Cancel means discard: the overlay promised "Esc again to
                // cancel" — finalizing here used to type the text anyway.
                self.performHaptic()
                self.disarmEscCancel()
                self.abortRecording(reason: "cancelled with Esc")
                ToastWindowController.show("Recording cancelled", style: .info, duration: 2)
            } else {
                // First press: arm only — a stray ESC shouldn't kill a long
                // dictation. The overlay swaps to the cancel hint.
                self.isEscCancelArmed = true
                self.escArmTask?.cancel()
                self.escArmTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    self?.disarmEscCancel()
                }
            }
        }
        session.onPipelineError = { [weak self] error in
            guard let self else { return }
            // While stopping, the stop task owns the session: it surfaces a
            // finalize failure itself. Handling it here too used to flip
            // state to .ready mid-stop, letting a new session start that the
            // stop task then tore down (mutex released, mic left running).
            guard self.recordingState == .recording else {
                LogService.warn("Pipeline error while stopping (stop task handles it): \(error.localizedDescription)",
                                category: "Recording")
                return
            }
            self.handlePipelineError(error)
        }
    }

    private func stopRecording() {
        LogService.info("stopRecording invoked — state=\(recordingState), session=\(currentSession != nil), mutex=\(mutex != nil)", category: "Recording")
        guard recordingState == .recording, let session = currentSession, let mutex else {
            LogService.warn("stopRecording guard failed — bailing out", category: "Recording")
            return
        }

        LogService.info("Recording stopped, duration: \(String(format: "%.1f", session.duration))s", category: "Recording")
        recordingState = .processing
        durationTicker?.cancel()
        durationTicker = nil
        disarmEscCancel()

        Task { [weak self, session, mutex] in
            // Released explicitly: on success after dispatch, on failure by
            // `handlePipelineError` once the session has drained.
            guard let self else { mutex.release(.dictation); return }
            LogService.info("stopRecording Task started — calling session.finish()", category: "Recording")
            do {
                let final = try await session.finish()
                LogService.info("session.finish() returned — final.text length=\(final.text.count), partialText length=\(self.partialText.count), confirmedSegments count=\(self.confirmedSegments.count), maxMicLevel=\(session.maxMicLevel)", category: "Recording")

                // session.finish() calls sink.deliver(isFinal=true), which
                // appends final.text to confirmedSegments. The fallback below
                // covers engines that flush entirely via partials.
                let lastPartial = self.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.partialText = ""
                if final.text.isEmpty, !lastPartial.isEmpty {
                    self.confirmedSegments.append(TranscriptionSegment(text: lastPartial, emotion: final.emotion))
                }

                let pieces = self.confirmedSegments.map(\.text).filter { !$0.isEmpty }
                let dispatchText = TranscriptJoin.sentences(pieces)
                LogService.info("Dispatch text assembled — \(pieces.count) segments, total length=\(dispatchText.count)", category: "Recording")

                let engineLabel = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType)

                // Opt-in LLM cleanup (Apple Intelligence): refine the text for
                // insertion only — history keeps the raw ASR output so engine
                // comparison / re-recognition stays honest.
                var insertText = dispatchText
                if UserDefaults.standard.bool(forKey: AppDefaults.Keys.llmTranscriptCleanup) {
                    if let cleaned = await TranscriptCleanupService.shared.cleanup(dispatchText) {
                        LogService.info("Transcript cleanup applied: \(dispatchText.count) → \(cleaned.count) chars", category: "Recording")
                        insertText = cleaned
                    }
                }

                await OutputDispatcher.dispatch(
                    text: insertText,
                    injector: self.textInjector,
                    historyStore: self.historyStore,
                    engineLabel: engineLabel,
                    audioURL: session.audioFileURL,
                    sessionDuration: session.duration,
                    historyText: dispatchText == insertText ? nil : dispatchText
                )

                self.scheduleOverlayHide(after: 2)
                self.micLevel = 0
                self.spectrum = Array(repeating: 0, count: 16)
                self.recordingState = .ready
                self.currentSession = nil
                mutex.release(.dictation)
                LogService.endSession()
            } catch {
                self.handlePipelineError(error)
            }
        }
    }

    /// Abort an in-flight recording without finalizing: a push-to-talk press
    /// shorter than the minimum useful duration, or the two-stage Esc cancel.
    /// Audio and text are discarded and state returns to `.ready`
    /// immediately. The mutex is released only after the session has
    /// drained (#9).
    private func abortRecording(reason: String) {
        guard recordingState == .recording, let session = currentSession, let mutex else { return }
        LogService.info("Aborting recording (\(reason))", category: "Recording")

        currentSession = nil
        durationTicker?.cancel()
        durationTicker = nil
        disarmEscCancel()
        confirmedSegments = []
        partialText = ""
        micLevel = 0
        spectrum = Array(repeating: 0, count: 16)
        isListeningSilence = false
        recordingState = .ready
        hideOverlay()

        Task { [session, mutex] in
            await session.abort()
            mutex.release(.dictation)
            await MainActor.run { LogService.endSession() }
        }
    }

    private func handlePipelineError(_ error: Error) {
        LogService.error("Recording error: \(error.localizedDescription)", category: "Recording")
        SentryService.capture(error: error)

        // Keep the failed session's audio on disk — it's the evidence for
        // "mic or engine?" (OpenSuperWhisper pattern).
        if let audioURL = SessionAudioRecorder.shared.endSession() {
            LogService.warn("Failed-session audio preserved: \(audioURL.path)", category: "Recording")
        }

        if let pipelineErr = error as? PipelineError {
            switch pipelineErr {
            case .sourceUnavailable:
                MicPermissionAlert.present()
            case .engineFailedFatally(let underlying):
                ToastWindowController.show("Engine error: \(underlying.localizedDescription)", style: .error, duration: 4)
            case .finalizeFailed(let underlying):
                ToastWindowController.show("Recognition failed: \(underlying.localizedDescription)", style: .warning, duration: 4)
            }
        } else {
            ToastWindowController.show("Recording error: \(error.localizedDescription)", style: .error, duration: 4)
        }

        recordingState = .ready
        durationTicker?.cancel()
        durationTicker = nil
        disarmEscCancel()
        // Release the mutex only once the session has drained (#9), so a new
        // session can't start while this one's pump still feeds the engine.
        let mutex = self.mutex
        if let session = currentSession {
            currentSession = nil
            Task {
                await session.abort()
                mutex?.release(.dictation)
            }
        } else {
            mutex?.release(.dictation)
        }
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

    // MARK: - Overlay

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

    // MARK: - OverlayWriter

    /// OverlayWriter conformance — called by OverlayProgressSink when the
    /// engine starts a new utterance (segment reset), so the previous partial
    /// becomes a confirmed segment instead of being overwritten.
    func appendConfirmedSegment(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        confirmedSegments.append(TranscriptionSegment(text: trimmed, emotion: nil))
        LogService.info("Segment promoted (count=\(confirmedSegments.count)): \"\(trimmed.prefix(40))\"", category: "Recording")
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
