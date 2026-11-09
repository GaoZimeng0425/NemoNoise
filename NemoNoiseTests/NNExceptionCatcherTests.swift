import XCTest
@testable import NemoNoise

nonisolated final class NNExceptionCatcherTests: XCTestCase {

    @MainActor func testNoExceptionRunsBlockAndDoesNotThrow() {
        var ran = false
        XCTAssertNoThrow(try catchingObjCException { ran = true })
        XCTAssertTrue(ran)
    }

    @MainActor func testNSExceptionIsConvertedToSwiftError() {
        XCTAssertThrowsError(try catchingObjCException {
            NSException(name: .genericException, reason: "boom", userInfo: nil).raise()
        }) { error in
            XCTAssertEqual((error as NSError).domain, "NNObjCException")
            // The exception's reason becomes the localized description.
            XCTAssertEqual((error as NSError).localizedDescription, "boom")
        }
    }
}
