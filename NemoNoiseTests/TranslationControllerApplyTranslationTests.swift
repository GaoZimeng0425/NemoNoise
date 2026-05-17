import XCTest
@testable import NemoNoise

@MainActor
final class TranslationControllerApplyTranslationTests: XCTestCase {

    func testApplyTranslationWithMatchingSeqWritesChinese() {
        let c = TranslationController()
        c.displayedSeq = 5
        c.applyTranslation(seq: 5, chinese: "你好")
        XCTAssertEqual(c.chineseText, "你好")
    }

    func testApplyTranslationWithStaleSeqIsDropped() {
        let c = TranslationController()
        c.displayedSeq = 6
        c.chineseText = ""
        c.applyTranslation(seq: 5, chinese: "stale")
        XCTAssertEqual(c.chineseText, "", "stale seq translations must be dropped")
    }

    func testApplyTranslationWithFutureSeqIsDropped() {
        let c = TranslationController()
        c.displayedSeq = 5
        c.chineseText = ""
        c.applyTranslation(seq: 6, chinese: "future")
        XCTAssertEqual(c.chineseText, "")
    }
}
