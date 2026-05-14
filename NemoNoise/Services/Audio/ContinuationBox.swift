import Foundation
import os

/// Sendable wrapper around `AsyncStream<AudioChunk>.Continuation` for crossing
/// isolation boundaries (audio tap callbacks run off-actor).
final class ContinuationBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<AsyncStream<AudioChunk>.Continuation?>(initialState: nil)
    var value: AsyncStream<AudioChunk>.Continuation? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
