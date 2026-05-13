import Foundation

final class SherpaPunctuation: @unchecked Sendable {
    private let punctuation: UnsafePointer<SherpaOnnxOfflinePunctuation>

    init?(modelPath: String) {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            LogService.error("Punctuation model not found: \(modelPath)", category: "SherpaPunctuation")
            return nil
        }

        var ptr: UnsafePointer<SherpaOnnxOfflinePunctuation>?

        modelPath.withCString { cModel in
            "cpu".withCString { cProvider in
                var modelConfig = SherpaOnnxOfflinePunctuationModelConfig()
                memset(&modelConfig, 0, MemoryLayout.size(ofValue: modelConfig))
                modelConfig.ct_transformer = cModel
                modelConfig.num_threads = 1
                modelConfig.provider = cProvider

                var config = SherpaOnnxOfflinePunctuationConfig()
                memset(&config, 0, MemoryLayout.size(ofValue: config))
                config.model = modelConfig

                ptr = SherpaOnnxCreateOfflinePunctuation(&config)
            }
        }

        guard let p = ptr else {
            LogService.error("Failed to create punctuation model", category: "SherpaPunctuation")
            return nil
        }
        punctuation = p
        LogService.info("Punctuation model loaded", category: "SherpaPunctuation")
    }

    func addPunctuation(to text: String) -> String {
        guard !text.isEmpty else { return text }
        let result = text.withCString { cText in
            SherpaOfflinePunctuationAddPunct(punctuation, cText)
        }
        guard let result else { return text }
        let output = String(cString: result)
        SherpaOfflinePunctuationFreeText(result)
        return output
    }

    deinit {
        SherpaOnnxDestroyOfflinePunctuation(punctuation)
    }
}
