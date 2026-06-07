import XCTest
@testable import NemoNoise

/// Detector test double: returns a scripted decision per window.
private final class ScriptedSpeechDetector: VADSpeechDetector {
    let windowSize: Int
    private let decisions: [Bool]
    private var i = 0
    init(windowSize: Int = 512, decisions: [Bool]) {
        self.windowSize = windowSize
        self.decisions = decisions
    }
    func isSpeech(_ window: [Float]) -> Bool {
        defer { i += 1 }
        return i < decisions.count ? decisions[i] : false
    }
    func reset() { i = 0 }
}

final class VADGatedSourceTests: XCTestCase {
    private func samples(_ v: Float, _ count: Int) -> [Float] { [Float](repeating: v, count: count) }

    func testConformsToAudioSource() {
        let _: any AudioSource = VADGatedSource(
            inner: MockAudioSource(),
            detector: EnergySpeechDetector()
        )
    }

    func testReturnsNilWhenLessThanOneWindow() {
        let src = VADGatedSource(inner: MockAudioSource(),
                                 detector: ScriptedSpeechDetector(decisions: [true]))
        XCTAssertNil(src.process(samples(0.5, 300)))   // < 512
    }

    func testSilenceIsGatedToZeros() {
        let src = VADGatedSource(inner: MockAudioSource(),
                                 detector: ScriptedSpeechDetector(decisions: [false, false]))
        let out = src.process(samples(0.5, 1024))      // 2 windows, both non-speech
        XCTAssertNotNil(out)
        XCTAssertEqual(out!.samples.count, 1024)
        XCTAssertTrue(out!.samples.allSatisfy { $0 == 0 })
    }

    func testOnsetPrependsPreSpeechRealAudio() {
        // window0 = non-speech (buffered + emits zeros), window1 = speech onset
        // (flush buffered real window0 + real window1). Emitted = 512 zeros +
        // 512 real (w0) + 512 real (w1) = 1536 samples.
        let src = VADGatedSource(inner: MockAudioSource(),
                                 detector: ScriptedSpeechDetector(decisions: [false, true]))
        let out = src.process(samples(0.5, 1024))
        XCTAssertNotNil(out)
        XCTAssertEqual(out!.samples.count, 1536)
        let nonZero = out!.samples.filter { $0 != 0 }.count
        XCTAssertEqual(nonZero, 1024)   // the two real windows survived
    }

    func testLeftoverCarriesAcrossCalls() {
        let src = VADGatedSource(inner: MockAudioSource(),
                                 detector: ScriptedSpeechDetector(decisions: [false, false]))
        XCTAssertNil(src.process(samples(0.0, 300)))    // 300 buffered, no window
        let out = src.process(samples(0.0, 300))         // 600 total -> 1 window
        XCTAssertNotNil(out)
        XCTAssertEqual(out!.samples.count, 512)
    }
}
