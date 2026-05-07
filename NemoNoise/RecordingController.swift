import SwiftUI
import AVFoundation
import ApplicationServices

@MainActor @Observable
final class RecordingController {
    var recordingState: RecordingState = .idle
    var confirmedSegments: [TranscriptionSegment] = []
    var partialText: String = ""
    var micLevel: Float = 0
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

    var recordingMode: RecordingMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "recordingMode") ?? "pushToTalk"
            return RecordingMode(rawValue: raw) ?? .pushToTalk
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "recordingMode")
        }
    }

    let modelManager = ModelManager()

    private let audioCapture = AudioCapture()
    private let textInjector = TextInjector()
    let hotkeyMonitor = HotkeyMonitor()
    private var overlayController: OverlayWindowController?
    private var recordingTask: Task<Void, Never>?
    private var accumulatedSamples: [Float] = []
    private var engine: (any ASRService)?

    var hotkeyDisplayText: String {
        let keyName: String
        switch hotkeyMonitor.hotkeyOption {
        case .option: keyName = "⌥ Option"
        case .rightCommand: keyName = "Right ⌘"
        }
        switch recordingMode {
        case .pushToTalk:
            return "Hold **\(keyName)** to record"
        case .toggle:
            return "Press **\(keyName)** to start/stop"
        }
    }

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
        switch recordingMode {
        case .pushToTalk:
            guard recordingState == .idle else { return }
            textInjector.captureTarget()
            startRecording()
        case .toggle:
            switch recordingState {
            case .idle:
                textInjector.captureTarget()
                startRecording()
            case .recording:
                stopRecording()
            case .processing:
                break
            }
        }
    }

    func handleHotkeyUp() {
        switch recordingMode {
        case .pushToTalk:
            guard recordingState == .recording else { return }
            stopRecording()
        case .toggle:
            break
        }
    }

    private func makeEngine() throws -> any ASRService {
        let choice = UserDefaults.standard.string(forKey: "engineType") ?? "apple"
        switch choice {
        case "sensevoice":
            if let dir = modelManager.modelPath(for: .senseVoice) {
                return try SherpaASREngine(modelDir: dir)
            }
        case "paraformer":
            if let dir = modelManager.modelPath(for: .paraformer) {
                return try ParaformerStreamingEngine(modelDir: dir)
            }
        default:
            break
        }
        return try AppleSpeechASREngine()
    }

    private func startRecording() {
        guard recordingState == .idle else {
            print("[RecordingController] Ignoring startRecording — state is \(recordingState)")
            return
        }

        let newEngine: any ASRService
        do {
            newEngine = try makeEngine()
        } catch {
            errorMessage = "Failed to initialize engine: \(error.localizedDescription)"
            showErrorAlert = true
            return
        }

        recordingState = .recording
        confirmedSegments = []
        partialText = ""
        accumulatedSamples = []
        showCopyButton = false
        showOverlay()
        startTimer()
        recordingStartTime = Date()

        engine = newEngine
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
                        errorMessage = "ASR engine error: \(error.localizedDescription)"
                        showErrorAlert = true
                        recordingState = .idle
                        hideOverlay()
                        break
                    }

                    // Auto-checkpoint for long recordings (>120s)
                    if let startTime = recordingStartTime, Date().timeIntervalSince(startTime) > maxRecordingDuration {
                        do {
                            if let result = try await engine?.finish(), !result.text.isEmpty {
                                let segment = TranscriptionSegment(text: result.text, emotion: result.emotion)
                                confirmedSegments.append(segment)
                            }
                            accumulatedSamples.removeAll(keepingCapacity: true)
                            let nextEngine = try makeEngine()
                            nextEngine.reset()
                            engine = nextEngine
                            recordingStartTime = Date()
                        } catch {
                            errorMessage = "Recording checkpoint failed: \(error.localizedDescription)"
                            showErrorAlert = true
                            recordingState = .idle
                            hideOverlay()
                            break
                        }
                    }
                }
            } catch {
                errorMessage = "Audio error: \(error.localizedDescription)"
                showErrorAlert = true
                recordingState = .idle
                hideOverlay()
            }
        }
    }

    private func stopRecording() {
        recordingState = .processing
        audioCapture.stop()
        stopTimer()
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
                errorMessage = "Final transcription failed: \(error.localizedDescription)"
                showErrorAlert = true
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

    private func startTimer() {
        recordingDuration = 0
        let startTime = Date()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    func copyToClipboard() {
        let text = confirmedSegments.map(\.text).joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopyButton = false
        hideOverlay()
    }
}
