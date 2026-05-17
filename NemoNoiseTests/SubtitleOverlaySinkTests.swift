import XCTest
@testable import NemoNoise

@MainActor
final class StubSubtitleTarget: SubtitleWriter {
    var englishText: String = ""
    var partialText: String = ""
    var chineseText: String = ""
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

    func testBilingualFinalSetsBothLanguages() async {
        let target = StubSubtitleTarget()
        target.partialText = "in-flight"
        let sink = SubtitleOverlaySink(target: target)
        let result = TranscriptionResult(
            text: "你好。",
            isFinal: true,
            emotion: nil,
            originalText: "Hello."
        )
        await sink.deliver(result, isFinal: true)
        XCTAssertEqual(target.englishText, "Hello.", "english must be the originalText")
        XCTAssertEqual(target.chineseText, "你好。", "chinese must be the translated text")
        XCTAssertEqual(target.partialText, "", "partial must be cleared on bilingual final")
    }

    func testUnTranslatedFinalLeavesChineseUntouched() async {
        let target = StubSubtitleTarget()
        target.chineseText = "stale-chinese"
        let sink = SubtitleOverlaySink(target: target)
        let result = TranscriptionResult(
            text: "Hello.",
            isFinal: true,
            emotion: nil,
            originalText: nil
        )
        await sink.deliver(result, isFinal: true)
        XCTAssertEqual(target.englishText, "Hello.")
        XCTAssertEqual(target.chineseText, "stale-chinese",
                       "translation-failed finals must not overwrite previously good chinese")
    }
}
