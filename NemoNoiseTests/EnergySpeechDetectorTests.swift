import XCTest
@testable import NemoNoise

final class EnergySpeechDetectorTests: XCTestCase {
    private func window(_ amplitude: Float, count: Int = 512) -> [Float] {
        [Float](repeating: amplitude, count: count)
    }

    func testLoudWindowIsSpeech() {
        let det = EnergySpeechDetector(config: VADConfig.default)
        XCTAssertTrue(det.isSpeech(window(0.5)))
    }

    func testSilentWindowIsNotSpeech() {
        let det = EnergySpeechDetector(config: VADConfig.default)
        XCTAssertFalse(det.isSpeech(window(0.0)))
    }

    func testThresholdBoundary() {
        var cfg = VADConfig.default
        cfg.energyThreshold = 0.1
        let det = EnergySpeechDetector(config: cfg)
        XCTAssertFalse(det.isSpeech(window(0.05)))   // rms 0.05 < 0.1
        XCTAssertTrue(det.isSpeech(window(0.2)))      // rms 0.2 > 0.1
    }

    func testWindowSizeFromConfig() {
        XCTAssertEqual(EnergySpeechDetector(config: .default).windowSize, 512)
    }

    func testEmptyWindowIsNotSpeech() {
        XCTAssertFalse(EnergySpeechDetector(config: .default).isSpeech([]))
    }
}
