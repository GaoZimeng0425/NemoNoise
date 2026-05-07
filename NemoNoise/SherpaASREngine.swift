import Foundation

final class SherpaASREngine: ASRService, @unchecked Sendable {
    private let recognizer: SherpaOfflineRecognizer
    private var accumulated: [Float] = []
    private var lastDecodeCount: Int = 0

    init(modelDir: URL, language: String = LanguagePreference.current.sherpaCode) throws {
        let modelPath  = modelDir.appendingPathComponent("model.int8.onnx").path
        let tokensPath = modelDir.appendingPathComponent("tokens.txt").path
        guard let r = SherpaOfflineRecognizer(modelPath: modelPath, tokensPath: tokensPath, language: language) else {
            throw ASRError.engineInitFailed
        }
        recognizer = r
        print("[SherpaASREngine] Model loaded, language: \(language)")
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        accumulated.append(contentsOf: samples)
        let newSamples = accumulated.count - lastDecodeCount
        guard newSamples >= 16000 else {
            return TranscriptionResult(text: "", isFinal: false, emotion: nil)
        }

        lastDecodeCount = accumulated.count
        let snapshot = accumulated

        let result = await Task.detached { [recognizer] in
            recognizer.decode(samples: snapshot, sampleRate: 16000)
        }.value

        return TranscriptionResult(text: result.text, isFinal: false, emotion: emotionEmoji(result.emotion))
    }

    func finish() async throws -> TranscriptionResult {
        defer { reset() }
        guard !accumulated.isEmpty else {
            return TranscriptionResult(text: "", isFinal: true, emotion: nil)
        }

        let snapshot = accumulated
        let result = await Task.detached { [recognizer] in
            recognizer.decode(samples: snapshot, sampleRate: 16000)
        }.value

        return TranscriptionResult(text: result.text, isFinal: true, emotion: emotionEmoji(result.emotion))
    }

    func reset() {
        accumulated.removeAll(keepingCapacity: true)
        lastDecodeCount = 0
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
