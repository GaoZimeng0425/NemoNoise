import XCTest
@testable import NemoNoise

nonisolated final class HotkeyMonitorTests: XCTestCase {

    @MainActor func testOnKeyDownCallbackType() {
        let monitor = HotkeyMonitor()
        var fired = false
        monitor.onKeyDown = { fired = true }
        monitor.simulateKeyDown()
        XCTAssertTrue(fired)
    }

    @MainActor func testOnKeyUpCallbackType() {
        let monitor = HotkeyMonitor()
        var fired = false
        monitor.onKeyUp = { fired = true }
        monitor.simulateKeyUp()
        XCTAssertTrue(fired)
    }

    @MainActor func testStopCancelsEventStream() {
        let monitor = HotkeyMonitor()
        monitor.start()
        monitor.stop()
        var fired = false
        monitor.onKeyDown = { fired = true }
        monitor.simulateKeyDown()
        XCTAssertFalse(fired)
    }
}
