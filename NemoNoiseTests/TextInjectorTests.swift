import XCTest
@testable import NemoNoise

final class TextInjectorTests: XCTestCase {

    func testInjectAXReturnsFalseWhenNoTarget() async {
        let injector = TextInjector()
        let result = await injector.injectAX("hello world")
        XCTAssertFalse(result)
    }

    func testCaptureTargetWithNoFocusedElement() async {
        let injector = TextInjector()
        injector.captureTarget()
        let result = await injector.injectAX("test")
        XCTAssertFalse(result)
    }

    func testInjectEmptyStringWithNoTarget() async {
        let injector = TextInjector()
        let result = await injector.injectAX("")
        XCTAssertFalse(result)
    }
}
