import SwiftUI
import AVFoundation

@Observable
final class RecordingController {
    var recordingState: RecordingState = .idle
    var confirmedSegments: [TranscriptionSegment] = []
    var partialText: String = ""
    var micLevel: Float = 0
    var lastError: String?
    var showCopyButton: Bool = false

    let modelManager = ModelManager()

    private let audioCapture = AudioCapture()
    private let textInjector = TextInjector()
    private let hotkeyMonitor = HotkeyMonitor()
    private var overlayController: OverlayWindowController?
    private var recordingTask: Task<Void, Never>?
    private var accumulatedSamples: [Float] = []
    private var engine: (any ASRService)?

    init() {
        hotkeyMonitor.onKeyDown = { [weak self] in
            Task { @MainActor [weak self] in self?.handleHotkeyDown() }
        }
        hotkeyMonitor.onKeyUp = { [weak self] in
            Task { @MainActor [weak self] in self?.handleHotkeyUp() }
        }
        hotkeyMonitor.start()
    }

    func handleHotkeyDown() {
        guard recordingState == .idle else { return }
        textInjector.captureTarget()
        startRecording()
    }

    func handleHotkeyUp() {
        guard recordingState == .recording else { return }
        stopRecording()
    }

    private func makeEngine() -> any ASRService {
        let choice = UserDefaults.standard.string(forKey: "engineType") ?? "apple"
        switch choice {
        case "sensevoice":
            if let dir = modelManager.modelPath(for: .senseVoice) {
                return SherpaASREngine(modelDir: dir)
            }
        case "paraformer":
            if let dir = modelManager.modelPath(for: .paraformer) {
                return ParaformerStreamingEngine(modelDir: dir)
            }
        default:
            break
        }
        return AppleSpeechASREngine()
    }

    private func startRecording() {
        recordingState = .recording
        confirmedSegments = []
        partialText = ""
        accumulatedSamples = []
        showCopyButton = false
        showOverlay()

        engine = makeEngine()
        engine?.reset()

        recordingTask = Task {
            do {
                let stream = try await audioCapture.start()

                for await chunk in stream {
                    guard recordingState == .recording else { break }
                    accumulatedSamples.append(contentsOf: chunk.samples)
                    micLevel = chunk.rmsLevel

                    if let result = try? await engine?.feedChunk(
                        chunk.samples,
                        sampleRate: 16000
                    ), !result.text.isEmpty {
                        partialText = result.text
                    }
                }
            } catch {
                print("[RecordingController] Audio error: \(error)")
                lastError = error.localizedDescription
                recordingState = .idle
                hideOverlay()
            }
        }
    }

    private func stopRecording() {
        recordingState = .processing
        audioCapture.stop()

        Task {
            defer {
                recordingState = .idle
                engine = nil
                if !showCopyButton { hideOverlay() }
            }
            do {
                guard !accumulatedSamples.isEmpty else { return }
                let result = try await engine?.finish()
                partialText = ""
                if let result, !result.text.isEmpty {
                    let segment = TranscriptionSegment(text: result.text, emotion: result.emotion)
                    confirmedSegments.append(segment)
                    await injectText(result.text)
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func injectText(_ text: String) async {
        let success = await textInjector.inject(text)
        if !success { showCopyButton = true }
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

    func copyToClipboard() {
        let text = confirmedSegments.map(\.text).joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopyButton = false
        hideOverlay()
    }
}
