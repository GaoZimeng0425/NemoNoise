import Foundation
import SwiftUI
import Combine

struct OrchestratorResult: Sendable {
    let text: String
    let isFinal: Bool
    let emotion: String?
    let rmsLevel: Float
}

@MainActor
final class SpeechOrchestrator {
    private let modelManager: ModelManager
    private let audioCapture = AudioCapture()
    private var engine: (any ASRService)?
    var onEngineFallback: ((String) -> Void)?

    var isStreaming: Bool {
        engine?.isStreaming ?? (UserDefaults.standard.string(forKey: "engineType") != "sensevoice")
    }

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    func startTranscription() -> AsyncThrowingStream<OrchestratorResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let initialEngine = try makeEngine()
                    self.engine = initialEngine
                    let originalEngineName = String(describing: type(of: initialEngine))
                    initialEngine.reset()

                    let audioStream = try await audioCapture.start()

                    continuation.onTermination = { @Sendable _ in
                        Task { @MainActor in
                            self.stop()
                        }
                    }

                    var hasFallenBack = false

                    for await chunk in audioStream {
                        guard let activeEngine = self.engine else { break }
                        do {
                            let result = try await activeEngine.feedChunk(chunk.samples, sampleRate: 16000)
                            continuation.yield(OrchestratorResult(
                                text: result.text,
                                isFinal: result.isFinal,
                                emotion: result.emotion,
                                rmsLevel: chunk.rmsLevel
                            ))
                        } catch where !hasFallenBack {
                            hasFallenBack = true
                            LogService.error("Engine \(originalEngineName) failed: \(error.localizedDescription)", category: "ASR")
                            LogService.info("Falling back to AppleSpeechASREngine", category: "ASR")

                            let fallbackEngine = try AppleSpeechASREngine()
                            fallbackEngine.reset()
                            self.engine = fallbackEngine
                            self.onEngineFallback?(originalEngineName)

                            continuation.yield(OrchestratorResult(
                                text: "", isFinal: false, emotion: nil, rmsLevel: chunk.rmsLevel
                            ))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    func finalize() async throws -> TranscriptionResult {
        guard let engine = engine else {
            return TranscriptionResult(text: "", isFinal: true, emotion: nil)
        }
        let result = try await engine.finish()
        stop()
        return result
    }
    
    func stop() {
        audioCapture.stop()
        engine = nil
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
}
