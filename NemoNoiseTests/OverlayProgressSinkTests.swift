import XCTest
@testable import NemoNoise

@MainActor
final class StubOverlayTarget: OverlayWriter {
    var partialText: String = ""
}

@MainActor
final class OverlayProgressSinkTests: XCTestCase {
    func testPartialUpdatesPartialText() async {
        let target = StubOverlayTarget()
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "hi", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "hi")
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
}
