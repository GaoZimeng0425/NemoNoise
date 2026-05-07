import Foundation

final class ParaformerStreamingEngine: ASRService, @unchecked Sendable {
    private let recognizer: SherpaOnlineRecognizer

    init(modelDir: URL) throws {
        let encoderPath = modelDir.appendingPathComponent("model_quant.onnx").path
        let decoderPath = modelDir.appendingPathComponent("decoder_quant.onnx").path
        let tokensPath  = modelDir.appendingPathComponent("tokens.txt").path
        guard let r = SherpaOnlineRecognizer(
            encoderPath: encoderPath,
            decoderPath: decoderPath,
            tokensPath: tokensPath
        ) else {
            throw ASRError.engineInitFailed
        }
        recognizer = r
        print("[ParaformerStreamingEngine] Model loaded")
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        let text = recognizer.feed(samples: samples, sampleRate: Int32(sampleRate))
        return TranscriptionResult(text: text, isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        let text = recognizer.finalize()
        return TranscriptionResult(text: text, isFinal: true, emotion: nil)
    }

    func reset() {
        recognizer.startStream()
    }
}
