import Foundation

final class SherpaASREngine: ASRService, @unchecked Sendable {
    private let recognizer: SherpaOfflineRecognizer
    private var accumulated: [Float] = []

    init(modelDir: URL) {
        let modelPath  = modelDir.appendingPathComponent("model.int8.onnx").path
        let tokensPath = modelDir.appendingPathComponent("tokens.txt").path
        guard let r = SherpaOfflineRecognizer(modelPath: modelPath, tokensPath: tokensPath) else {
            fatalError("[SherpaASREngine] Failed to load model from \(modelDir.path)")
        }
        recognizer = r
        print("[SherpaASREngine] Model loaded")
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        accumulated.append(contentsOf: samples)
        // Run a quick partial decode every ~1s of audio
        if accumulated.count >= 16000 {
            let result = recognizer.decode(samples: accumulated, sampleRate: Int32(sampleRate))
            return TranscriptionResult(text: result.text, isFinal: false, emotion: emotionEmoji(result.emotion))
        }
        return TranscriptionResult(text: "", isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        defer { accumulated.removeAll() }
        guard !accumulated.isEmpty else {
            return TranscriptionResult(text: "", isFinal: true, emotion: nil)
        }
        let result = recognizer.decode(samples: accumulated, sampleRate: 16000)
        return TranscriptionResult(text: result.text, isFinal: true, emotion: emotionEmoji(result.emotion))
    }

    func reset() {
        accumulated.removeAll()
    }

    private func emotionEmoji(_ emotion: String) -> String? {
        switch emotion.uppercased() {
        case "HAPPY":     return "😊"
        case "SAD":       return "😢"
        case "ANGRY":     return "😠"
        case "NEUTRAL":   return "😐"
        case "FEARFUL":   return "😨"
        case "DISGUSTED": return "🤢"
        case "SURPRISED": return "😮"
        default:          return nil
        }
    }
}
