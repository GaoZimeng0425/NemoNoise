import XCTest
@testable import NemoNoise

final class TextInjectorTests: XCTestCase {

    func testInjectReturnsFailedWhenNoTarget() async {
        let injector = TextInjector()
        let outcome = await injector.inject("hello world")
        XCTAssertEqual(outcome, .failed(reason: "no_target"))
    }

    func testCaptureTargetWithNoFocusedElement() async {
        let injector = TextInjector()
        injector.captureTarget()
        let outcome = await injector.inject("test")
        if case .failed = outcome {
            // expected — running under XCTest, no focused element
        } else {
            XCTFail("expected .failed when no focused element, got \(outcome)")
        }
    }

    func testInjectEmptyStringWithNoTarget() async {
        let injector = TextInjector()
        let outcome = await injector.inject("")
        XCTAssertEqual(outcome, .failed(reason: "no_target"))
    }

    func testInjectLongTextReturnsFailedWithoutAttempting() async {
        let injector = TextInjector()
        // Long text guard fires before the no_target guard would, so we should
        // get failed(reason: "text_too_long...") even without a captured target.
        let bigText = String(repeating: "x", count: 5001)
        let outcome = await injector.inject(bigText)
        if case .failed(let reason) = outcome {
            XCTAssertTrue(reason.contains("too_long"), "expected too_long reason, got: \(reason)")
        } else {
            XCTFail("expected .failed for 5001-char text, got \(outcome)")
        }
    }
}
