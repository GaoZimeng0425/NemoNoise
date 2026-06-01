import Foundation
import Speech

struct EngineBuild: Sendable {
    let engine: any ASREngine
    let fallbackReason: String?
}

protocol ASREngineFactoring: Sendable {
    func makePrimary() throws -> EngineBuild
    func makeTranslation() throws -> EngineBuild
    func makeFallback() -> (any ASREngine)?
}

final class ASREngineFactory: ASREngineFactoring {
    private let modelManager: ModelManager

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    func makePrimary() throws -> EngineBuild {
        let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType) ?? AppDefaults.Defaults.engineType
        LogService.info("Factory creating engine: \(choice)", category: "ASREngineFactory")

        var fallbackReason: String?

        switch choice {
        case "sensevoice":
            if let dir = modelManager.modelPath(for: .senseVoice) {
                let engine = try SherpaASREngine(modelDir: dir)
                return EngineBuild(engine: engine, fallbackReason: nil)
            }
            LogService.warn("SenseVoice model not found, falling back to Apple", category: "ASREngineFactory")
            fallbackReason = "SenseVoice model not installed — using Apple Speech. Open Settings to download."
        case "paraformer":
            if let dir = modelManager.modelPath(for: .paraformer) {
                let engine = try ParaformerStreamingEngine(modelDir: dir)
                return EngineBuild(engine: engine, fallbackReason: nil)
            }
            LogService.warn("Paraformer model not found, falling back to Apple", category: "ASREngineFactory")
            fallbackReason = "Paraformer model not installed — using Apple Speech. Open Settings to download."
        case "qwen3":
            if let dir = modelManager.modelPath(for: .qwen3) {
                let engine = try Qwen3ASREngine(modelDir: dir)
                return EngineBuild(engine: engine, fallbackReason: nil)
            }
            LogService.warn("Qwen3 model not installed, falling back to Apple", category: "ASREngineFactory")
            fallbackReason = "Qwen3 model not installed — using Apple Speech. Open Settings to download."
        case "apple":
            break
        default:
            LogService.warn("Unknown engine choice '\(choice)', falling back to Apple", category: "ASREngineFactory")
        }

        let apple = try AppleSpeechASREngine()
        return EngineBuild(engine: apple, fallbackReason: fallbackReason)
    }

    func makeTranslation() throws -> EngineBuild {
        if let dir = modelManager.modelPath(for: .paraformer),
           let paraformer = try? ParaformerStreamingEngine(modelDir: dir) {
            LogService.info("Translation engine: Paraformer", category: "ASREngineFactory")
            return EngineBuild(engine: paraformer, fallbackReason: nil)
        }
        LogService.info("Translation engine: Apple Speech en-US", category: "ASREngineFactory")
        let apple = try AppleSpeechASREngine(locale: "en-US")
        return EngineBuild(engine: apple, fallbackReason: nil)
    }

    /// Build the fallback engine used by the dictation pipeline when the
    /// primary engine fails mid-recording. Returns nil unless the user has
    /// already authorized Apple Speech — otherwise an unexpected fallback
    /// would trigger the speech-recognition permission prompt mid-session
    /// even though the user never picked Apple Speech.
    func makeFallback() -> (any ASREngine)? {
        let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType) ?? AppDefaults.Defaults.engineType
        if choice == "apple" { return nil }  // primary is Apple, fallback redundant
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return nil }
        return try? AppleSpeechASREngine()
    }
}
