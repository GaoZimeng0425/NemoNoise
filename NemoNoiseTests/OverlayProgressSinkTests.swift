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

@MainActor
final class OverlayProgressSinkTests: XCTestCase {
    func testPartialUpdatesPartialText() async {
        let target = StubOverlayTarget()
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "hi", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "hi")
        XCTAssertEqual(target.promotedSegments, [])
    }

    func testFinalDoesNotClearPartial() async {
        let target = StubOverlayTarget()
        target.partialText = "kept"
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "final", isFinal: true, emotion: nil), isFinal: true)
        XCTAssertEqual(target.partialText, "kept")
    }

    func testEmptyTextIgnored() async {
        let target = StubOverlayTarget()
        target.partialText = "kept"
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "kept")
    }

    func testCumulativePartialDoesNotPromote() async {
        let target = StubOverlayTarget()
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "hello", isFinal: false, emotion: nil), isFinal: false)
        await sink.deliver(TranscriptionResult(text: "hello world", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "hello world")
        XCTAssertEqual(target.promotedSegments, [], "extending partial should NOT promote")
    }

    func testSegmentResetPromotesPreviousPartial() async {
        let target = StubOverlayTarget()
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "hello world", isFinal: false, emotion: nil), isFinal: false)
        await sink.deliver(TranscriptionResult(text: "second sentence", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "second sentence")
        XCTAssertEqual(target.promotedSegments, ["hello world"], "non-extending new partial should promote the old one")
    }

    func testMidStreamFinalDoesNotMutateTargetState() async {
        let target = StubOverlayTarget()
        target.partialText = "in-flight partial"
        let sink = OverlayProgressSink(target: target)
        // Simulating the new pipeline behavior: a mid-stream isFinal=true delivery
        await sink.deliver(
            TranscriptionResult(text: "sentence one.", isFinal: true, emotion: nil),
            isFinal: true
        )
        XCTAssertEqual(target.partialText, "in-flight partial",
                       "partialText must be preserved across mid-stream finals")
        XCTAssertEqual(target.promotedSegments, [],
                       "mid-stream finals must NOT promote partial segments via the dictation sink")
    }
}
