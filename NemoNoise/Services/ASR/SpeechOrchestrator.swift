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
    
    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }
    
    func startTranscription() -> AsyncThrowingStream<OrchestratorResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let currentEngine = try makeEngine()
                    self.engine = currentEngine
                    currentEngine.reset()
                    
                    let audioStream = try await audioCapture.start()
                    
                    continuation.onTermination = { @Sendable _ in
                        Task { @MainActor in
                            self.stop()
                        }
                    }
                    
                    for await chunk in audioStream {
                        let result = try await currentEngine.feedChunk(chunk.samples, sampleRate: 16000)
                        
                        let orchestratorResult = OrchestratorResult(
                            text: result.text,
                            isFinal: result.isFinal,
                            emotion: result.emotion,
                            rmsLevel: chunk.rmsLevel
                        )
                        continuation.yield(orchestratorResult)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            
            // Handle early termination if needed
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
