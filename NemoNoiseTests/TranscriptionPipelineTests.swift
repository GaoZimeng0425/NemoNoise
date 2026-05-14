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
            if case .partial(let r, _) = event { return r.text == "partial-text" }
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
