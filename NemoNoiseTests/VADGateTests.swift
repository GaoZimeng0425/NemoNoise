import XCTest
@testable import NemoNoise

nonisolated final class VADGateTests: XCTestCase {
    private let W = 512
    @MainActor private func real(_ v: Float = 0.5) -> [Float] { [Float](repeating: v, count: 512) }

    /// Explicit cap so the tests exercise the buffer mechanism, not the
    /// (tunable) default padding width.
    @MainActor private func cfg() -> VADConfig {
        var c = VADConfig()
        c.preSpeechWindows = 3
        return c
    }

    @MainActor func testNonSpeechEmitsSingleSilentWindow() {
        let gate = VADGate(config: cfg())
        let out = gate.step(window: real(), isSpeech: false)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].count, W)
        XCTAssertTrue(out[0].allSatisfy { $0 == 0 })
    }

    @MainActor func testSustainedSpeechPassesThroughUnchanged() {
        let gate = VADGate(config: cfg())
        _ = gate.step(window: real(), isSpeech: true)   // onset
        let out = gate.step(window: real(0.7), isSpeech: true)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], real(0.7))
    }

    @MainActor func testOnsetFlushesPreSpeechBufferThenCurrentWindow() {
        let gate = VADGate(config: cfg())   // preSpeechWindows = 3
        _ = gate.step(window: real(0.1), isSpeech: false)
        _ = gate.step(window: real(0.2), isSpeech: false)
        let out = gate.step(window: real(0.3), isSpeech: true)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0], real(0.1))
        XCTAssertEqual(out[1], real(0.2))
        XCTAssertEqual(out[2], real(0.3))
    }

    @MainActor func testPreSpeechBufferIsCappedAtConfiguredWindows() {
        let gate = VADGate(config: cfg())   // cap 3
        for v in [Float(0.1), 0.2, 0.3, 0.4, 0.5] {
            _ = gate.step(window: real(v), isSpeech: false)
        }
        let out = gate.step(window: real(0.9), isSpeech: true)
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0], real(0.3))
        XCTAssertEqual(out[1], real(0.4))
        XCTAssertEqual(out[2], real(0.5))
        XCTAssertEqual(out[3], real(0.9))
    }

    @MainActor func testResetClearsStateAndBuffer() {
        let gate = VADGate(config: cfg())
        _ = gate.step(window: real(0.1), isSpeech: false)
        gate.reset()
        let out = gate.step(window: real(0.3), isSpeech: true)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], real(0.3))
    }
}
