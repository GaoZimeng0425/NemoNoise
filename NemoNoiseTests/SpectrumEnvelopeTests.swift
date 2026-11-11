import XCTest
@testable import NemoNoise

nonisolated final class SpectrumEnvelopeTests: XCTestCase {

    func testApplyMovesBinsTowardTargetWithoutOvershooting() {
        var envelope = SpectrumEnvelope(binCount: 2)
        envelope.apply([1, 0.5])
        XCTAssertGreaterThan(envelope.bins[0], 0)
        XCTAssertLessThan(envelope.bins[0], 1)
        XCTAssertGreaterThan(envelope.bins[1], 0)
        XCTAssertLessThan(envelope.bins[1], 0.5)
    }

    func testConvergesToHeldTarget() {
        var envelope = SpectrumEnvelope(binCount: 1)
        for _ in 0..<50 { envelope.apply([1]) }
        XCTAssertEqual(envelope.bins[0], 1, accuracy: 0.001)
    }

    /// The whole point of the envelope: a rising edge tracks faster than a
    /// falling edge decays, so peaks pop and tails linger.
    func testAttackIsFasterThanRelease() {
        var settled = SpectrumEnvelope(binCount: 1)
        for _ in 0..<50 { settled.apply([0.5]) }

        var rising = settled
        rising.apply([1.0])
        let rise = rising.bins[0] - 0.5

        var falling = settled
        falling.apply([0])
        let fall = 0.5 - falling.bins[0]

        XCTAssertGreaterThan(rise, fall)
    }

    /// A producer restart at a different bin count must not inherit the old
    /// values: the smoothing restarts from silence.
    func testSizeChangeRestartsFromZero() {
        var envelope = SpectrumEnvelope(binCount: 4)
        for _ in 0..<50 { envelope.apply([1, 1, 1, 1]) }
        XCTAssertEqual(envelope.bins[0], 1, accuracy: 0.001)

        envelope.apply([1, 1])
        XCTAssertEqual(envelope.bins.count, 2)
        // Continued from the old value it would stay ≈1; from zero one
        // attack step lands ≈0.76.
        XCTAssertGreaterThan(envelope.bins[0], 0.5)
        XCTAssertLessThan(envelope.bins[0], 0.9)
    }

    func testResetSilencesEveryBin() {
        var envelope = SpectrumEnvelope(binCount: 3)
        for _ in 0..<10 { envelope.apply([1, 1, 1]) }
        envelope.reset()
        XCTAssertEqual(envelope.bins, [0, 0, 0])
    }
}
