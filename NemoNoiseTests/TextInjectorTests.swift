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
}
