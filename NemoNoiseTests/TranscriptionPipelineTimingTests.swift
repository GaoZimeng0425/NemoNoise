import XCTest
import os
@testable import NemoNoise

/// Every confirmed line carries when it was spoken, not when recognition got
/// round to it: the two meeting tracks have very different recognition delays
/// (streaming vs. a VAD segment held up to 30 s), so delivery time misorders
/// them and can't be compared across tracks (echo matching needs that).
nonisolated final class TranscriptionPipelineTimingTests: XCTestCase {

    /// 0.1 s of 16 kHz audio.
    private static let chunk = [Float](repeating: 0.1, count: 1600)

    nonisolated private final class CapturingSink: Sink, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[TranscriptionResult]>(initialState: [])
        var finals: [TranscriptionResult] { lock.withLock { $0 } }
        func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
            guard isFinal, !result.text.isEmpty else { return }
            lock.withLock { $0.append(result) }
        }
    }

    /// Rebuilds the result the way real post-processors do, dropping any
    /// field it doesn't know about.
    nonisolated private struct RebuildingProcessor: PostProcessor {
        func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
            guard !result.text.isEmpty else { return nil }
            return TranscriptionResult(text: result.text + "!", isFinal: result.isFinal, emotion: result.emotion)
        }
    }

    @MainActor private func run(
        engine: MockASREngine,
        chunks: Int,
        postProcessors: [any PostProcessor] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> CapturingSink {
        let source = MockAudioSource()
        let sink = CapturingSink()
        let pipeline = TranscriptionPipeline(source: source, engine: engine,
                                             postProcessors: postProcessors, sink: sink, now: now)
        let events = pipeline.start()
        let consumer = Task { for try await _ in events {} }
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<chunks { source.emit(samples: Self.chunk) }
        try await Task.sleep(for: .milliseconds(100))
        _ = try await pipeline.finalize()
        _ = try? await consumer.value
        return sink
    }

    private func partial(_ text: String) -> TranscriptionResult {
        TranscriptionResult(text: text, isFinal: false, emotion: nil)
    }
    private func final(_ text: String, audioStart: TimeInterval? = nil) -> TranscriptionResult {
        TranscriptionResult(text: text, isFinal: true, emotion: nil, audioStart: audioStart)
    }

    @MainActor func testFinalIsStampedWithStartOfItsFirstPartialChunk() async throws {
        let engine = MockASREngine()
        engine.finishResultText = ""
        engine.feedChunkScript = [partial(""), partial(""), partial("hel"), final("hello"),
                                  partial(""), partial("wor"), final("world")]
        let sink = try await run(engine: engine, chunks: 7)

        XCTAssertEqual(sink.finals.map(\.text), ["hello", "world"])
        XCTAssertEqual(sink.finals[0].audioStart ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(sink.finals[1].audioStart ?? -1, 0.5, accuracy: 1e-9)
    }

    @MainActor func testFinalWithoutPartialsStartsAtEndOfPreviousLine() async throws {
        let engine = MockASREngine()
        engine.finishResultText = ""
        engine.feedChunkScript = [partial("a"), final("a."), partial(""), final("b.")]
        let sink = try await run(engine: engine, chunks: 4)

        XCTAssertEqual(sink.finals.map(\.text), ["a.", "b."])
        XCTAssertEqual(sink.finals[1].audioStart ?? -1, 0.2, accuracy: 1e-9,
                       "no partial: the line can only have started after the previous one ended")
    }

    @MainActor func testEngineProvidedStartSurvivesPostProcessors() async throws {
        let engine = MockASREngine()
        engine.finishResultText = ""
        engine.feedChunkScript = [partial("x"), final("x", audioStart: 0.05)]
        let sink = try await run(engine: engine, chunks: 2, postProcessors: [RebuildingProcessor()])

        XCTAssertEqual(sink.finals.map(\.text), ["x!"])
        XCTAssertEqual(sink.finals[0].audioStart ?? -1, 0.05, accuracy: 1e-9)
    }

    @MainActor func testFinishResultIsStampedWithPendingUtteranceStart() async throws {
        let engine = MockASREngine()
        engine.finishResultText = "tail"
        engine.feedChunkScript = [partial(""), partial("ta")]
        let sink = try await run(engine: engine, chunks: 2)

        XCTAssertEqual(sink.finals.map(\.text), ["tail"])
        XCTAssertEqual(sink.finals[0].audioStart ?? -1, 0.1, accuracy: 1e-9)
    }

    @MainActor func testSpokenAtIsFirstAudioWallClockPlusAudioStart() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let engine = MockASREngine()
        engine.finishResultText = ""
        engine.feedChunkScript = [partial(""), partial("hi"), final("hi.")]
        let sink = try await run(engine: engine, chunks: 3, now: { t0 })

        // The first chunk arrives once captured, so audio began 0.1 s before
        // t0; the line started 0.1 s into the audio.
        let spokenAt = try XCTUnwrap(sink.finals.first?.spokenAt)
        XCTAssertEqual(spokenAt.timeIntervalSince(t0), -0.1 + 0.1, accuracy: 1e-9)
    }
}
