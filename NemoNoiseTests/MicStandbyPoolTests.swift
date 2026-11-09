import XCTest
import AVFoundation
@testable import NemoNoise

/// MicStandbyPool semantics with real (never-started) engines: deposit /
/// withdraw handoff, replacement, discard, and window expiry. The retire
/// hook is stubbed — touching `inputNode` in the test process hangs the HAL
/// proxy (see MicStandbyPool.retireEngine).
nonisolated final class MicStandbyPoolTests: XCTestCase {

    @MainActor func testDepositThenWithdrawReturnsEngine() {
        let pool = MicStandbyPool(window: 2, retireEngine: { _ in })
        let engine = AVAudioEngine()
        pool.deposit(engine: engine, format: AVAudioFormat())

        let parked = pool.withdraw()
        XCTAssertTrue(parked?.engine === engine)
        XCTAssertNil(pool.withdraw(), "second withdraw must be empty")
    }

    @MainActor func testDiscardEmptiesSlot() {
        let pool = MicStandbyPool(window: 2, retireEngine: { _ in })
        pool.deposit(engine: AVAudioEngine(), format: AVAudioFormat())

        pool.discard()
        XCTAssertNil(pool.withdraw())
    }

    @MainActor func testDepositReplacesParkedEngine() {
        let pool = MicStandbyPool(window: 2, retireEngine: { _ in })
        let first = AVAudioEngine()
        let second = AVAudioEngine()
        pool.deposit(engine: first, format: AVAudioFormat())
        pool.deposit(engine: second, format: AVAudioFormat())

        let parked = pool.withdraw()
        XCTAssertTrue(parked?.engine === second)
    }

    @MainActor func testWindowExpiryRetiresEngine() async {
        let pool = MicStandbyPool(window: 0.15, retireEngine: { _ in })
        pool.deposit(engine: AVAudioEngine(), format: AVAudioFormat())

        try? await Task.sleep(for: .seconds(0.8))
        XCTAssertNil(pool.withdraw(), "engine should have been discarded after the window")
    }
}
