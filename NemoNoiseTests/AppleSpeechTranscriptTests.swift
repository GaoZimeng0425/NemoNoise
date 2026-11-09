import XCTest
@testable import NemoNoise

/// The SpeechAnalyzer results loop commits one utterance at a time (`isFinal`)
/// and refines the current one (volatile). The engine must surface each commit
/// as its own `isFinal` result — the segment boundary every sink relies on —
/// and report only the current utterance as the partial. Before this, the
/// engine merged everything into one growing partial and committed only at
/// `finish()`: a meeting's Me track became a single line written at stop.
nonisolated final class AppleSpeechTranscriptTests: XCTestCase {

    @MainActor func testVolatileOnlyReportsPartialOfCurrentUtterance() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "你好", isFinal: false)
        let result = transcript.takeChunkResult()
        XCTAssertEqual(result.text, "你好")
        XCTAssertFalse(result.isFinal)
    }

    @MainActor func testCommittedUtteranceIsReportedOnceAsFinal() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "你好", isFinal: false)
        transcript.apply(text: "你好。", isFinal: true)

        let first = transcript.takeChunkResult()
        XCTAssertEqual(first.text, "你好。")
        XCTAssertTrue(first.isFinal)

        let second = transcript.takeChunkResult()
        XCTAssertEqual(second.text, "", "a commit must not be reported twice")
        XCTAssertFalse(second.isFinal)
    }

    @MainActor func testPartialAfterCommitExcludesCommittedText() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "第一句。", isFinal: true)
        _ = transcript.takeChunkResult()
        transcript.apply(text: "第二", isFinal: false)

        let result = transcript.takeChunkResult()
        XCTAssertEqual(result.text, "第二")
        XCTAssertFalse(result.isFinal)
    }

    @MainActor func testCommitsBetweenChunksAreJoinedWithoutCJKSpaces() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "第一句。", isFinal: true)
        transcript.apply(text: "第二句。", isFinal: true)

        let result = transcript.takeChunkResult()
        XCTAssertEqual(result.text, "第一句。第二句。")
        XCTAssertTrue(result.isFinal)
    }

    @MainActor func testFinishReturnsOnlyUnreportedCommitsPlusVolatile() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "已报告。", isFinal: true)
        _ = transcript.takeChunkResult()
        transcript.apply(text: "未报告。", isFinal: true)
        transcript.apply(text: "尾巴", isFinal: false)

        let result = transcript.takeFinishResult()
        XCTAssertEqual(result.text, "未报告。尾巴")
        XCTAssertTrue(result.isFinal)
    }

    @MainActor func testFinishWithNothingPendingIsEmptyFinal() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "说完了。", isFinal: true)
        _ = transcript.takeChunkResult()

        let result = transcript.takeFinishResult()
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.isFinal)
    }

    @MainActor func testWhitespaceOnlyCommitIsIgnored() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "  ", isFinal: true)
        let result = transcript.takeChunkResult()
        XCTAssertFalse(result.isFinal)
        XCTAssertEqual(result.text, "")
    }

    @MainActor func testLatinCommitsAreSpaceSeparated() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "Hello there.", isFinal: true)
        transcript.apply(text: "How are you?", isFinal: true)
        XCTAssertEqual(transcript.takeChunkResult().text, "Hello there. How are you?")
    }

    /// Fast speech: the transcriber's final pass can drop whole phrases its
    /// last draft had. The commit keeps the draft then (`HeardText.fuller`).
    @MainActor func testCommitKeepsLastDraftWhenFinalDroppedMostOfIt() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "我们周五之前把落地页的文案定下来", isFinal: false, audioStart: 0, audioEnd: 4.0)
        transcript.apply(text: "我们周五。", isFinal: true, audioStart: 0, audioEnd: 4.0)
        XCTAssertEqual(transcript.takeChunkResult().text, "我们周五之前把落地页的文案定下来")
    }

    /// The draft often already covers audio past the range being finalized
    /// ("ABCDEF" while "ABC" commits). Keeping it would commit "DEF" now and
    /// again with its own final.
    @MainActor func testCommitKeepsFinalWhenDraftRunsPastTheFinalRange() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "我们周五之前把落地页的文案定下来", isFinal: false, audioStart: 0, audioEnd: 4.0)
        transcript.apply(text: "我们周五。", isFinal: true, audioStart: 0, audioEnd: 1.2)
        XCTAssertEqual(transcript.takeChunkResult().text, "我们周五。")
    }

    @MainActor func testCommitKeepsDraftWhenItCoversOnlyTheFinalRange() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "我们周五之前把落地页的文案定下来", isFinal: false, audioStart: 0, audioEnd: 4.0)
        transcript.apply(text: "我们周五。", isFinal: true, audioStart: 0, audioEnd: 4.0)
        XCTAssertEqual(transcript.takeChunkResult().text, "我们周五之前把落地页的文案定下来")
    }

    @MainActor func testCommitKeepsFinalWhenRangesAreUnknown() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "我们周五之前把落地页的文案定下来", isFinal: false)
        transcript.apply(text: "我们周五。", isFinal: true)
        XCTAssertEqual(transcript.takeChunkResult().text, "我们周五。")
    }

    @MainActor func testCommitKeepsFinalWhenItIsAboutAsLongAsDraft() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "我们周五之前把文案定下来", isFinal: false)
        transcript.apply(text: "我们周五之前把文案定下来。", isFinal: true)
        XCTAssertEqual(transcript.takeChunkResult().text, "我们周五之前把文案定下来。")
    }

    @MainActor func testCommitCarriesTranscriberAudioStart() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "第一句。", isFinal: true, audioStart: 1.5)
        XCTAssertEqual(transcript.takeChunkResult().audioStart, 1.5)
    }

    @MainActor func testJoinedCommitsCarryTheFirstStart() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "第一句。", isFinal: true, audioStart: 1.5)
        transcript.apply(text: "第二句。", isFinal: true, audioStart: 3.0)
        XCTAssertEqual(transcript.takeChunkResult().audioStart, 1.5)
    }

    @MainActor func testFinishCarriesStartOfFirstUnreportedText() {
        var transcript = AppleSpeechTranscript()
        transcript.apply(text: "未报告。", isFinal: true, audioStart: 2.0)
        transcript.apply(text: "尾巴", isFinal: false, audioStart: 4.0)
        XCTAssertEqual(transcript.takeFinishResult().audioStart, 2.0)

        var volatileOnly = AppleSpeechTranscript()
        volatileOnly.apply(text: "尾巴", isFinal: false, audioStart: 4.0)
        XCTAssertEqual(volatileOnly.takeFinishResult().audioStart, 4.0)
    }

    @MainActor func testAppleEngineDeclaresSentenceFinals() throws {
        let engine = try AppleSpeechASREngine(locale: "zh-CN")
        XCTAssertTrue(engine.emitsSentenceFinals)
    }
}
