import Foundation
@testable import NemoNoise

/// Test double that emits AudioChunks driven by the test.
final class MockAudioSource: AudioSource, @unchecked Sendable {
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    var throwOnStart: Error?

    func start() async throws -> AsyncStream<AudioChunk> {
        startCalls += 1
        if let err = throwOnStart { throw err }
        return AsyncStream<AudioChunk> { cont in
            self.continuation = cont
        }
    }

    func stop() {
        stopCalls += 1
        continuation?.finish()
        continuation = nil
    }

    /// Push a chunk to whoever's iterating.
    func emit(samples: [Float], rmsLevel: Float = 0.1) {
        continuation?.yield(AudioChunk(samples: samples, rmsLevel: rmsLevel))
    }

    /// End the stream without an error.
    func finishStream() {
        continuation?.finish()
    }
}
