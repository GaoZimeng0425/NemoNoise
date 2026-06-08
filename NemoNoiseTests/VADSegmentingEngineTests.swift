import XCTest
@testable import NemoNoise

/// Returns a scripted sequence of speech/non-speech decisions, one per window.
/// After the script is exhausted it returns false (silence).
private final class ScriptedDetector: VADSpeechDetector {
    let windowSize = 512
    var decisions: [Bool]
    private var i = 0
    init(_ decisions: [Bool]) { self.decisions = decisions }
    func isSpeech(_ window: [Float]) -> Bool {
        defer { i += 1 }
        return i < decisions.count ? decisions[i] : false
    }
    func reset() { /* keep index across reset; tests don't rely on it */ }
}

/// Stands in for an offline inner engine. Records each segment fed via
/// `feedChunk` and returns scripted text from `finish()` (FIFO).
private final class OfflineDecodeSpy: ASREngine, @unchecked Sendable {
    let isStreaming = false
    private(set) var resetCount = 0
    private(set) var fedSegments: [[Float]] = []
    var finishTexts: [String] = []
    var finishError: Error?

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        fedSegments.append(samples)
        return TranscriptionResult(text: "", isFinal: false, emotion: nil)
    }
    func finish() async throws -> TranscriptionResult {
        if let e = finishError { throw e }
        let t = finishTexts.isEmpty ? "" : finishTexts.removeFirst()
        return TranscriptionResult(text: t, isFinal: true, emotion: nil)
    }
    func reset() { resetCount += 1 }
}

private struct DummyError: Error {}

final class VADSegmentingEngineTests: XCTestCase {
    private let W = 512

    /// minSilence = 2 windows, minSpeech = 1 window, no pre-speech for clean counts.
    private func cfg() -> VADConfig {
        var c = VADConfig()
        c.windowSize = 512
        c.preSpeechWindows = 0
        c.minSilenceMs = 64      // 2 windows
        c.minSpeechMs = 32       // 1 window
        c.maxSegmentMs = 3200    // 100 windows
        return c
    }

    /// n consecutive 512-sample windows (sample values are irrelevant — the
    /// detector is scripted, not analyzing audio).
    private func samples(_ n: Int) -> [Float] { [Float](repeating: 0.5, count: n * 512) }

    func testIsStreamingReportsTrue() {
        // Reports true so the overlay shows the progressive text it now emits,
        // even though the inner engine is offline.
        let engine = VADSegmentingEngine(
            inner: OfflineDecodeSpy(),
            detector: ScriptedDetector([]),
            config: cfg()
        )
        XCTAssertTrue(engine.isStreaming)
    }

    func testBufferingReturnsEmptyPartialAndNoDecode() async throws {
        let spy = OfflineDecodeSpy()
        let engine = VADSegmentingEngine(inner: spy, detector: ScriptedDetector([false]), config: cfg())
        let r = try await engine.feedChunk(samples(1), sampleRate: 16000)
        XCTAssertEqual(r.text, "")
        XCTAssertFalse(r.isFinal)
        XCTAssertEqual(spy.fedSegments.count, 0)
    }

    func testSegmentCommitDecodesAndEmitsFinal() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["你好"]
        // speech, silence, silence -> closes one segment (3 windows)
        let detector = ScriptedDetector([true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r.text, "你好")
        XCTAssertTrue(r.isFinal)
        XCTAssertEqual(spy.resetCount, 1)
        XCTAssertEqual(spy.fedSegments.count, 1)
        XCTAssertEqual(spy.fedSegments[0].count, 3 * W)   // onset + 2 silence, no pre-speech
    }

    func testTwoSegmentsAcrossChunksEmitProgressively() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["A", "B"]
        let detector = ScriptedDetector([true, false, false, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r1 = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r1.text, "A")
        XCTAssertTrue(r1.isFinal)

        let r2 = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r2.text, "B")
        XCTAssertTrue(r2.isFinal)
        XCTAssertEqual(spy.fedSegments.count, 2)
    }

    func testMultipleSegmentsInOneChunkAreJoined() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["A", "B"]
        let detector = ScriptedDetector([true, false, false, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(6), sampleRate: 16000)
        XCTAssertEqual(r.text, "A B")
        XCTAssertTrue(r.isFinal)
    }

    func testFinishFlushesTrailingSegment() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["tail"]
        let detector = ScriptedDetector([true, true])   // open segment, no endpoint
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let partial = try await engine.feedChunk(samples(2), sampleRate: 16000)
        XCTAssertEqual(partial.text, "")        // still buffering
        let final = try await engine.finish()
        XCTAssertEqual(final.text, "tail")
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(spy.fedSegments.count, 1)
        XCTAssertEqual(spy.fedSegments[0].count, 2 * W)
    }

    func testSegmentDecodeFailureIsSwallowed() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishError = DummyError()
        let detector = ScriptedDetector([true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        // Must NOT throw; the bad segment yields no text, session continues.
        let r = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r.text, "")
        XCTAssertFalse(r.isFinal)
    }

    func testResetClearsSegmenterAndInner() async throws {
        let spy = OfflineDecodeSpy()
        let detector = ScriptedDetector([true, true])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())
        _ = try await engine.feedChunk(samples(2), sampleRate: 16000)   // open segment

        engine.reset()
        // After reset, finish() finds no open segment -> empty final.
        let final = try await engine.finish()
        XCTAssertEqual(final.text, "")
    }
}
