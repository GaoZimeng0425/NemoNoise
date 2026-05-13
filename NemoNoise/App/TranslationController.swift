import SwiftUI
import ApplicationServices
import KeyboardShortcuts

@MainActor @Observable
final class TranslationController {
    var translationState: TranslationState = .idle
    var englishText: String = ""
    var partialText: String = ""
    var chineseText: String = ""
    var isTranslating: Bool = false
    var audioLevel: Float = 0

    let translationService: AppleTranslationService = AppleTranslationService()
    private var audioCapture: SystemAudioCapture?
    private var asrEngine: (any ASRService)?
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

        // Create ASR engine: Paraformer (bilingual) with Apple Speech fallback
        let engine: any ASRService
        if let modelManager = recordingController?.modelManager,
           let dir = modelManager.modelPath(for: .paraformer),
           let paraformer = try? ParaformerStreamingEngine(modelDir: dir) {
            paraformer.reset()
            engine = paraformer
            LogService.info("Using Paraformer for translation ASR", category: "Translation")
        } else {
            LogService.info("Paraformer unavailable, falling back to Apple Speech", category: "Translation")
            guard let apple = try? AppleSpeechASREngine(locale: "en-US") else {
                LogService.error("Failed to create any ASR engine", category: "Translation")
                translationState = .error("ASR engine unavailable")
                return
            }
            apple.reset()
            engine = apple
        }
        self.asrEngine = engine

        translationState = .capturing
        englishText = ""
        partialText = ""
        chineseText = ""
        showSubtitle()

        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = SystemAudioCapture()
                self.audioCapture = capture
                let audioStream = try await capture.start()
                LogService.info("Audio stream established, feeding chunks to ASR engine", category: "Translation")

                for await chunk in audioStream {
                    guard self.isActive else { break }
                    self.audioLevel = chunk.rmsLevel
                    do {
                        let result = try await engine.feedChunk(chunk.samples, sampleRate: 16000)
                        if !result.text.isEmpty {
                            if result.isFinal {
                                self.partialText = ""
                                self.englishText = result.text
                                LogService.info("ASR final: \(result.text.prefix(80))", category: "Translation")
                            } else {
                                self.partialText = result.text
                            }
                        }
                    } catch {
                        LogService.warn("ASR feedChunk error: \(error.localizedDescription)", category: "Translation")
                    }
                }
            } catch {
                LogService.error("System audio capture error: \(error.localizedDescription)", category: "Translation")
                self.translationState = .error(error.localizedDescription)
                self.hideSubtitle()
                ToastWindowController.show("Audio capture stopped: \(error.localizedDescription)", style: .error)
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

    // MARK: - Translation Helper

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
