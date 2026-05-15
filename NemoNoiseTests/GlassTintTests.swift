import XCTest
import SwiftUI
@testable import NemoNoise

final class GlassTintTests: XCTestCase {
    // HUD mapping
    func testHUDReadyReturnsNil() {
        XCTAssertNil(GlassTint.forHUD(.ready))
    }

    func testHUDRecordingReturnsRed() {
        XCTAssertEqual(GlassTint.forHUD(.recording), Color.red.opacity(0.15))
    }

    func testHUDProcessingReturnsBlue() {
        XCTAssertEqual(GlassTint.forHUD(.processing), Color.blue.opacity(0.12))
    }

    func testHUDFailedReturnsOrange() {
        XCTAssertEqual(GlassTint.forHUD(.failed("boom")), Color.orange.opacity(0.18))
    }

    // Subtitle mapping
    func testSubtitleIdleReturnsNil() {
        XCTAssertNil(GlassTint.forSubtitle(.idle))
    }

    func testSubtitleCapturingReturnsGreen() {
        XCTAssertEqual(GlassTint.forSubtitle(.capturing), Color.green.opacity(0.12))
    }

    func testSubtitleErrorReturnsNil() {
        XCTAssertNil(GlassTint.forSubtitle(.error("boom")))
    }
}
