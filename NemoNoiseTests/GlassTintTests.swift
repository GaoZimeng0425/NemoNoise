import XCTest
import SwiftUI
@testable import NemoNoise

final class GlassTintTests: XCTestCase {
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
