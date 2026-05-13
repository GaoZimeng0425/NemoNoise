import SwiftUI
import ApplicationServices
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

    private static let translationShortcut = KeyboardShortcuts.Name("translationMode")

    func setRecordingController(_ controller: RecordingController) {
        self.recordingController = controller
    }

    var onTranslationActiveCheck: (() -> Bool)?

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

        // Mutual exclusion: don't start if dictation is active
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

    // MARK: - Hotkey Monitoring

    private var hotkeyTask: Task<Void, Never>?

    func startHotkeyMonitoring() {
        hotkeyTask = Task { [weak self] in
            for await event in KeyboardShortcuts.events(for: Self.translationShortcut) {
                guard let self, event == .keyDown else { return }
                self.toggle()
            }
        }
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
