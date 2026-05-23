import Foundation

final class ParaformerStreamingEngine: ASREngine, @unchecked Sendable {
    private let recognizer: SherpaOnlineRecognizer

    init(modelDir: URL) throws {
        let encoderPath = modelDir.appendingPathComponent("encoder.int8.onnx").path
        let decoderPath = modelDir.appendingPathComponent("decoder.int8.onnx").path
        let tokensPath  = modelDir.appendingPathComponent("tokens.txt").path
        let start = ContinuousClock.now
        guard let r = SherpaOnlineRecognizer(
            encoderPath: encoderPath,
            decoderPath: decoderPath,
            tokensPath: tokensPath
        ) else {
            LogService.error("Model init failed, encoder: \(encoderPath)", category: "ASR")
            throw ASRError.engineInitFailed
        }
        recognizer = r
        let elapsed = ContinuousClock.now - start
        LogService.info("Model loaded, init duration: \(elapsed.description)", category: "ParaformerStreamingEngine")
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        let text = recognizer.feed(samples: samples, sampleRate: Int32(sampleRate))
        let isEndpoint = recognizer.isEndpoint
        if isEndpoint {
            recognizer.resetStream()
        }
        return Self.buildResult(rawText: text, isEndpoint: isEndpoint)
    }

    func finish() async throws -> TranscriptionResult {
        let text = recognizer.finalize()
        return TranscriptionResult(text: text, isFinal: true, emotion: nil)
    }

    func reset() {
        recognizer.startStream()
    }

    func markBoundary() {
        recognizer.resetStream()
    }

    /// Pure helper. Engine emits recognition text only — punctuation is
    /// PunctuationProcessor's job downstream. Adding "。" here was the source
    /// of two bugs: duplicate punctuation (engine "。" + CT-Transformer "。")
    /// and intermittent last-char loss (CT-Transformer behaves unpredictably
    /// when fed pre-punctuated input, sometimes stripping a content token).
    static func buildResult(rawText: String, isEndpoint: Bool) -> TranscriptionResult {
        return TranscriptionResult(text: rawText, isFinal: isEndpoint, emotion: nil)
    }
}
