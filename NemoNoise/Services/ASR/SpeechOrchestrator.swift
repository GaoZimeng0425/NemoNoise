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
    private let audioCapture = MicAudioSource()
    private var engine: (any ASRService)?
    var onEngineFallback: ((String) -> Void)?

    var isStreaming: Bool {
        engine?.isStreaming ?? true
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
                            SentryService.capture(message: "Engine \(originalEngineName) failed, falling back: \(error.localizedDescription)")

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

        do {
            let result = try await engine.finish()
            stop()
            return result
        } catch let error as CloudASRError {
            stop()
            switch error {
            case .authenticationFailed:
                onEngineFallback?("CloudASREngine")
                throw error
            case .requestTimeout:
                LogService.warn("Cloud timeout, returning empty result", category: "ASR")
                onEngineFallback?("CloudASREngine")
                return TranscriptionResult(text: "", isFinal: true, emotion: nil)
            default:
                throw error
            }
        }
    }
    
    func stop() {
        audioCapture.stop()
        engine = nil
    }
    
    private func makeEngine() throws -> any ASRService {
        let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType) ?? AppDefaults.Defaults.engineType
        LogService.info("Creating engine: \(choice)", category: "ASR")
        switch choice {
        case "sensevoice":
            if let dir = modelManager.modelPath(for: .senseVoice) {
                do {
                    return try SherpaASREngine(modelDir: dir)
                } catch {
                    LogService.error("SherpaASREngine init failed: \(error.localizedDescription)", category: "ASR")
                    throw error
                }
            }
            LogService.warn("SenseVoice model not found, falling back to Apple", category: "ASR")
        case "paraformer":
            if let dir = modelManager.modelPath(for: .paraformer) {
                do {
                    return try ParaformerStreamingEngine(modelDir: dir)
                } catch {
                    LogService.error("ParaformerStreamingEngine init failed: \(error.localizedDescription)", category: "ASR")
                    throw error
                }
            }
            LogService.warn("Paraformer model not found, falling back to Apple", category: "ASR")
        case "cloud":
            if let apiKey = KeychainService.load(key: KeychainService.Keys.cloudAPIKey), !apiKey.isEmpty {
                return CloudASREngine(apiKey: apiKey)
            }
            LogService.warn("Cloud API key not set, falling back to Apple", category: "ASR")
        default:
            break
        }
        return try AppleSpeechASREngine()
    }
}
