import AppKit
import SwiftUI

/// Third mode of the app: meeting recording. Owns TWO pipelines — mic ("Me")
/// and system audio ("Them") — writing into one `MeetingTranscriptStore`
/// through two track-labeled `MeetingSink`s. Physical track separation stands
/// in for speaker diarization: whoever is on this Mac's mic is Me, whoever is
/// in the system audio (the call) is Them.
///
/// Like the other modes, exclusion is enforced by `RecordingMutex`; sessions
/// have no duration cap (unlike dictation's 120 s) because meetings run long.
@MainActor @Observable
final class MeetingController: MeetingWriter {
    enum State: Equatable {
        case idle
        case recording
        case finishing
    }

    // MARK: - UI state (observed by SwiftUI)

    var meetingState: State = .idle
    var meetingLines: [MeetingLine] = []
    var meetingPartialMe: String = ""
    var meetingPartialThem: String = ""
    var meetingDuration: TimeInterval = 0
    var meEngineLabel: String = ""
    var themEngineLabel: String = ""
    var meLevel: Float = 0
    var themLevel: Float = 0
    /// Per-track live spectrums for the panel's waveforms (16 bins, same
    /// contract as the dictation overlay).
    var meSpectrum: [Float] = Array(repeating: 0, count: 16)
    var themSpectrum: [Float] = Array(repeating: 0, count: 16)

    var isActive: Bool { meetingState != .idle }

    var durationText: String {
        let seconds = Int(meetingDuration)
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Dependencies

    /// Per-session store indirection: the per-meeting pipeline sinks append
    /// through this box; the controller swaps the store each meeting.
    let storeBox = MeetingStoreBox()

    /// Builds fresh per-meeting pipelines around the provider's resident
    /// engines. Installed by PipelineProvider; nil until engines are built.
    private var pipelineFactory: (() -> (mic: TranscriptionPipeline, system: TranscriptionPipeline)?)?
    private var micPipeline: TranscriptionPipeline?
    private var systemPipeline: TranscriptionPipeline?
    private var mutex: RecordingMutex?
    private var micTask: Task<Void, Never>?
    private var systemTask: Task<Void, Never>?
    private var store: MeetingTranscriptStore?
    private var panelController: MeetingPanelController?
    private var fullTranscriptWindow: FullTranscriptWindowController?

    /// Opens (or brings to front) the full-meeting transcript window.
    func showFullTranscript() {
        if fullTranscriptWindow == nil {
            fullTranscriptWindow = FullTranscriptWindowController()
        }
        fullTranscriptWindow?.show(controller: self)
    }
    private var timerTask: Task<Void, Never>?
    private var meTrackAlive = false
    private var themTrackAlive = false
    /// Single-flight auto-start after a first click found engines unbuilt:
    /// polls readiness briefly and starts the meeting the moment they bind,
    /// instead of making the user click again.
    private var autoStartTask: Task<Void, Never>?

    /// Installed by PipelineProvider: builds the meeting engines on first
    /// use (lazy, so engine memory is only paid when a meeting actually runs).
    var preparePipelines: (@MainActor () -> Void)?

    // MARK: - Bind + toggle

    func bind(pipelineFactory: @escaping () -> (mic: TranscriptionPipeline, system: TranscriptionPipeline)?,
              mutex: RecordingMutex,
              meEngineLabel: String,
              themEngineLabel: String) {
        self.pipelineFactory = pipelineFactory
        self.mutex = mutex
        self.meEngineLabel = meEngineLabel
        self.themEngineLabel = themEngineLabel
    }

    var pipelinesReady: Bool { pipelineFactory != nil }

    /// The provider dropped the meeting engines (memory pressure): the next
    /// start goes back through `preparePipelines` instead of getting nil from
    /// a stale factory and silently doing nothing.
    func unbind() {
        pipelineFactory = nil
    }

    func toggle() {
        if isActive {
            stopMeeting()
        } else {
            startMeeting()
        }
    }

    // MARK: - Lifecycle

    func startMeeting() {
        guard meetingState == .idle else { return }

        guard pipelinesReady else {
            // First meeting (heavy local models): engines build in the
            // background; start automatically the moment they bind — the
            // user should not have to click twice.
            preparePipelines?()
            guard autoStartTask == nil else { return }
            ToastWindowController.show("Preparing meeting engines…", style: .info, duration: 2)
            autoStartTask = Task { [weak self] in
                // ~10 s max; readiness flips in ~1 s for Apple, longer for
                // local models loading off disk.
                for _ in 0..<100 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self else { return }
                    if self.meetingState != .idle { break }
                    if self.pipelinesReady {
                        self.autoStartTask = nil
                        self.startMeeting()
                        return
                    }
                }
                self?.autoStartTask = nil
            }
            return
        }
        guard let mutex, let pipelines = pipelineFactory?() else { return }
        micPipeline = pipelines.mic
        systemPipeline = pipelines.system

        switch MicrophonePermission.preflight() {
        case .ready:
            break
        case .needsPrompt:
            Task { @MainActor in
                if await MicrophonePermission.prompt() {
                    self.startMeeting()
                } else {
                    MicPermissionAlert.present()
                }
            }
            return
        case .denied:
            MicPermissionAlert.present()
            return
        }

        guard mutex.tryAcquire(.meeting) else {
            ToastWindowController.show("Audio is in use by another mode", style: .info, duration: 2)
            return
        }

        // Trigger the audio-only "System Audio Recording" consent once, before
        // capture begins (the tap source falls back to ScreenCaptureKit if the
        // tap can't be created, so this is a best-effort prompt).
        ProcessTapAudioSource.fireAuthorizationPrompt()

        guard let store = MeetingTranscriptStore() else {
            mutex.release(.meeting)
            ToastWindowController.show("Could not create meeting transcript file", style: .error)
            return
        }

        _ = LogService.startSession()
        LogService.info("Meeting starting (Me=\(meEngineLabel), Them=\(themEngineLabel))", category: "Meeting")
        self.store = store
        storeBox.current = store
        meetingLines = []
        meetingPartialMe = ""
        meetingPartialThem = ""
        meetingDuration = 0
        meSpectrum = Array(repeating: 0, count: 16)
        themSpectrum = Array(repeating: 0, count: 16)
        meTrackAlive = true
        themTrackAlive = true
        meetingState = .recording
        showPanel()
        startTimer()

        micTask = Task { [weak self, micPipeline] in
            guard let self, let micPipeline else { return }
            do {
                for try await event in micPipeline.start() {
                    self.handleTrackEvent(.me, event)
                }
            } catch {
                self.handleTrackFailure(.me, error)
            }
        }
        systemTask = Task { [weak self, systemPipeline] in
            guard let self, let systemPipeline else { return }
            do {
                for try await event in systemPipeline.start() {
                    self.handleTrackEvent(.them, event)
                }
            } catch {
                self.handleTrackFailure(.them, error)
            }
        }
    }

