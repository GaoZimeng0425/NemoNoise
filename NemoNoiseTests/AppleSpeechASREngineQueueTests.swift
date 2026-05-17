import XCTest
@testable import NemoNoise

final class AppleSpeechFinalQueueTests: XCTestCase {

    func testPopReturnsNilWhenEmpty() {
        var queue = AppleSpeechFinalQueue()
        XCTAssertNil(queue.popNext())
    }

    func testEnqueueThenPopReturnsFIFO() {
        var queue = AppleSpeechFinalQueue()
        queue.enqueue(TranscriptionResult(text: "first.", isFinal: true, emotion: nil))
        queue.enqueue(TranscriptionResult(text: "second.", isFinal: true, emotion: nil))
        XCTAssertEqual(queue.popNext()?.text, "first.")
        XCTAssertEqual(queue.popNext()?.text, "second.")
        XCTAssertNil(queue.popNext())
    }

    func testDrainConcatenatesAllPending() {
        var queue = AppleSpeechFinalQueue()
        queue.enqueue(TranscriptionResult(text: "first.", isFinal: true, emotion: nil))
        queue.enqueue(TranscriptionResult(text: "second.", isFinal: true, emotion: nil))
        queue.enqueue(TranscriptionResult(text: "third.", isFinal: true, emotion: nil))
        let drained = queue.drainConcatenated()
        XCTAssertEqual(drained?.text, "first. second. third.")
        XCTAssertTrue(drained?.isFinal == true)
        XCTAssertNil(queue.popNext(), "queue must be empty after drain")
    }

    func testDrainReturnsNilWhenEmpty() {
        var queue = AppleSpeechFinalQueue()
        XCTAssertNil(queue.drainConcatenated())
    }

    func testDrainOfSingleEntryReturnsItVerbatim() {
        var queue = AppleSpeechFinalQueue()
        queue.enqueue(TranscriptionResult(text: "only.", isFinal: true, emotion: "joy"))
        let drained = queue.drainConcatenated()
        XCTAssertEqual(drained?.text, "only.")
        XCTAssertEqual(drained?.emotion, "joy")
    }
}
