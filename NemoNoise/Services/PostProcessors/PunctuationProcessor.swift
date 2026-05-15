import Foundation

/// PostProcessor that adds bilingual (zh+en) punctuation to final ASR text
/// using sherpa-onnx's CT-Transformer model. Partial results pass through —
/// running the model on every partial chunk is wasteful and the CT-Transformer
/// is trained for complete sentences.
final class PunctuationProcessor: PostProcessor {
    private let punctuator: SherpaOfflinePunctuator

    init(punctuator: SherpaOfflinePunctuator) {
        self.punctuator = punctuator
    }

    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        guard isFinal, !result.text.isEmpty else { return nil }
        let punctuated = punctuator.addPunctuation(to: result.text)
        return TranscriptionResult(text: punctuated, isFinal: true, emotion: result.emotion)
    }
}
