import XCTest
@testable import NemoNoise

@MainActor
final class TranscriptionPipelineTests: XCTestCase {

    func testPipelineYieldsPartialOnChunkAndFinalOnFinalize() async throws {
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

    func testFallbackEngineTakesOverWhenPrimaryThrows() async throws {
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

    func testEngineFailureWithoutFallbackThrowsFatal() async throws {
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

    func testPipelineCanBeStartedAgainAfterFinalize() async throws {
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

    func testStopDoesNotCallFinish() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, sink: RecordingSink()
        )

        _ = pipeline.start()
        try await Task.sleep(for: .milliseconds(20))
        pipeline.stop()

        XCTAssertEqual(engine.finishCallCount, 0)
        XCTAssertGreaterThanOrEqual(source.stopCalls, 1)
    }

    // MARK: - Mid-stream isFinal propagation

    func testEngineMidStreamFinalYieldsFinalEvent() async throws {
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
        pipeline.stop()

        XCTAssertTrue(collected.contains { event in
            if case .final(let r) = event { return r.text == "sentence one." && r.isFinal }
            return false
        }, "engine's mid-stream isFinal=true must surface as PipelineEvent.final, got: \(collected)")
    }

    func testEngineMidStreamFinalDeliveredToSinkWithIsFinalTrue() async throws {
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
        pipeline.stop()

        let finalDelivery = sink.delivered.first { $0.isFinal && $0.text == "sentence one." }
        XCTAssertNotNil(finalDelivery, "sink.deliver must be called with isFinal=true for the mid-stream final, got: \(sink.delivered)")
    }

    // MARK: - Source failure

    func testSourceStartFailureSurfacesAsSourceUnavailable() async throws {
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
}
