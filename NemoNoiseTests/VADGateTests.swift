import XCTest
@testable import NemoNoise

final class VADGateTests: XCTestCase {
    private let W = 512
    private func real(_ v: Float = 0.5) -> [Float] { [Float](repeating: v, count: 512) }

    func testNonSpeechEmitsSingleSilentWindow() {
        let gate = VADGate(config: .default)
        let out = gate.step(window: real(), isSpeech: false)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].count, W)
        XCTAssertTrue(out[0].allSatisfy { $0 == 0 })
    }

    func testSustainedSpeechPassesThroughUnchanged() {
        let gate = VADGate(config: .default)
        _ = gate.step(window: real(), isSpeech: true)   // onset
        let out = gate.step(window: real(0.7), isSpeech: true)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], real(0.7))
    }

    func testOnsetFlushesPreSpeechBufferThenCurrentWindow() {
        let gate = VADGate(config: .default)   // preSpeechWindows = 3
        _ = gate.step(window: real(0.1), isSpeech: false)
        _ = gate.step(window: real(0.2), isSpeech: false)
        let out = gate.step(window: real(0.3), isSpeech: true)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0], real(0.1))
        XCTAssertEqual(out[1], real(0.2))
        XCTAssertEqual(out[2], real(0.3))
    }

    func testPreSpeechBufferIsCappedAtConfiguredWindows() {
        let gate = VADGate(config: .default)   // cap 3
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

    func testResetClearsStateAndBuffer() {
        let gate = VADGate(config: .default)
        _ = gate.step(window: real(0.1), isSpeech: false)
        gate.reset()
        let out = gate.step(window: real(0.3), isSpeech: true)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], real(0.3))
    }
}
