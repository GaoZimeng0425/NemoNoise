import Foundation

/// Single place to construct ASR engines. Reads `UserDefaults` for the user's
/// preferred engine and `Keychain` for API keys, with predictable fallback to
/// Apple Speech when models or keys are missing.
@MainActor
final class ASREngineFactory {
    private let modelManager: ModelManager

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    /// Build the engine the user has selected in Settings. Falls back to Apple
    /// Speech if the chosen engine's prerequisites (model files, API key) are
    /// not satisfied.
    func makeUserPreferred() throws -> any ASREngine {
        let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType) ?? AppDefaults.Defaults.engineType
        LogService.info("Factory creating engine: \(choice)", category: "ASREngineFactory")

        switch choice {
        case "sensevoice":
            if let dir = modelManager.modelPath(for: .senseVoice) {
                return try SherpaASREngine(modelDir: dir)
            }
            LogService.warn("SenseVoice model not found, falling back to Apple", category: "ASREngineFactory")
        case "paraformer":
            if let dir = modelManager.modelPath(for: .paraformer) {
                return try ParaformerStreamingEngine(modelDir: dir)
            }
            LogService.warn("Paraformer model not found, falling back to Apple", category: "ASREngineFactory")
        case "qwen3":
            if let dir = modelManager.modelPath(for: .qwen3) {
                return try Qwen3ASREngine(modelDir: dir)
            }
            LogService.warn("Qwen3 model not installed, falling back to Apple", category: "ASREngineFactory")
        case "cloud":
            if let apiKey = KeychainService.load(key: KeychainService.Keys.cloudAPIKey), !apiKey.isEmpty {
                return CloudASREngine(apiKey: apiKey)
            }
            LogService.warn("Cloud API key not set, falling back to Apple", category: "ASREngineFactory")
        case "apple":
            break
        default:
            LogService.warn("Unknown engine choice '\(choice)', falling back to Apple", category: "ASREngineFactory")
        }
        return try AppleSpeechASREngine()
    }

    /// Build the engine used by translation: Paraformer for bilingual, falling
    /// back to Apple Speech locked to en-US.
    func makeForTranslation() throws -> any ASREngine {
        if let dir = modelManager.modelPath(for: .paraformer),
           let paraformer = try? ParaformerStreamingEngine(modelDir: dir) {
            LogService.info("Translation engine: Paraformer", category: "ASREngineFactory")
            return paraformer
        }
        LogService.info("Translation engine: Apple Speech en-US", category: "ASREngineFactory")
        return try AppleSpeechASREngine(locale: "en-US")
    }

    /// Build the fallback engine used by the dictation pipeline when the
    /// primary engine fails mid-recording.
    func makeFallback() throws -> any ASREngine {
        try AppleSpeechASREngine()
    }
}
