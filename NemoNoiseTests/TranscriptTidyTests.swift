import XCTest
@testable import NemoNoise

nonisolated final class TranscriptTidyTests: XCTestCase {

    // MARK: - tidy: what recognizers leave behind

    /// A committed sentence's period that came out at the start of the next
    /// line (seen from Apple SpeechAnalyzer on device, 2026-11-09).
    @MainActor func testLeadingMarkFromThePreviousSentenceIsDropped() {
        XCTAssertEqual(TranscriptTidy.tidy("。下一句开始了"), "下一句开始了")
        XCTAssertEqual(TranscriptTidy.tidy("，然后呢"), "然后呢")
        XCTAssertEqual(TranscriptTidy.tidy(" . and then"), "and then")
    }

    @MainActor func testSpaceBeforeAMarkIsDropped() {
        XCTAssertEqual(TranscriptTidy.tidy("先这样 ，再看"), "先这样，再看")
        XCTAssertEqual(TranscriptTidy.tidy("ready ?"), "ready?")
    }

    /// Breaths and hesitations transcribed as runs of dots.
    @MainActor func testDotRunsBecomeOneEllipsis() {
        XCTAssertEqual(TranscriptTidy.tidy("我想想。。。好吧"), "我想想…好吧")
        XCTAssertEqual(TranscriptTidy.tidy("well...... maybe"), "well… maybe")
        XCTAssertEqual(TranscriptTidy.tidy("hmm.. ok"), "hmm… ok")
        XCTAssertEqual(TranscriptTidy.tidy("等一下… …可以"), "等一下…可以")
    }

    @MainActor func testRepeatedCommasCollapse() {
        XCTAssertEqual(TranscriptTidy.tidy("苹果，，香蕉"), "苹果，香蕉")
        XCTAssertEqual(TranscriptTidy.tidy("red, , green"), "red, green")
    }

    @MainActor func testCommaNextToEllipsisIsDropped() {
        XCTAssertEqual(TranscriptTidy.tidy("所以，…我们"), "所以…我们")
        XCTAssertEqual(TranscriptTidy.tidy("so…, we"), "so… we")
    }

    @MainActor func testSpaceRunsCollapseButLineBreaksStay() {
        XCTAssertEqual(TranscriptTidy.tidy("one   two\tthree"), "one two three")
        XCTAssertEqual(TranscriptTidy.tidy("上一段。\n\n下一段。"), "上一段。\n\n下一段。")
    }

    @MainActor func testOnlyMarksBecomesEmpty() {
        XCTAssertEqual(TranscriptTidy.tidy("……"), "")
        XCTAssertEqual(TranscriptTidy.tidy(" ，。 "), "")
    }

    @MainActor func testOrdinaryTextIsUntouched() {
        XCTAssertEqual(TranscriptTidy.tidy("版本 2.5 已经发布。"), "版本 2.5 已经发布。")
        XCTAssertEqual(TranscriptTidy.tidy("Meet at 3 p.m. today."), "Meet at 3 p.m. today.")
        XCTAssertEqual(TranscriptTidy.tidy("气温-3度"), "气温-3度")
    }

    @MainActor func testLeadingMinusOfANumberIsKept() {
        XCTAssertEqual(TranscriptTidy.tidy("-3度"), "-3度")
        XCTAssertEqual(TranscriptTidy.tidy("- 好的"), "好的")
    }

    // MARK: - recoverDroppedWords: a final that lost what its draft had

    @MainActor func testDraftWinsWhenFinalLostMuchOfIt() {
        let draft = "明天上午十点在三楼会议室讨论预算"
        XCTAssertEqual(TranscriptTidy.recoverDroppedWords(final: "明天上午。", draft: draft), draft)

        let english = "please send the updated budget numbers to finance before friday"
        XCTAssertEqual(TranscriptTidy.recoverDroppedWords(final: "please send the budget.", draft: english), english)
    }

    @MainActor func testFinalWinsWhenItHasAboutAsMuch() {
        let final = "明天上午十点开会。"
        XCTAssertEqual(TranscriptTidy.recoverDroppedWords(final: final, draft: "明天上午十点钟开会"), final)
        XCTAssertEqual(TranscriptTidy.recoverDroppedWords(final: final, draft: ""), final)
        XCTAssertEqual(TranscriptTidy.recoverDroppedWords(final: "Send it today.", draft: "send it out today"), "Send it today.")
    }

    @MainActor func testRecoveredDraftIsTidied() {
        XCTAssertEqual(TranscriptTidy.recoverDroppedWords(final: "好。", draft: "，好的那我们就按这个方案往下推进"),
                       "好的那我们就按这个方案往下推进")
    }
}
