import XCTest
@testable import NemoNoise

/// Cases ported from cicada's `HeardTextTests.swift` (Apache-2.0,
/// github.com/wquguru/cicada @ 0c1dda2), translated from Swift Testing.
nonisolated final class HeardTextTests: XCTestCase {

    // MARK: - clean

    @MainActor func testCleanCollapsesBreathMarks() {
        XCTAssertEqual(HeardText.clean("in.........."), "in…")
        XCTAssertEqual(HeardText.clean(", , that"), "that")
        XCTAssertEqual(HeardText.clean(". , that is causing a product twice."), "that is causing a product twice.")
        XCTAssertEqual(HeardText.clean("that.......... in increased production"), "that… in increased production")
        XCTAssertEqual(HeardText.clean("would.. would be oversupplied."), "would… would be oversupplied.")
        XCTAssertEqual(HeardText.clean("whether it's in the UALE, , Saudi Arab, or the wider."),
                       "whether it's in the UALE, Saudi Arab, or the wider.")
        XCTAssertEqual(HeardText.clean(",, and there should be more diversified."), "and there should be more diversified.")
        XCTAssertEqual(HeardText.clean(", you... lucrative"), "you… lucrative")
        XCTAssertEqual(HeardText.clean("of people.."), "of people…")
        XCTAssertEqual(HeardText.clean("，，我们周四上线。。。"), "我们周四上线…")
        XCTAssertEqual(HeardText.clean("........"), "")
    }

    @MainActor func testCleanLeavesOrdinaryTextAlone() {
        XCTAssertEqual(HeardText.clean("to over 1.4 million a day."), "to over 1.4 million a day.")
        XCTAssertEqual(HeardText.clean("The U.S. said no."), "The U.S. said no.")
        XCTAssertEqual(HeardText.clean("我们周四上线。"), "我们周四上线。")
    }

    @MainActor func testCleanKeepsLineBreaksAndNegativeNumbers() {
        XCTAssertEqual(HeardText.clean("第一段。\n\n第二段。"), "第一段。\n\n第二段。")
        XCTAssertEqual(HeardText.clean("-5度"), "-5度")
        XCTAssertEqual(HeardText.clean("- 那么"), "那么")
    }

    // MARK: - fuller

    /// cicada issue #1, from a 200 wpm run: the final pass lost "the support
    /// team asked", "numbers", "foxtrot 6".
    @MainActor func testFullerKeepsDraftWhenFinalDroppedPhrases() {
        let final = "for a new escalation process for enterprise customers, and Echo 5 Finance, needs the budget. for next year by the end. of this month. in."
        let draft = "to for the support team asked for a new escalation process for enterprise customers and echo 5 Finance needs the budget numbers for next year by the end of this month in foxtrot 6"
        XCTAssertEqual(HeardText.fuller(final: final, draft: draft), draft)
    }

    @MainActor func testFullerKeepsFinalWhenItHasAboutAsMuch() {
        let final = "We need the design review finished by Tuesday, and the audit too."
        XCTAssertEqual(HeardText.fuller(final: final,
                                        draft: "We need the design review finished by Tuesday and the the audit too"), final)
        XCTAssertEqual(HeardText.fuller(final: final, draft: ""), final)
        XCTAssertEqual(HeardText.fuller(final: "我们周五之前把文案定下来。", draft: "我们周五之前把落地页的文案定下来"),
                       "我们周五之前把文案定下来。")
    }

    @MainActor func testFullerKeepsChineseDraftWhenFinalLostMostOfIt() {
        XCTAssertEqual(HeardText.fuller(final: "我们周五。", draft: "我们周五之前把落地页的文案定下来"),
                       "我们周五之前把落地页的文案定下来")
    }
}
