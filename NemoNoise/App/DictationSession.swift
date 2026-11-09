import AppKit
import Foundation

/// One dictation recording: a cheap, per-session shell that owns the pipeline
/// instance, its timers, the ESC monitor, and the session audio file. Created
/// on hotkey down, discarded after `finish()`/`abort()` — the controller keeps
/// only UI state, so a finished session's callbacks can never touch a newer
/// one (they can only reach this object, which is about to be dropped).
@MainActor
final class DictationSession {
    enum Event {
        case partial(text: String, rms: Float, spectrum: [Float])
        case level(rms: Float, spectrum: [Float])
        case engineFallback(from: String)
    }

    let pipeline: TranscriptionPipeline
    let mode: RecordingMode

    var onEvent: (@MainActor (Event) -> Void)?
    /// 3 s with no recognized speech — the overlay's "Listening..." prompt.
    var onSpeechSilence: (@MainActor () -> Void)?
    var onMaxDurationReached: (@MainActor () -> Void)?
    /// ESC pressed in toggle mode — the controller runs the two-stage
    /// cancel (first press arms, second press stops).
    var onEscPressed: (@MainActor () -> Void)?
    var onPipelineError: (@MainActor (Error) -> Void)?

    /// Finished-session audio (set by `finish()`); nil after `abort()`.
    private(set) var audioFileURL: URL?
    /// Highest RMS this session — logged at finalize to tell "mic delivered
    /// silence" apart from "audio flowed but nothing was recognised".
    private(set) var maxMicLevel: Float = 0

    private(set) var startedAt: Date?
    private var eventTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var silenceTimer: Timer?
    /// Local ESC monitor — fallback only, when the global tap below failed
    /// to install (see `startEscMonitor`).
    private var escMonitor: Any?
    /// Global ESC tap (#3): the overlay never takes keyboard focus, so only a
    /// CGEvent tap sees ESC pressed inside the target app — and it consumes
    /// the key so the target app doesn't react to our cancel key.
    private let globalEscMonitor = GlobalEscMonitor()
    private let maxRecordingDuration: TimeInterval
    private let silenceThreshold: TimeInterval = 3.0

    init(pipeline: TranscriptionPipeline,
         mode: RecordingMode,
         maxDuration: TimeInterval = 120) {
        self.pipeline = pipeline
        self.mode = mode
        self.maxRecordingDuration = maxDuration
    }

    var duration: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// Speech activity observed (partial result) — re-arm the silence timer.
    func noteSpeechActivity() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onSpeechSilence?()
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        startedAt = Date()
        SessionAudioRecorder.shared.beginSession()
        startEscMonitor()

        durationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.duration >= self.maxRecordingDuration else { continue }
                self.onMaxDurationReached?()
                return
            }
        }

        eventTask = Task { [weak self, pipeline] in
            guard let self else { return }
            do {
                self.noteSpeechActivity()
                for try await event in pipeline.start() {
                    switch event {
                    case .partial(let result, let rms, let spectrum):
                        self.maxMicLevel = max(self.maxMicLevel, rms)
                        self.onEvent?(.partial(text: result.text, rms: rms, spectrum: spectrum))
                        self.noteSpeechActivity()
                    case .level(let rms, let spectrum):
                        self.maxMicLevel = max(self.maxMicLevel, rms)
                        self.onEvent?(.level(rms: rms, spectrum: spectrum))
                    case .engineFallback(let from):
                        self.onEvent?(.engineFallback(from: from))
                    case .final:
                        break
                    }
                }
            } catch {
                self.onPipelineError?(error)
            }
        }
    }

    /// End the session: drain tail audio, close the audio file, return the
    /// engine's final result. The event task finishes when the pipeline's
    /// stream closes inside `finalize()`.
    func finish() async throws -> TranscriptionResult {
        stopTimers()
        let result = try await pipeline.finalize()
        // After finalize: it stops the mic and drains its tail, so the file
        // gets the last words too. (On a throw, the error path keeps the
        // file via its own `endSession()`.)
        audioFileURL = SessionAudioRecorder.shared.endSession()
        await eventTask?.value
        return result
    }

    /// Abort without finalizing (push-to-talk press too short). Audio is
    /// discarded.
    func abort() async {
        stopTimers()
        SessionAudioRecorder.shared.discardSession()
        await pipeline.stop()
        await eventTask?.value
    }

    private func stopTimers() {
        durationTask?.cancel()
        durationTask = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        globalEscMonitor.stop()
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    /// ESC cancel in toggle mode. Exactly one delivery path is installed: the
    /// global tap when it can be created, otherwise the legacy local monitor.
    /// Installing both would double-fire a single physical press, which the
    /// two-stage cancel would collapse into an instant arm→stop.
    private func startEscMonitor() {
        guard mode == .toggle else { return }
        if globalEscMonitor.start { [weak self] in
            self?.onEscPressed?()
        } {
            return
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in
                self?.onEscPressed?()
            }
            return nil
        }
    }
}
