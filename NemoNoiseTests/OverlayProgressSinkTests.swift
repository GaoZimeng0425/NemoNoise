import XCTest
@testable import NemoNoise

@MainActor
final class StubOverlayTarget: OverlayWriter {
    var partialText: String = ""
    var promotedSegments: [String] = []

    func appendConfirmedSegment(_ text: String) {
        promotedSegments.append(text)
    }
}

nonisolated final class OverlayProgressSinkTests: XCTestCase {
    @MainActor func testPartialUpdatesPartialText() async {
        let target = StubOverlayTarget()
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "hi", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "hi")
        XCTAssertEqual(target.promotedSegments, [])
    }

    @MainActor func testFinalPromotesSegmentAndClearsPartial() async {
        let target = StubOverlayTarget()
        target.partialText = "in-flight"
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "final", isFinal: true, emotion: nil), isFinal: true)
        XCTAssertEqual(target.promotedSegments, ["final"],
                       "isFinal is the segment boundary: its text becomes a confirmed segment")
        XCTAssertEqual(target.partialText, "",
                       "the finalized partial must not linger next to its confirmed segment")
    }

    @MainActor func testEmptyTextIgnored() async {
        let target = StubOverlayTarget()
        target.partialText = "kept"
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "kept")
    }

    @MainActor func testCumulativePartialDoesNotPromote() async {
        let target = StubOverlayTarget()
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "hello", isFinal: false, emotion: nil), isFinal: false)
        await sink.deliver(TranscriptionResult(text: "hello world", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "hello world")
        XCTAssertEqual(target.promotedSegments, [], "extending partial should NOT promote")
    }

    @MainActor func testNonExtendingPartialReplacesWithoutPromoting() async {
        let target = StubOverlayTarget()
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "hello world", isFinal: false, emotion: nil), isFinal: false)
        await sink.deliver(TranscriptionResult(text: "second sentence", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "second sentence")
        XCTAssertEqual(target.promotedSegments, [],
                       "segment boundaries come only from isFinal; inferring them from partials double-fired with isFinal (duplicate sentences)")
    }

    @MainActor func testMidStreamFinalCommitsOnceThenNextPartialStartsFresh() async {
        let target = StubOverlayTarget()
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "sentence one", isFinal: false, emotion: nil), isFinal: false)
        await sink.deliver(TranscriptionResult(text: "sentence one.", isFinal: true, emotion: nil), isFinal: true)
        await sink.deliver(TranscriptionResult(text: "sentence two", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.promotedSegments, ["sentence one."],
                       "each mid-stream final is committed exactly once")
        XCTAssertEqual(target.partialText, "sentence two")
    }
}
