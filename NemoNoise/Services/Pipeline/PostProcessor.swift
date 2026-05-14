import Foundation

/// Transforms a transcription result between the ASR engine and the sink.
///
/// Implementations decide based on `isFinal` whether to run at all — partial
/// results are noisy and many transforms (e.g. translation, LLM rewrite) only
/// make sense on final text. Return `nil` to pass through unchanged.
protocol PostProcessor: Sendable {
    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult?
}
