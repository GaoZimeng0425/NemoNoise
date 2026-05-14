import SwiftUI
import KeyboardShortcuts

@MainActor @Observable
final class TranslationController: SubtitleWriter {
    var translationState: TranslationState = .idle
    var englishText: String = ""
    var partialText: String = ""
    var chineseText: String = ""        // populated by SubtitleOverlayView post-translation
    var isTranslating: Bool = false
    var audioLevel: Float = 0

    let translationService: AppleTranslationService = AppleTranslationService()
    private var subtitleController: SubtitleOverlayController?
    private var pipelineTask: Task<Void, Never>?
    private weak var recordingController: RecordingController?
    private var pipeline: TranscriptionPipeline?

    private static let translationShortcut = KeyboardShortcuts.Name("translationMode")

    func setRecordingController(_ controller: RecordingController) {
        self.recordingController = controller
    }

    /// Called by NemoNoiseApp after both controllers and their pipelines are constructed.
    func bind(pipeline: TranscriptionPipeline) {
        self.pipeline = pipeline
    }

    var isActive: Bool { translationState != .idle }

    // MARK: - Toggle

    func toggle() {
        if isActive { stopTranslation() } else { startTranslation() }
    }

    private func startTranslation() {
        guard translationState == .idle, let pipeline else { return }
        if let rc = recordingController, rc.recordingState != .ready { return }

        guard CGPreflightScreenCaptureAccess() else {
            ScreenRecordingAlert.present()
            return
        }

        _ = LogService.startSession()
        LogService.info("Translation mode starting", category: "Translation")
        translationState = .capturing
        englishText = ""
        partialText = ""
        chineseText = ""
        showSubtitle()

        pipelineTask = Task { [weak self, pipeline] in
            guard let self else { return }
            do {
                for try await event in pipeline.start() {
                    switch event {
                    case .partial(_, let rms):
                        self.audioLevel = rms
                    case .rms(let level):
                        self.audioLevel = level
                    case .final, .engineFallback:
                        break
                    }
                    // partial/final text written by SubtitleOverlaySink
                }
            } catch {
                LogService.error("Translation pipeline error: \(error.localizedDescription)", category: "Translation")
                self.translationState = .error(error.localizedDescription)
                self.hideSubtitle()
                ToastWindowController.show("Audio capture stopped: \(error.localizedDescription)", style: .error)
            }
        }
    }

    func stopTranslation() {
        LogService.info("Translation mode stopping", category: "Translation")
        pipelineTask?.cancel()
        pipelineTask = nil
        Task { [pipeline] in
            _ = try? await pipeline?.finalize()
        }
        hideSubtitle()
        translationState = .idle
        LogService.endSession()
    }

    // MARK: - Hotkey

    private var hotkeyTask: Task<Void, Never>?

    func startHotkeyMonitoring() {
        hotkeyTask = Task { [weak self] in
            for await event in KeyboardShortcuts.events(for: Self.translationShortcut) {
                guard let self, event == .keyDown else { return }
                self.toggle()
            }
        }
    }

    // MARK: - Helper (kept for ShouldTranslateTests)

    func shouldTranslate(_ text: String) -> Bool {
        let chars = Array(text)
        let asciiCount = chars.filter { $0.isASCII && $0.isLetter }.count
        let totalLetters = chars.filter { $0.isLetter }.count
        guard totalLetters > 0 else { return false }
        return Double(asciiCount) / Double(totalLetters) > 0.5
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