    func stopMeeting() {
        guard meetingState == .recording, let mutex else { return }
        LogService.info("Meeting stopping, duration \(durationText)", category: "Meeting")

        meetingState = .finishing
        micTask?.cancel()
        micTask = nil
        systemTask?.cancel()
        systemTask = nil
        stopTimer()
        let store = self.store
        self.store = nil

        Task { [weak self, micPipeline, systemPipeline, mutex, store] in
            // Drain both pipelines; transcript text written by their sinks
            // (including the final deliveries) must land before the export.
            _ = try? await micPipeline?.finalize()
            _ = try? await systemPipeline?.finalize()

            let url = store?.exportMarkdown()
            await MainActor.run { [weak self] in
                // Finalize drained the sinks' last deliveries; safe to detach
                // the session store now. Mutex release must not depend on
                // `self` still being alive.
                self?.storeBox.current = nil
                guard let self else {
                    mutex.release(.meeting)
                    return
                }
                self.meetingState = .idle
                self.meetingPartialMe = ""
                self.meetingPartialThem = ""
                self.micPipeline = nil
                self.systemPipeline = nil
                self.fullTranscriptWindow?.close()
                mutex.release(.meeting)
                LogService.endSession()
                self.hidePanel()
                if let url {
                    ToastWindowController.show("Meeting saved", style: .success)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    ToastWindowController.show("Meeting stopped (transcript export failed)", style: .warning)
                }
            }
        }
    }

    // MARK: - Track events

    private func handleTrackEvent(_ track: MeetingLine.Track, _ event: PipelineEvent) {
        // Text arrives through MeetingSink; events carry level + spectrum for
        // the panel's live waveforms. `.level` (no recognized text — silence,
        // or non-speech audio) carries the same metering and is the MORE
        // common case, so both shapes update the meters.
        switch event {
        case .partial(_, rms: let rms, spectrum: let spectrum),
             .level(rms: let rms, spectrum: let spectrum):
            if track == .me {
                meLevel = rms
                meSpectrum = spectrum
            } else {
                themLevel = rms
                themSpectrum = spectrum
            }
        case .final, .engineFallback:
            return
        }
    }

    /// One track's pipeline died mid-meeting (engine or capture failure). The
    /// other track keeps recording; when both are dead the meeting ends.
    private func handleTrackFailure(_ track: MeetingLine.Track, _ error: Error) {
        guard meetingState == .recording else { return }
        LogService.error("Meeting \(track.label) track failed: \(error.localizedDescription)", category: "Meeting")

        if track == .me {
            meTrackAlive = false
            meLevel = 0
            if let failed = micPipeline {
                Task { await failed.stop() }
            }
        } else {
            themTrackAlive = false
            themLevel = 0
            if let failed = systemPipeline {
                Task { await failed.stop() }
            }
        }

        if meTrackAlive || themTrackAlive {
            ToastWindowController.show("\(track.label) track stopped: \(error.localizedDescription)",
                                       style: .warning, duration: 4)
        } else {
            ToastWindowController.show("Both tracks failed — ending meeting", style: .error, duration: 4)
            stopMeeting()
        }
    }

    /// Called (on the main actor) when the mic source reports a mid-meeting
    /// interruption (device change / stall): finalize what we have and stop.
    func handleMicInterruption(_ reason: AudioInterruptionReason) {
        guard meetingState == .recording else { return }
        let message = reason == .deviceConfigurationChanged
            ? "输入设备已变化，会议已停止"
            : "未检测到音频输入，会议已停止"
        LogService.warn("Meeting mic interruption (\(reason)) — finalizing session", category: "Meeting")
        ToastWindowController.show(message, style: .warning, duration: 4)
        stopMeeting()
    }

    // MARK: - Panel + timer

    private func showPanel() {
        if panelController == nil {
            panelController = MeetingPanelController(controller: self)
        }
        panelController?.show()
    }

    private func hidePanel() {
        panelController?.hide()
    }

    private func startTimer() {
        meetingDuration = 0
        let start = Date()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.meetingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
