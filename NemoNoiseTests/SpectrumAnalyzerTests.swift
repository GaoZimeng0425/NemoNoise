import XCTest
@testable import NemoNoise

final class SpectrumAnalyzerTests: XCTestCase {
    private let sampleRate: Float = 16000
    private let binCount = 16

    func makeSine(freq: Float, duration: Float = 0.1, amplitude: Float = 0.5) -> [Float] {
        let count = Int(sampleRate * duration)
        let twoPi = 2 * Float.pi
        return (0..<count).map { i in
            amplitude * sin(twoPi * freq * Float(i) / sampleRate)
        }
    }

    func testReturnsBinCountElements() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let result = analyzer.analyze(makeSine(freq: 1000))
        XCTAssertEqual(result.count, binCount)
    }

    func testSilenceIsNearZero() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let silence = Array<Float>(repeating: 0, count: 1024)
        let result = analyzer.analyze(silence)
        for (i, v) in result.enumerated() {
            XCTAssertLessThan(v, 0.05, "bin \(i) should be near 0 for silence, got \(v)")
        }
    }

    func testLowFrequencyDominatesLowBin() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let result = analyzer.analyze(makeSine(freq: 100))
        guard let maxIdx = result.indices.max(by: { result[$0] < result[$1] }) else {
            return XCTFail("empty result")
        }
        XCTAssertLessThanOrEqual(maxIdx, 2, "100Hz sine should peak in bin 0-2, got \(maxIdx)")
    }

    func testMidFrequencyDominatesMidBin() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let result = analyzer.analyze(makeSine(freq: 1000))
        guard let maxIdx = result.indices.max(by: { result[$0] < result[$1] }) else {
            return XCTFail("empty result")
        }
        XCTAssertGreaterThanOrEqual(maxIdx, 6, "1kHz sine should peak in middle bins, got \(maxIdx)")
        XCTAssertLessThanOrEqual(maxIdx, 12, "1kHz sine should peak in middle bins, got \(maxIdx)")
    }

    func testHighFrequencyDominatesHighBin() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let result = analyzer.analyze(makeSine(freq: 3000))
        guard let maxIdx = result.indices.max(by: { result[$0] < result[$1] }) else {
            return XCTFail("empty result")
        }
        XCTAssertGreaterThanOrEqual(maxIdx, 12, "3kHz sine should peak in upper bins, got \(maxIdx)")
    }

    func testShortInputIsPadded() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let result = analyzer.analyze(makeSine(freq: 1000, duration: 0.006))
        XCTAssertEqual(result.count, binCount)
    }

    func testValuesStayInZeroOneRange() {
        let analyzer = SpectrumAnalyzer(binCount: binCount, sampleRate: sampleRate)
        let loud = makeSine(freq: 500, amplitude: 0.95)
        let result = analyzer.analyze(loud)
        for v in result {
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
        }
    }
}
