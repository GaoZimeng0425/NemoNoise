import Foundation

/// Offline ASR engine backed by sherpa-onnx Qwen3-ASR-0.6B. Like SenseVoice,
/// this engine accumulates audio for the whole session and decodes once on
/// `finish()`. Decoding is LLM-style and not real-time — the user releases
/// the hotkey and waits for the result.
final class Qwen3ASREngine: ASREngine, @unchecked Sendable {
    private let recognizer: SherpaQwen3Recognizer
    private var accumulated: [Float] = []

    let isStreaming = false
    // Qwen3-ASR is an LLM-decoder model that emits punctuation itself; running
    // the CT-Transformer on top would double/corrupt it (`。。`, `？？`).
    let emitsPunctuation = true

    init(modelDir: URL) throws {
        let convFrontend = modelDir.appendingPathComponent("conv_frontend.onnx").path
        let encoder      = modelDir.appendingPathComponent("encoder.int8.onnx").path
        let decoder      = modelDir.appendingPathComponent("decoder.int8.onnx").path
        let tokenizer    = modelDir.appendingPathComponent("tokenizer").path

        let start = ContinuousClock.now
        guard let r = SherpaQwen3Recognizer(
            convFrontendPath: convFrontend,
            encoderPath: encoder,
            decoderPath: decoder,
            tokenizerDir: tokenizer,
            hotwords: UserLexicon.biasStrings()
        ) else {
            LogService.error("Qwen3-ASR init failed in \(modelDir.path)", category: "ASR")
            throw ASRError.engineInitFailed
        }
        recognizer = r
        LogService.info("Qwen3-ASR loaded, init duration: \((ContinuousClock.now - start).description)", category: "Qwen3ASREngine")
    }

    /// Qwen3 is non-streaming: just accumulate, yield empty partials.
    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        accumulated.append(contentsOf: samples)
        return TranscriptionResult(text: "", isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        defer { reset() }
        guard !accumulated.isEmpty else {
            return TranscriptionResult(text: "", isFinal: true, emotion: nil)
        }

        let snapshot = accumulated
        let text = await Task.detached { [recognizer] in
            recognizer.decode(samples: snapshot, sampleRate: 16000)
        }.value

        return TranscriptionResult(text: text, isFinal: true, emotion: nil)
    }

    func reset() {
        accumulated.removeAll(keepingCapacity: true)
    }
}
