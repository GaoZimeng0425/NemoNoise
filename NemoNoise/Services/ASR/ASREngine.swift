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
    func markBoundary() {}
}
