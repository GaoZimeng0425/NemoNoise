import Foundation

/// Events emitted by a running TranscriptionPipeline.
///
/// Consumers (controllers) subscribe via `pipeline.start()` and map these to
/// `@Observable` state changes for SwiftUI.
enum PipelineEvent: Sendable {
    /// An intermediate (partial) transcription update plus the current input
    /// level (RMS and frequency spectrum).
    case partial(TranscriptionResult, rms: Float, spectrum: [Float])

    /// Final transcription. Emitted from `finalize()`. The result has already
    /// been delivered to every sink before this event is yielded.
    case final(TranscriptionResult)

    /// Pipeline switched from primary engine to fallback mid-session.
    case engineFallback(from: String)

    /// Input-level update with no transcription text. Use for waveform UI when
    /// the engine produced no new text in this chunk.
    case level(rms: Float, spectrum: [Float])
}
