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
    private let factory: ASREngineFactory
    private let audioCapture = MicAudioSource()
    private var engine: (any ASREngine)?
    var onEngineFallback: ((String) -> Void)?

    var isStreaming: Bool {
        engine?.isStreaming ?? true
    }

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.factory = ASREngineFactory(modelManager: modelManager)
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
    
    private func makeEngine() throws -> any ASREngine {
        try factory.makeUserPreferred()
    }
}
