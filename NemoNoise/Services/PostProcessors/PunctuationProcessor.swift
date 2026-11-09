import Foundation

/// PostProcessor that adds bilingual (zh+en) punctuation to final ASR text
/// using sherpa-onnx's CT-Transformer model. Partial results pass through —
/// running the model on every partial chunk is wasteful and the CT-Transformer
/// is trained for complete sentences.
/// `nonisolated` + detached inference (#6): the CT-Transformer run used to
/// execute on the main actor (default isolation hop from the pump task),
/// stalling the UI during punctuation inference.
nonisolated final class PunctuationProcessor: PostProcessor {
    private let punctuator: SherpaOfflinePunctuator

    init(punctuator: SherpaOfflinePunctuator) {
        self.punctuator = punctuator
    }

    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        guard isFinal, !result.text.isEmpty else { return nil }
        let source = result.text
        let punctuated = await Task.detached { [punctuator] in
            punctuator.addPunctuation(to: source)
        }.value
        return TranscriptionResult(text: punctuated, isFinal: true, emotion: result.emotion, sequence: result.sequence)
    }
}
