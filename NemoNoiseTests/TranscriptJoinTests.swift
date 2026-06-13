import XCTest
@testable import NemoNoise

/// Joining VAD-cut, self-punctuated segments (Qwen3 / SenseVoice) must not
/// insert an ASCII space between CJK segments — that space shows up after a
/// full-width mark ("你好。 走吧。") and reads as wrong punctuation. Latin
/// sentences still get the conventional inter-sentence space.
final class TranscriptJoinTests: XCTestCase {
    func testCJKSegmentsJoinWithoutSpace() {
        let out = TranscriptJoin.sentences(["今天天气不错。", "我们出去走走吧。"])
        XCTAssertEqual(out, "今天天气不错。我们出去走走吧。")
    }

    func testLatinSegmentsKeepInterSentenceSpace() {
        let out = TranscriptJoin.sentences(["Hello there.", "How are you?"])
        XCTAssertEqual(out, "Hello there. How are you?")
    }

    func testNoSpaceWhenEitherBoundarySideIsCJK() {
        XCTAssertEqual(TranscriptJoin.sentences(["你好", "world"]), "你好world")
        XCTAssertEqual(TranscriptJoin.sentences(["hello", "世界"]), "hello世界")
    }

    func testDropsEmptyPiecesAndTrimsEdges() {
        XCTAssertEqual(TranscriptJoin.sentences(["  你好。 ", "", "  走吧。"]), "你好。走吧。")
    }

    func testSinglePieceAndEmptyInput() {
        XCTAssertEqual(TranscriptJoin.sentences(["只有一段。"]), "只有一段。")
        XCTAssertEqual(TranscriptJoin.sentences([]), "")
        XCTAssertEqual(TranscriptJoin.sentences(["   ", ""]), "")
    }
}
