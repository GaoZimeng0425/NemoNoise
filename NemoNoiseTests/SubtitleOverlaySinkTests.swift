import XCTest
@testable import NemoNoise

@MainActor
final class StubSubtitleTarget: SubtitleWriter {
    var englishText: String = ""
    var partialText: String = ""
}

@MainActor
final class SubtitleOverlaySinkTests: XCTestCase {
    func testPartialUpdatesPartialText() async {
        let target = StubSubtitleTarget()
        let sink = SubtitleOverlaySink(target: target)
        await sink.deliver(TranscriptionResult(text: "hello partial", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "hello partial")
        XCTAssertEqual(target.englishText, "")
    }

    func testFinalClearsPartialAndSetsEnglish() async {
        let target = StubSubtitleTarget()
        target.partialText = "stale"
        let sink = SubtitleOverlaySink(target: target)
        await sink.deliver(TranscriptionResult(text: "hello final", isFinal: true, emotion: nil), isFinal: true)
        XCTAssertEqual(target.englishText, "hello final")
        XCTAssertEqual(target.partialText, "")
    }

    func testEmptyTextIsIgnored() async {
        let target = StubSubtitleTarget()
        target.englishText = "kept"
        let sink = SubtitleOverlaySink(target: target)
        await sink.deliver(TranscriptionResult(text: "", isFinal: true, emotion: nil), isFinal: true)
        XCTAssertEqual(target.englishText, "kept")
    }
}
