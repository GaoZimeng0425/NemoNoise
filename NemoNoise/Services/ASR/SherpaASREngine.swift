import Foundation

final class SherpaASREngine: ASREngine, @unchecked Sendable {
    private let recognizer: SherpaOfflineRecognizer
    private var accumulated: [Float] = []
    private var lastDecodeCount: Int = 0

    let isStreaming = false
    // SenseVoice runs with use_itn=1 and emits its own punctuation, so the
    // CT-Transformer must not re-punctuate (it would double/corrupt marks).
    let emitsPunctuation = true

    init(modelDir: URL, language: String = LanguagePreference.current.sherpaCode) throws {
        let modelPath  = modelDir.appendingPathComponent("model.int8.onnx").path
        let tokensPath = modelDir.appendingPathComponent("tokens.txt").path
        let start = ContinuousClock.now
        guard let r = SherpaOfflineRecognizer(modelPath: modelPath, tokensPath: tokensPath, language: language) else {
            LogService.error("Model init failed, path: \(modelPath)", category: "ASR")
            throw ASRError.engineInitFailed
        }
        recognizer = r
        let elapsed = ContinuousClock.now - start
        LogService.info("Model loaded, language: \(language), init duration: \(elapsed.description)", category: "SherpaASREngine")
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        accumulated.append(contentsOf: samples)
        let newSamples = accumulated.count - lastDecodeCount
        guard newSamples >= 16000 else {
            return TranscriptionResult(text: "", isFinal: false, emotion: nil)
        }

        lastDecodeCount = accumulated.count
        let snapshot = accumulated
        let decodeStart = ContinuousClock.now

        let result = await Task.detached { [recognizer] in
            recognizer.decode(samples: snapshot, sampleRate: 16000)
        }.value

        let decodeElapsed = ContinuousClock.now - decodeStart
        LogService.debug("Decode: \(result.text.count) chars, duration: \(decodeElapsed.description), samples: \(snapshot.count)", category: "SherpaASREngine")

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
