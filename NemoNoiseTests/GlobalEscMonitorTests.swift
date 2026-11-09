import XCTest
@testable import NemoNoise

/// GlobalEscMonitor lifecycle invariants. Whether the tap itself can be
/// created depends on the environment (accessibility trust); these tests
/// must hold for BOTH outcomes.
nonisolated final class GlobalEscMonitorTests: XCTestCase {

    @MainActor func testStartStopIsIdempotent() {
        let monitor = GlobalEscMonitor()
        let first = monitor.start { }

        // Replacing a live tap with another one must not crash or leak.
        let second = monitor.start { }
        XCTAssertEqual(second, first, "tap availability should not flip between consecutive starts")

        monitor.stop()
        monitor.stop()  // idempotent
    }

    @MainActor func testStopWithoutStartIsSafe() {
        let monitor = GlobalEscMonitor()
        monitor.stop()
    }

    @MainActor func testStartAfterStopWorks() {
        let monitor = GlobalEscMonitor()
        let first = monitor.start { }
        monitor.stop()
        let restarted = monitor.start { }
        XCTAssertEqual(restarted, first)
        monitor.stop()
    }
    // MARK: - Which key presses are ours

    /// Holding Esc auto-repeats within the 2.5 s arm window: the repeat must
    /// not count as the second press, or one long press cancels.
    @MainActor func testAutoRepeatIsNotOurs() {
        XCTAssertFalse(GlobalEscMonitor.isCancelPress(keyCode: 53, isAutoRepeat: true, flags: []))
    }

    /// ⌘⌥Esc is Force Quit; any modified Esc belongs to the system or the app.
    @MainActor func testModifiedEscIsNotOurs() {
        for flag: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl, .maskShift] {
            XCTAssertFalse(GlobalEscMonitor.isCancelPress(keyCode: 53, isAutoRepeat: false, flags: flag))
        }
    }

    @MainActor func testPlainEscIsOurs() {
        XCTAssertTrue(GlobalEscMonitor.isCancelPress(keyCode: 53, isAutoRepeat: false, flags: []))
        // Caps Lock / numeric-pad state are not intent modifiers.
        XCTAssertTrue(GlobalEscMonitor.isCancelPress(keyCode: 53, isAutoRepeat: false, flags: .maskAlphaShift))
    }

    @MainActor func testOtherKeysAreNotOurs() {
        XCTAssertFalse(GlobalEscMonitor.isCancelPress(keyCode: 0, isAutoRepeat: false, flags: []))
    }
}
