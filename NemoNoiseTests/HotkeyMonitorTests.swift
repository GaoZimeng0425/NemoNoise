import XCTest
@testable import NemoNoise

final class HotkeyMonitorTests: XCTestCase {

    func testOnKeyDownCallbackType() {
        let monitor = HotkeyMonitor()
        var fired = false
        monitor.onKeyDown = { fired = true }
        monitor.simulateKeyDown()
        XCTAssertTrue(fired)
    }

    func testOnKeyUpCallbackType() {
        let monitor = HotkeyMonitor()
        var fired = false
        monitor.onKeyUp = { fired = true }
        monitor.simulateKeyUp()
        XCTAssertTrue(fired)
    }

    func testStopCancelsEventStream() {
        let monitor = HotkeyMonitor()
        monitor.start()
        monitor.stop()
        var fired = false
        monitor.onKeyDown = { fired = true }
        monitor.simulateKeyDown()
        XCTAssertFalse(fired)
    }
}
