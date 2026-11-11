import XCTest
@testable import NemoNoise

/// Joining VAD-cut, self-punctuated segments (Qwen3 / SenseVoice) must not
/// insert an ASCII space between CJK segments — that space shows up after a
/// full-width mark ("你好。 走吧。") and reads as wrong punctuation. Latin
/// sentences still get the conventional inter-sentence space.
nonisolated final class TranscriptJoinTests: XCTestCase {
    @MainActor func testCJKSegmentsJoinWithoutSpace() {
        let out = TranscriptJoin.sentences(["今天天气不错。", "我们出去走走吧。"])
        XCTAssertEqual(out, "今天天气不错。我们出去走走吧。")
    }

    @MainActor func testLatinSegmentsKeepInterSentenceSpace() {
        let out = TranscriptJoin.sentences(["Hello there.", "How are you?"])
        XCTAssertEqual(out, "Hello there. How are you?")
    }

    @MainActor func testNoSpaceWhenEitherBoundarySideIsCJK() {
        XCTAssertEqual(TranscriptJoin.sentences(["你好", "world"]), "你好world")
        XCTAssertEqual(TranscriptJoin.sentences(["hello", "世界"]), "hello世界")
    }

    @MainActor func testDropsEmptyPiecesAndTrimsEdges() {
        XCTAssertEqual(TranscriptJoin.sentences(["  你好。 ", "", "  走吧。"]), "你好。走吧。")
    }

    @MainActor func testSinglePieceAndEmptyInput() {
        XCTAssertEqual(TranscriptJoin.sentences(["只有一段。"]), "只有一段。")
        XCTAssertEqual(TranscriptJoin.sentences([String]()), "")
        XCTAssertEqual(TranscriptJoin.sentences(["   ", ""]), "")
    }

    // MARK: - Seam pauses (breath vs sentence end)

    /// Each VAD-cut segment is decoded as a complete utterance and so ends in
    /// a sentence mark; a short seam pause means that mark punctuated a breath.
    @MainActor func testShortSeamStripsPreviousSentenceMark() {
        let out = TranscriptJoin.sentences([("你好。", nil), ("走吧。", 0.1)])
        XCTAssertEqual(out, "你好走吧。")
    }

    @MainActor func testLongSeamKeepsSentenceMark() {
        let out = TranscriptJoin.sentences([("你好。", nil), ("走吧。", TranscriptJoin.sentencePause)])
        XCTAssertEqual(out, "你好。走吧。")
    }

    @MainActor func testUnknownPauseKeepsSentenceMark() {
        // nil = the engine didn't measure a pause (streaming engines).
        XCTAssertEqual(TranscriptJoin.sentences([("你好。", nil), ("走吧。", nil)]), "你好。走吧。")
    }

    @MainActor func testShortSeamStripsLatinMarkAndKeepsSpaceRule() {
        XCTAssertEqual(TranscriptJoin.sentences([("Hello.", nil), ("there", 0.5)]), "Hello there")
        XCTAssertEqual(TranscriptJoin.sentences([("好。", nil), ("world", 0.9)]), "好world")
    }

    @MainActor func testSeamStripOnlyTakesSentenceMarksNotCommas() {
        XCTAssertEqual(TranscriptJoin.sentences([("但是，", nil), ("我想说", 0.1)]), "但是，我想说")
    }

    @MainActor func testLastPieceAlwaysKeepsItsMark() {
        let out = TranscriptJoin.sentences([("第一句。", nil), ("最后一句。", 0.1)])
        XCTAssertEqual(out, "第一句最后一句。")
    }

    @MainActor func testSeamStripTakesWholeRunOfMarks() {
        let out = TranscriptJoin.sentences([("真的吗？？", nil), ("是的", 0.1)])
        XCTAssertEqual(out, "真的吗是的")
    }
}
