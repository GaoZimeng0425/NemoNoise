import XCTest
@testable import NemoNoise

final class AudioStallWatchdogTests: XCTestCase {
    func testNotStalledImmediatelyAfterCreation() {
        let w = AudioStallWatchdog(threshold: 2.0, now: 100.0)
        XCTAssertFalse(w.isStalled(at: 100.0))
    }

    func testNotStalledJustBeforeThreshold() {
        let w = AudioStallWatchdog(threshold: 2.0, now: 100.0)
        XCTAssertFalse(w.isStalled(at: 102.0)) // exactly threshold is not yet stalled
    }

    func testStalledPastThreshold() {
        let w = AudioStallWatchdog(threshold: 2.0, now: 100.0)
        XCTAssertTrue(w.isStalled(at: 102.01))
    }

    func testRecordingActivityResetsTheClock() {
        var w = AudioStallWatchdog(threshold: 2.0, now: 100.0)
        w.recordActivity(at: 103.0)
        XCTAssertFalse(w.isStalled(at: 104.5)) // 1.5s since last activity
        XCTAssertTrue(w.isStalled(at: 105.01)) // 2.01s since last activity
    }
}
