import XCTest
@testable import NemoNoise

final class TextInjectorTests: XCTestCase {

    func testInjectAXReturnsFalseWhenNoTarget() {
        let injector = TextInjector()
        let result = injector.injectAX("hello world")
        XCTAssertFalse(result)
    }

    func testCaptureTargetWithNoFocusedElement() {
        let injector = TextInjector()
        injector.captureTarget()
        let result = injector.injectAX("test")
        XCTAssertFalse(result)
    }

    func testInjectEmptyStringWithNoTarget() {
        let injector = TextInjector()
        let result = injector.injectAX("")
        XCTAssertFalse(result)
    }
}
