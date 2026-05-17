import Foundation

protocol ASREngine: AnyObject, Sendable {
    /// Whether this engine streams results in real time.
    var isStreaming: Bool { get }

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
    func markBoundary() {}
}
