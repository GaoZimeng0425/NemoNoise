import SwiftUI
import AVFoundation
import ApplicationServices

@Observable
final class RecordingController {
    var recordingState: RecordingState = .idle
    var confirmedSegments: [TranscriptionSegment] = []
    var partialText: String = ""
    var micLevel: Float = 0
    let recordingError = RecordingError()
    var showCopyButton: Bool = false
    var showErrorAlert: Bool = false
    var errorMessage: String = ""
    var showAccessibilityGuide: Bool = false
    var isListeningSilence: Bool = false
    private var silenceTimer: Timer?
    private let maxRecordingDuration: TimeInterval = 120
    private var recordingStartTime: Date?
    var recordingDuration: TimeInterval = 0
    private var timerTask: Task<Void, Never>?

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
        guard recordingState == .idle else {
            print("[RecordingController] Ignoring startRecording — state is \(recordingState)")
            return
        }
        recordingState = .recording
        confirmedSegments = []
        partialText = ""
        accumulatedSamples = []
        showCopyButton = false
        showOverlay()
        recordingStartTime = Date()

        engine = makeEngine()
        engine?.reset()

        recordingTask = Task {
            do {
                let stream = try await audioCapture.start()
                resetSilenceTimer()

                for await chunk in stream {
                    guard recordingState == .recording else { break }
                    accumulatedSamples.append(contentsOf: chunk.samples)
                    micLevel = chunk.rmsLevel

                    do {
                        let result = try await engine?.feedChunk(chunk.samples, sampleRate: 16000)
                        if let result, !result.text.isEmpty {
                            partialText = result.text
                            isListeningSilence = false
                            resetSilenceTimer()
                        }
                    } catch {
                        await MainActor.run {
                            errorMessage = "ASR engine error: \(error.localizedDescription)"
                            showErrorAlert = true
                            recordingState = .idle
                        }
                        hideOverlay()
                        break
                    }

                    // Auto-checkpoint for long recordings (>120s)
                    if let startTime = recordingStartTime, Date().timeIntervalSince(startTime) > maxRecordingDuration {
                        if let result = try? await engine?.finish(), !result.text.isEmpty {
                            let segment = TranscriptionSegment(text: result.text, emotion: result.emotion)
                            await MainActor.run { confirmedSegments.append(segment) }
                        }
                        engine = makeEngine()
                        engine?.reset()
                        recordingStartTime = Date()
                    }
                }
            } catch {
                print("[RecordingController] Audio error: \(error)")
                recordingError.error = error.localizedDescription
                recordingState = .idle
                hideOverlay()
            }
        }
    }

    private func stopRecording() {
        recordingState = .processing
        audioCapture.stop()
        invalidateSilenceTimer()

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
                recordingError.error = error.localizedDescription
            }
        }
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

    func copyToClipboard() {
        let text = confirmedSegments.map(\.text).joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopyButton = false
        hideOverlay()
    }
}
