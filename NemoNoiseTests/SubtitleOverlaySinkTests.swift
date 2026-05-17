import XCTest
@testable import NemoNoise

@MainActor
final class StubSubtitleTarget: SubtitleWriter {
    var englishText: String = ""
    var partialText: String = ""
    var chineseText: String = ""
    var isTranslating: Bool = false
    var displayedSeq: Int = -1

    private(set) var applyTranslationCalls: [(seq: Int, chinese: String)] = []
    func applyTranslation(seq: Int, chinese: String) {
        applyTranslationCalls.append((seq, chinese))
        guard seq == displayedSeq else { return }
        chineseText = chinese
    }
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

    func testSeqTaggedFinalSetsEnglishAndDisplayedSeqAndClearsChinese() async {
        let target = StubSubtitleTarget()
        target.chineseText = "stale-chinese"   // simulates prior sentence's translation
        let sink = SubtitleOverlaySink(target: target)
        let result = TranscriptionResult(
            text: "Hello world.", isFinal: true, emotion: nil,
            originalText: nil, sequence: 7
        )
        await sink.deliver(result, isFinal: true)
        XCTAssertEqual(target.englishText, "Hello world.")
        XCTAssertEqual(target.partialText, "")
        XCTAssertEqual(target.chineseText, "", "chinese cleared so old translation does not linger")
        XCTAssertEqual(target.displayedSeq, 7)
    }

    func testSeqlessFinalKeepsLegacyBehavior() async {
        let target = StubSubtitleTarget()
        target.chineseText = "kept"
        let sink = SubtitleOverlaySink(target: target)
        let result = TranscriptionResult(
            text: "dictation final", isFinal: true, emotion: nil,
            originalText: nil, sequence: nil
        )
        await sink.deliver(result, isFinal: true)
        XCTAssertEqual(target.englishText, "dictation final")
        XCTAssertEqual(target.partialText, "")
        XCTAssertEqual(target.chineseText, "kept", "seq-less finals leave chinese untouched")
        XCTAssertEqual(target.displayedSeq, -1, "seq-less finals do not advance displayedSeq")
    }
}
