import XCTest
@testable import NemoNoise

final class VADSegmenterTests: XCTestCase {
    private let W = 512

    /// Small thresholds so tests are short. 32 ms/window.
    private func cfg() -> VADConfig {
        var c = VADConfig()
        c.windowSize = 512
        c.preSpeechWindows = 2
        c.minSilenceMs = 64    // 2 windows
        c.minSpeechMs = 32     // 1 window
        c.maxSegmentMs = 320   // 10 windows
        return c
    }

    private func win(_ v: Float) -> [Float] { [Float](repeating: v, count: 512) }

    func testNonSpeechNeverEmitsSegment() {
        let seg = VADSegmenter(config: cfg())
        for _ in 0..<5 {
            XCTAssertEqual(seg.step(window: win(0.0), isSpeech: false), .buffering)
        }
    }

    func testSpeechThenSilenceEmitsSegment() {
        let seg = VADSegmenter(config: cfg())
        XCTAssertEqual(seg.step(window: win(0.5), isSpeech: true), .buffering)   // onset
        XCTAssertEqual(seg.step(window: win(0.5), isSpeech: true), .buffering)   // 2nd speech
        XCTAssertEqual(seg.step(window: win(0.0), isSpeech: false), .buffering)  // silence 1
        // silence 2 reaches minSilence (2 windows) -> close
        guard case .segment(let samples) = seg.step(window: win(0.0), isSpeech: false) else {
            return XCTFail("expected segment")
        }
        // onset + 2nd speech + 2 silence windows = 4 windows
        XCTAssertEqual(samples.count, 4 * W)
    }

    func testOnsetPrependsPreSpeechBuffer() {
        let seg = VADSegmenter(config: cfg())   // preSpeechWindows = 2
        _ = seg.step(window: win(0.1), isSpeech: false)
        _ = seg.step(window: win(0.2), isSpeech: false)
        _ = seg.step(window: win(0.9), isSpeech: true)   // onset, should prepend 0.1, 0.2
        _ = seg.step(window: win(0.0), isSpeech: false)
        guard case .segment(let s) = seg.step(window: win(0.0), isSpeech: false) else {
            return XCTFail("expected segment")
        }
        // pre(2) + onset(1) + silence(2) = 5 windows
        XCTAssertEqual(s.count, 5 * W)
        XCTAssertEqual(Array(s.prefix(W)), win(0.1))               // first pre-speech window
        XCTAssertEqual(Array(s[W..<2*W]), win(0.2))               // second pre-speech window
        XCTAssertEqual(Array(s[2*W..<3*W]), win(0.9))             // onset window
    }

    func testShortBlipIsDiscarded() {
        // minSpeech requires 3 windows so a single-window blip is rejected.
        var c = cfg(); c.minSpeechMs = 96   // 3 windows
        let s = VADSegmenter(config: c)
        _ = s.step(window: win(0.5), isSpeech: true)   // 1 speech window only
        _ = s.step(window: win(0.0), isSpeech: false)  // silence 1
        // silence 2 closes, but speech (1) < minSpeech (3) -> discard
        XCTAssertEqual(s.step(window: win(0.0), isSpeech: false), .buffering)
    }

    func testInternalPauseDoesNotSplit() {
        let seg = VADSegmenter(config: cfg())   // minSilence = 2 windows
        _ = seg.step(window: win(0.5), isSpeech: true)    // onset
        _ = seg.step(window: win(0.0), isSpeech: false)   // 1 silence (< 2, no split)
        _ = seg.step(window: win(0.5), isSpeech: true)    // speech resumes
        _ = seg.step(window: win(0.0), isSpeech: false)   // silence 1
        guard case .segment(let s) = seg.step(window: win(0.0), isSpeech: false) else {
            return XCTFail("expected single segment")
        }
        XCTAssertEqual(s.count, 5 * W)   // onset + silence + speech + 2 silence
    }

