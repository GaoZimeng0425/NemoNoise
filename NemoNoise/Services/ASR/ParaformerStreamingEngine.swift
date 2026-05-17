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

    /// Pure helper to keep the endpoint-handling logic unit-testable without
    /// needing the underlying ONNX recognizer to be loaded.
    static func buildResult(rawText: String, isEndpoint: Bool) -> TranscriptionResult {
        if isEndpoint {
            let text = rawText.isEmpty ? "" : rawText + "。"
            return TranscriptionResult(text: text, isFinal: true, emotion: nil)
        }
        return TranscriptionResult(text: rawText, isFinal: false, emotion: nil)
    }
}
