import XCTest
import os
@testable import NemoNoise

/// Shared sink test double: records every delivery for assertion.
final class RecordingSink: Sink, @unchecked Sendable {
    private(set) var delivered: [(text: String, isFinal: Bool)] = []
    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        delivered.append((result.text, isFinal))
    }
}

nonisolated final class TranscriptionPipelineTests: XCTestCase {

    @MainActor func testPipelineYieldsPartialOnChunkAndFinalOnFinalize() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        engine.feedChunkResultText = "partial-text"
        engine.finishResultText = "final-text"

        let sink = RecordingSink()
        let pipeline = TranscriptionPipeline(
            source: source,
            engine: engine,
            postProcessors: [],
            sink: sink,
            fallback: nil
        )

        let eventStream = pipeline.start()
        var collected: [PipelineEvent] = []

        let consumer = Task {
            do {
                for try await event in eventStream {
                    collected.append(event)
                    if case .final = event { break }
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        // Give the pipeline a moment to subscribe and call engine.reset + source.start.
        try await Task.sleep(for: .milliseconds(50))
        source.emit(samples: [0.1, 0.2, 0.3], rmsLevel: 0.5)
        try await Task.sleep(for: .milliseconds(50))

        let final = try await pipeline.finalize()
        XCTAssertEqual(final.text, "final-text")

        _ = await consumer.value

        // Assert we saw a partial event and then the final.
        XCTAssertTrue(collected.contains { event in
            if case .partial(let r, _, _) = event { return r.text == "partial-text" }
            return false
        })
        XCTAssertTrue(collected.contains { event in
            if case .final(let r) = event { return r.text == "final-text" }
            return false
        })
        XCTAssertEqual(engine.resetCallCount, 1)
        XCTAssertEqual(engine.feedChunkCallCount, 1)
        XCTAssertEqual(engine.finishCallCount, 1)
    }
}

extension TranscriptionPipelineTests {

    // MARK: - Engine fallback

    @MainActor func testFallbackEngineTakesOverWhenPrimaryThrows() async throws {
        let source = MockAudioSource()
        let primary = MockASREngine()
        primary.feedChunkShouldThrow = NSError(domain: "primary", code: 1)

        let fallback = MockASREngine()
        fallback.feedChunkResultText = "from-fallback"
        fallback.finishResultText = "final-from-fallback"

        let sink = RecordingSink()
        let pipeline = TranscriptionPipeline(
            source: source,
            engine: primary,
            sink: sink,
            fallback: fallback
        )

        let events = pipeline.start()
        var sawFallback = false
        var sawFallbackPartial = false

        let consumer = Task {
            for try await event in events {
                switch event {
                case .engineFallback: sawFallback = true
                case .partial(let r, _, _) where r.text == "from-fallback": sawFallbackPartial = true
                default: break
                }
                if sawFallbackPartial { break }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        // Primary throws on this chunk; pipeline switches to fallback.
        source.emit(samples: [0.1])
        // After switch, give the loop time, then emit another chunk that the fallback handles.
        try await Task.sleep(for: .milliseconds(50))
        source.emit(samples: [0.2])
        try await Task.sleep(for: .milliseconds(50))

        let finalResult = try await pipeline.finalize()
        _ = try? await consumer.value

        XCTAssertTrue(sawFallback, "expected engineFallback event")
        XCTAssertTrue(sawFallbackPartial, "expected partial from fallback engine")
        XCTAssertEqual(fallback.resetCallCount, 1)
        XCTAssertEqual(finalResult.text, "final-from-fallback", "finalize must call finish() on the fallback engine, not the failed primary")
    }

    // MARK: - No fallback → fatal

    @MainActor func testEngineFailureWithoutFallbackThrowsFatal() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        engine.feedChunkShouldThrow = NSError(domain: "engine", code: 42)

        let pipeline = TranscriptionPipeline(
            source: source,
            engine: engine,
            sink: RecordingSink(),
            fallback: nil
        )

        let events = pipeline.start()
        var caughtError: Error?
        let consumer = Task {
            do {
                for try await _ in events { /* drain */ }
            } catch {
                caughtError = error
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        source.emit(samples: [0.1])
        try await Task.sleep(for: .milliseconds(80))
        source.finishStream()
        _ = await consumer.value

        guard let pipelineErr = caughtError as? PipelineError else {
            return XCTFail("expected PipelineError, got \(String(describing: caughtError))")
        }
        if case .engineFailedFatally = pipelineErr {
            // OK
        } else {
            XCTFail("expected engineFailedFatally, got \(pipelineErr)")
        }
    }

    // MARK: - Reuse

    @MainActor func testPipelineCanBeStartedAgainAfterFinalize() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, sink: RecordingSink()
        )

        _ = pipeline.start()
        try await Task.sleep(for: .milliseconds(20))
        _ = try await pipeline.finalize()

        _ = pipeline.start()
        try await Task.sleep(for: .milliseconds(20))
        _ = try await pipeline.finalize()

        XCTAssertEqual(engine.resetCallCount, 2, "engine should reset on every start")
        XCTAssertEqual(source.startCalls, 2)
    }

    // MARK: - Stop without finalize

    @MainActor func testStopDoesNotCallFinish() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, sink: RecordingSink()
        )

        _ = pipeline.start()
        try await Task.sleep(for: .milliseconds(20))
        await pipeline.stop()

        XCTAssertEqual(engine.finishCallCount, 0)
        XCTAssertGreaterThanOrEqual(source.stopCalls, 1)
    }

    // MARK: - Mid-stream isFinal propagation

    @MainActor func testEngineMidStreamFinalYieldsFinalEvent() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        engine.feedChunkScript = [
            TranscriptionResult(text: "sentence one.", isFinal: true, emotion: nil)
        ]
        let sink = RecordingSink()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, postProcessors: [], sink: sink, fallback: nil
        )

        let events = pipeline.start()
        var collected: [PipelineEvent] = []
        let consumer = Task {
            for try await event in events {
                collected.append(event)
                if case .final = event { break }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        source.emit(samples: [0.1])
        try await Task.sleep(for: .milliseconds(50))
        source.finishStream()
        _ = try? await consumer.value
        await pipeline.stop()

        XCTAssertTrue(collected.contains { event in
            if case .final(let r) = event { return r.text == "sentence one." && r.isFinal }
            return false
        }, "engine's mid-stream isFinal=true must surface as PipelineEvent.final, got: \(collected)")
    }

    @MainActor func testEngineMidStreamFinalDeliveredToSinkWithIsFinalTrue() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        engine.feedChunkScript = [
            TranscriptionResult(text: "sentence one.", isFinal: true, emotion: nil)
        ]
        let sink = RecordingSink()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, postProcessors: [], sink: sink, fallback: nil
        )

        let events = pipeline.start()
        let consumer = Task {
            for try await event in events {
                if case .final = event { break }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        source.emit(samples: [0.1])
        try await Task.sleep(for: .milliseconds(60))
        source.finishStream()
        _ = try? await consumer.value
        await pipeline.stop()

        let finalDelivery = sink.delivered.first { $0.isFinal && $0.text == "sentence one." }
        XCTAssertNotNil(finalDelivery, "sink.deliver must be called with isFinal=true for the mid-stream final, got: \(sink.delivered)")
    }

    // MARK: - Consumer termination stops the source (#2c)

    /// Cancelling the consumer task (or dropping the event stream) must stop
    /// the audio source via `onTermination` — otherwise a re-bound controller
    /// leaves the old session's microphone running.
    @MainActor func testConsumerCancellationStopsSource() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, sink: RecordingSink()
        )

        let events = pipeline.start()
        let consumer = Task { for try await _ in events { /* drain */ } }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertGreaterThanOrEqual(source.stopCalls, 1,
                                    "onTermination must stop the audio source when the consumer goes away")
        await pipeline.stop()
    }

    /// Single-session instances: cancelling session N's consumer (a late
    /// `onTermination` from a finished session) must not affect session N+1 —
    /// which now runs on its OWN pipeline instance with its own source.
    @MainActor func testSeparateInstancesDoNotInterfere() async throws {
        let source1 = MockAudioSource()
        let pipeline1 = TranscriptionPipeline(
            source: source1, engine: MockASREngine(), sink: RecordingSink()
        )
        let events1 = pipeline1.start()
        let consumer1 = Task { for try await _ in events1 { /* drain */ } }
        try await Task.sleep(for: .milliseconds(50))
        consumer1.cancel()
        try await Task.sleep(for: .milliseconds(100))

        // Session 2 on a fresh instance — unaffected by session 1's teardown.
        let source2 = MockAudioSource()
        let sink2 = RecordingSink()
        let pipeline2 = TranscriptionPipeline(
            source: source2, engine: MockASREngine(), sink: sink2
        )
        let events2 = pipeline2.start()
        let consumer2 = Task { for try await _ in events2 { /* drain */ } }
        try await Task.sleep(for: .milliseconds(50))

        source2.emit(samples: [0.1])
        try await Task.sleep(for: .milliseconds(100))
        consumer2.cancel()
        await pipeline2.stop()

        XCTAssertGreaterThanOrEqual(source1.stopCalls, 1,
                                    "session 1's cancellation must stop its own source")
        XCTAssertTrue(sink2.delivered.contains { $0.text == "mock partial" },
                      "session 2 must still receive chunks after session 1's consumer was cancelled")
    }

    // MARK: - Stop drains the pump (#9)

    /// Thread-safe flag used by the drain test.
    final class LockedFlag: @unchecked Sendable {
        private let flag = OSAllocatedUnfairLock(initialState: false)
        func set() { flag.withLock { $0 = true } }
        var isSet: Bool { flag.withLock { $0 } }
    }

    /// `feedChunk` that blocks until the test opens a gate; ignores task
    /// cancellation so the pump genuinely stays mid-feed while stopped.
    final class GatedEngine: ASREngine, @unchecked Sendable {
        let isStreaming = true
        private let gateOpen = OSAllocatedUnfairLock(initialState: false)
        private let feedEnteredFlag = OSAllocatedUnfairLock(initialState: false)
        private let feedExitedFlag = OSAllocatedUnfairLock(initialState: false)
        var feedEntered: Bool { feedEnteredFlag.withLock { $0 } }
        var feedExited: Bool { feedExitedFlag.withLock { $0 } }
        func openGate() { gateOpen.withLock { $0 = true } }

        func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
            feedEnteredFlag.withLock { $0 = true }
            while !gateOpen.withLock({ $0 }) {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            feedExitedFlag.withLock { $0 = true }
            return TranscriptionResult(text: "gated partial", isFinal: false, emotion: nil)
        }

        func finish() async throws -> TranscriptionResult {
            TranscriptionResult(text: "", isFinal: true, emotion: nil)
        }
        func reset() {}
    }

    /// `stop()` must not return while the pump is still mid-`feedChunk` —
    /// otherwise a rapid stop→start cycle feeds stale chunks into the freshly
    /// reset engine.
    @MainActor func testStopWaitsForInFlightFeedToDrain() async throws {
        let source = MockAudioSource()
        let engine = GatedEngine()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, sink: RecordingSink()
        )

        let events = pipeline.start()
        let consumer = Task { for try await _ in events { /* drain */ } }
        try await Task.sleep(for: .milliseconds(50))
        source.emit(samples: [0.1])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(engine.feedEntered, "pump should be blocked inside feedChunk")

        let stopReturned = LockedFlag()
        let stopTask = Task {
            await pipeline.stop()
            stopReturned.set()
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(stopReturned.isSet,
                       "stop() must wait for the in-flight feedChunk to drain, not return early")
        XCTAssertFalse(engine.feedExited)

        engine.openGate()
        _ = await stopTask.value
        XCTAssertTrue(stopReturned.isSet)
        XCTAssertTrue(engine.feedExited, "the in-flight feed should have completed before stop() returned")
        consumer.cancel()
    }

    // MARK: - Source failure

    @MainActor func testSourceStartFailureSurfacesAsSourceUnavailable() async throws {
        let source = MockAudioSource()
        source.throwOnStart = NSError(domain: "mic-denied", code: 1)
        let engine = MockASREngine()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, sink: RecordingSink()
        )

        let events = pipeline.start()
        var caughtError: Error?
        do {
            for try await _ in events { }
        } catch {
            caughtError = error
        }

        guard let pipelineErr = caughtError as? PipelineError else {
            return XCTFail("expected PipelineError, got \(String(describing: caughtError))")
        }
        if case .sourceUnavailable = pipelineErr {
            // OK
        } else {
            XCTFail("expected sourceUnavailable, got \(pipelineErr)")
        }
    }

    // MARK: - Interruption: text preserved when stream ends before finalize

    /// Reproduces the audio-interruption flow at the pipeline level: the audio
    /// stream ends early (as it does when MicAudioSource stops its engine on a
    /// device change / stall), and `finalize()` is called afterwards. The
    /// already-recognized text must still be preserved — finalize must drain
    /// `engine.finish()` and must not hang.
    @MainActor func testFinalizeAfterEarlyStreamEndPreservesRecognizedText() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        engine.feedChunkResultText = "recognized so far"
        engine.finishResultText = "recognized so far final"

        let sink = RecordingSink()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, postProcessors: [], sink: sink, fallback: nil
        )

        let events = pipeline.start()
        let consumer = Task { for try await _ in events { /* drain */ } }

        try await Task.sleep(for: .milliseconds(50))
        source.emit(samples: [0.1])               // a partial is recognized + delivered
        try await Task.sleep(for: .milliseconds(50))

        // Simulate the interruption: the capture stream ends early, before finalize.
        source.finishStream()
        try await Task.sleep(for: .milliseconds(20))

        // finalize() runs the same path RecordingController.stopRecording uses.
        let final = try await pipeline.finalize()
        _ = try? await consumer.value

        XCTAssertEqual(final.text, "recognized so far final",
                       "finalize must drain engine.finish() even when the stream ended early")
        XCTAssertEqual(engine.finishCallCount, 1, "engine.finish() must be called exactly once")
        XCTAssertTrue(sink.delivered.contains { $0.text == "recognized so far" },
                      "streamed partial must have reached the sink before the early stop")
    }

    // MARK: - Translation pipeline force-segment integration

    /// `nonisolated`: its `read` closure is called from the pipeline's
    /// `@Sendable` clock, off the main actor.
    nonisolated final class TickingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _current: Date = Date(timeIntervalSinceReferenceDate: 0)
        func readNow() -> Date {
            lock.lock(); defer { lock.unlock() }
            return _current
        }
        var read: @Sendable () -> Date { { [weak self] in self?.readNow() ?? Date() } }
        func tick(_ s: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            _current = _current.addingTimeInterval(s)
        }
    }

    @MainActor
    func testTranslationPipelineForceSegmentsAfterHardLimit() async throws {
        let engine = MockASREngine()
        // Seven accumulating partials, none isFinal.
        engine.feedChunkScript = [
            TranscriptionResult(text: "the speaker",                                          isFinal: false, emotion: nil),
            TranscriptionResult(text: "the speaker is",                                       isFinal: false, emotion: nil),
            TranscriptionResult(text: "the speaker is saying",                                isFinal: false, emotion: nil),
            TranscriptionResult(text: "the speaker is saying many",                           isFinal: false, emotion: nil),
            TranscriptionResult(text: "the speaker is saying many things",                    isFinal: false, emotion: nil),
            TranscriptionResult(text: "the speaker is saying many things now",                isFinal: false, emotion: nil),
            TranscriptionResult(text: "the speaker is saying many things now and continuing", isFinal: false, emotion: nil),
        ]
        let clock = TickingClock()
        let segmenter = SentenceSegmenter(engine: engine, now: clock.read)

        let source = MockAudioSource()
        let writer = StubSubtitleWriter()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine,
            postProcessors: [segmenter],
            sink: SubtitleOverlaySink(target: writer),
            fallback: nil
        )

        let events = pipeline.start()
        let consumer = Task { for try await _ in events { /* drain */ } }

        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<7 {
            clock.tick(1.1)
            source.emit(samples: [0.1])
            try await Task.sleep(for: .milliseconds(20))
        }
        source.finishStream()
        _ = try? await pipeline.finalize()
        _ = try? await consumer.value

        XCTAssertFalse(writer.englishText.isEmpty,
                       "after 7 partials over >6s, hard-limit must have force-segmented at least once")
        XCTAssertGreaterThan(writer.displayedSeq, 0,
                             "displayedSeq must have advanced past initial -1")
    }
}
