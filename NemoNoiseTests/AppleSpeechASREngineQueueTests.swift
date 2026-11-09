import XCTest
@testable import NemoNoise

nonisolated final class AppleSpeechFinalQueueTests: XCTestCase {

    @MainActor func testPopReturnsNilWhenEmpty() {
        var queue = AppleSpeechFinalQueue()
        XCTAssertNil(queue.popNext())
    }

    @MainActor func testEnqueueThenPopReturnsFIFO() {
        var queue = AppleSpeechFinalQueue()
        queue.enqueue(TranscriptionResult(text: "first.", isFinal: true, emotion: nil))
        queue.enqueue(TranscriptionResult(text: "second.", isFinal: true, emotion: nil))
        XCTAssertEqual(queue.popNext()?.text, "first.")
        XCTAssertEqual(queue.popNext()?.text, "second.")
        XCTAssertNil(queue.popNext())
    }

    @MainActor func testDrainConcatenatesAllPending() {
        var queue = AppleSpeechFinalQueue()
        queue.enqueue(TranscriptionResult(text: "first.", isFinal: true, emotion: nil))
        queue.enqueue(TranscriptionResult(text: "second.", isFinal: true, emotion: nil))
        queue.enqueue(TranscriptionResult(text: "third.", isFinal: true, emotion: nil))
        let drained = queue.drainConcatenated()
        XCTAssertEqual(drained?.text, "first. second. third.")
        XCTAssertTrue(drained?.isFinal == true)
        XCTAssertNil(queue.popNext(), "queue must be empty after drain")
    }

    @MainActor func testDrainReturnsNilWhenEmpty() {
        var queue = AppleSpeechFinalQueue()
        XCTAssertNil(queue.drainConcatenated())
    }

    @MainActor func testDrainOfSingleEntryReturnsItVerbatim() {
        var queue = AppleSpeechFinalQueue()
        queue.enqueue(TranscriptionResult(text: "only.", isFinal: true, emotion: "joy"))
        let drained = queue.drainConcatenated()
        XCTAssertEqual(drained?.text, "only.")
        XCTAssertEqual(drained?.emotion, "joy")
    }
}
