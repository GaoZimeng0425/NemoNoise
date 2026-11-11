import Foundation

protocol ASREngine: AnyObject, Sendable {
    /// Whether this engine streams results in real time.
    var isStreaming: Bool { get }

    /// Whether this engine already emits punctuation in its output (e.g. an
    /// LLM-decoder ASR like Qwen3). When true, the pipeline must NOT run the
    /// CT-Transformer `PunctuationProcessor` on top — doing so re-predicts
    /// punctuation and collides with the engine's own, producing `。。` / `？？`.
    /// Default false: raw-token engines (Paraformer, SenseVoice) need punctuation added.
    var emitsPunctuation: Bool { get }

    /// Whether this engine commits its own sentences: each `isFinal` result
    /// from `feedChunk` is one finished utterance, and partials are a
    /// revisable hypothesis of the current utterance only (Apple
    /// SpeechAnalyzer). `SentenceSegmenter` must not cut such partials — the
    /// engine rewrites them, and its own final would repeat the cut text.
    /// Default false: the engine's partial is a growing prefix the pipeline
    /// may segment (Paraformer).
    var emitsSentenceFinals: Bool { get }

    /// Feed one audio chunk during recording. Returns a partial result (may be empty).
    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult

    /// Called when recording stops. Returns the final transcription.
    func finish() async throws -> TranscriptionResult

    /// Reset internal state before a new recording session.
    func reset()

    /// Hint that the pipeline has force-segmented the current utterance.
    /// Engines that maintain accumulated decoder state across chunks should
    /// reset that state without ending the stream. Default: no-op.
    func markBoundary()
}

extension ASREngine {
    var isStreaming: Bool { true }
    var emitsPunctuation: Bool { false }
    var emitsSentenceFinals: Bool { false }
    func markBoundary() {}
}

/// An offline engine whose decoder accepts per-decode bias text (Qwen3's
/// per-stream hotwords). `VADSegmentingEngine` uses it to hand each segment
/// the session's confirmed transcript so far — names then stay spelled the
/// same across segments — and to re-decode with a reduced bias when a
/// hallucination guard fires. Engines without a biasing channel (SenseVoice's
/// CTC decoder) simply don't conform.
protocol BiasableDecodeEngine: ASREngine {
    /// Bias text for the next decode cycle (reset → feed → finish). Consumed
    /// by that decode; nil restores the engine's built-in bias (lexicon terms).
    func setNextDecodeBias(_ bias: String?)
}
