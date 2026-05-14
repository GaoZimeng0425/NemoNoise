import Foundation

/// A source of audio chunks at 16 kHz mono Float32. Implementations may
/// capture from microphone, system audio, file, etc.
protocol AudioSource: Sendable {
    /// Start producing chunks. Must `throw` if the underlying source cannot
    /// be opened (permission denied, no hardware).
    func start() async throws -> AsyncStream<AudioChunk>

    /// Stop producing. Idempotent; safe to call multiple times.
    func stop()
}