    func testMaxSegmentForceCut() {
        let seg = VADSegmenter(config: cfg())   // maxSegment = 10 windows
        var event: SegmenterEvent = .buffering
        for _ in 0..<10 {
            event = seg.step(window: win(0.5), isSpeech: true)
        }
        guard case .segment(let s) = event else {
            return XCTFail("expected force-cut segment at 10 windows")
        }
        XCTAssertEqual(s.count, 10 * W)
    }

    func testFlushReturnsOpenSegmentThenNil() {
        let seg = VADSegmenter(config: cfg())
        _ = seg.step(window: win(0.5), isSpeech: true)   // onset
        _ = seg.step(window: win(0.5), isSpeech: true)   // 2nd speech, no endpoint
        let flushed = seg.flush()
        XCTAssertEqual(flushed?.count, 2 * W)
        XCTAssertNil(seg.flush())                        // already drained
    }

    func testFlushDiscardsTooShortSegment() {
        var c = cfg(); c.minSpeechMs = 96   // 3 windows
        let seg = VADSegmenter(config: c)
        _ = seg.step(window: win(0.5), isSpeech: true)   // 1 speech window
        XCTAssertNil(seg.flush())                        // < minSpeech -> nil
    }

    func testResetClearsState() {
        let seg = VADSegmenter(config: cfg())
        _ = seg.step(window: win(0.5), isSpeech: true)
        seg.reset()
        XCTAssertNil(seg.flush())
    }

    func testReOnsetAfterDiscardedBlip() {
        // minSpeech = 3 windows, minSilence = 2 windows
        var c = cfg(); c.minSpeechMs = 96; c.minSilenceMs = 64
        let seg = VADSegmenter(config: c)

        // Phase 1: blip (1 speech + 2 silence) — speech count < minSpeech → discard
        _ = seg.step(window: win(0.5), isSpeech: true)   // speech 1 (onset)
        _ = seg.step(window: win(0.0), isSpeech: false)  // silence 1
        XCTAssertEqual(seg.step(window: win(0.0), isSpeech: false), .buffering)  // silence 2 → discard

        // Phase 2: proper segment (3 speech + 2 silence); preBuffer was cleared at first onset
        _ = seg.step(window: win(0.5), isSpeech: true)   // speech 1 (re-onset, no pre-buffer)
        _ = seg.step(window: win(0.5), isSpeech: true)   // speech 2
        _ = seg.step(window: win(0.5), isSpeech: true)   // speech 3
        _ = seg.step(window: win(0.0), isSpeech: false)  // silence 1
        guard case .segment(let samples) = seg.step(window: win(0.0), isSpeech: false) else {
            return XCTFail("expected segment after re-onset")
        }
        // 3 speech + 2 silence = 5 windows (no pre-speech; preBuffer was cleared at first onset)
        XCTAssertEqual(samples.count, 5 * W)
    }

    func testPreSpeechBufferIsCapped() {
        // preSpeechWindows = 2; feed 4 non-speech windows, only last 2 should be kept
        let seg = VADSegmenter(config: cfg())
        _ = seg.step(window: win(0.1), isSpeech: false)  // pre 1 (will be evicted)
        _ = seg.step(window: win(0.2), isSpeech: false)  // pre 2 (will be evicted)
        _ = seg.step(window: win(0.3), isSpeech: false)  // pre 3 (retained as oldest)
        _ = seg.step(window: win(0.4), isSpeech: false)  // pre 4 (retained as newest)
        _ = seg.step(window: win(0.9), isSpeech: true)   // onset; prepends [0.3, 0.4]
        _ = seg.step(window: win(0.0), isSpeech: false)  // silence 1
        guard case .segment(let s) = seg.step(window: win(0.0), isSpeech: false) else {
            return XCTFail("expected segment")
        }
        // 2 pre-speech + 1 onset + 2 silence = 5 windows
        XCTAssertEqual(s.count, 5 * W)
        XCTAssertEqual(Array(s[0 * W ..< 1 * W]), win(0.3))  // first retained pre-speech
        XCTAssertEqual(Array(s[1 * W ..< 2 * W]), win(0.4))  // second retained pre-speech
        XCTAssertEqual(Array(s[2 * W ..< 3 * W]), win(0.9))  // onset window
    }
}
