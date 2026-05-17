import XCTest
@testable import NemoNoise

@MainActor
final class StubASREngine: ASREngine, @unchecked Sendable {
    var isStreaming: Bool = true
    var markBoundaryCalls: Int = 0

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        TranscriptionResult(text: "", isFinal: false, emotion: nil)
    }
    func finish() async throws -> TranscriptionResult {
        TranscriptionResult(text: "", isFinal: true, emotion: nil)
    }
    func reset() {}
    func markBoundary() { markBoundaryCalls += 1 }
}

final class SentenceSegmenterTests: XCTestCase {

    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _current: Date = Date(timeIntervalSinceReferenceDate: 0)
        var current: Date {
            get { lock.withLock { _current } }
            set { lock.withLock { _current = newValue } }
        }
        var read: @Sendable () -> Date { { [self] in self.current } }
        func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    @MainActor
    private func makeSegmenter(_ clock: FakeClock = FakeClock()) -> (SentenceSegmenter, StubASREngine, FakeClock) {
        let engine = StubASREngine()
        let segmenter = SentenceSegmenter(engine: engine, now: clock.read)
        return (segmenter, engine, clock)
    }

    @MainActor
    func testEmptyResultReturnsNil() async throws {
        let (segmenter, _, _) = makeSegmenter()
        let out = try await segmenter.process(
            TranscriptionResult(text: "", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertNil(out)
    }

    @MainActor
    func testEngineNativeFinalPassesThroughWithSeq() async throws {
        let (segmenter, _, _) = makeSegmenter()
        let input = TranscriptionResult(text: "Hello world.", isFinal: true, emotion: nil)
        let out = try await segmenter.process(input, isFinal: true)
        XCTAssertEqual(out?.text, "Hello world.")
        XCTAssertEqual(out?.isFinal, true)
        XCTAssertEqual(out?.sequence, 1)
    }

    @MainActor
    func testPartialPropagatesUpcomingSeq() async throws {
        let (segmenter, _, _) = makeSegmenter()
        let out = try await segmenter.process(
            TranscriptionResult(text: "hel", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(out?.text, "hel")
        XCTAssertEqual(out?.isFinal, false)
        XCTAssertEqual(out?.sequence, 1, "partial belongs to the next-to-be-emitted seq")
    }

    @MainActor
    func testSentenceEnderForcesSegment() async throws {
        let (segmenter, engine, _) = makeSegmenter()
        _ = try await segmenter.process(
            TranscriptionResult(text: "Hello world", isFinal: false, emotion: nil),
            isFinal: false
        )
        let out = try await segmenter.process(
            TranscriptionResult(text: "Hello world.", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(out?.text, "Hello world.")
        XCTAssertEqual(out?.isFinal, true)
        XCTAssertEqual(out?.sequence, 1)
        XCTAssertEqual(engine.markBoundaryCalls, 1)
    }

    @MainActor
    func testHardLimitForcesSegment() async throws {
        let clock = FakeClock()
        let (segmenter, engine, _) = makeSegmenter(clock)

        _ = try await segmenter.process(
            TranscriptionResult(text: "this is one", isFinal: false, emotion: nil),
            isFinal: false
        )
        clock.advance(6.5)
        let out = try await segmenter.process(
            TranscriptionResult(text: "this is one long sentence with no end", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(out?.isFinal, true, "should force-segment when elapsed > 6s")
        XCTAssertEqual(out?.text, "this is one long sentence with no end")
        XCTAssertEqual(out?.sequence, 1)
        XCTAssertEqual(engine.markBoundaryCalls, 1)
    }

    @MainActor
    func testSilenceForcesSegment() async throws {
        let clock = FakeClock()
        let (segmenter, engine, _) = makeSegmenter(clock)

        _ = try await segmenter.process(
            TranscriptionResult(text: "speaker said something", isFinal: false, emotion: nil),
            isFinal: false
        )
        clock.advance(1.0)
        let out = try await segmenter.process(
            TranscriptionResult(text: "speaker said something", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(out?.isFinal, true)
        XCTAssertEqual(out?.text, "speaker said something")
        XCTAssertEqual(out?.sequence, 1)
        XCTAssertEqual(engine.markBoundaryCalls, 1)
    }

    @MainActor
    func testCursorExcludesConsumedPrefixOnNextPartial() async throws {
        let clock = FakeClock()
        let (segmenter, _, _) = makeSegmenter(clock)

        _ = try await segmenter.process(
            TranscriptionResult(text: "Hello how are you", isFinal: false, emotion: nil),
            isFinal: false
        )
        clock.advance(6.5)
        let first = try await segmenter.process(
            TranscriptionResult(text: "Hello how are you", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(first?.isFinal, true)
        XCTAssertEqual(first?.text, "Hello how are you", "first force-segment emits full delta")

        let next = try await segmenter.process(
            TranscriptionResult(text: "Hello how are you doing today", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(next?.text, " doing today", "delta excludes the consumed prefix")
        XCTAssertEqual(next?.isFinal, false)
        XCTAssertEqual(next?.sequence, 2, "partial belongs to upcoming seq=2")
    }

    @MainActor
    func testEngineFinalResetsCursor() async throws {
        let (segmenter, _, _) = makeSegmenter()

        _ = try await segmenter.process(
            TranscriptionResult(text: "你好世界。", isFinal: true, emotion: nil),
            isFinal: true
        )
        let out = try await segmenter.process(
            TranscriptionResult(text: "下一句开始", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(out?.text, "下一句开始", "cursor was reset by engine-native final")
        XCTAssertEqual(out?.sequence, 2)
    }

    @MainActor
    func testShrinkageResetsCursor() async throws {
        let clock = FakeClock()
        let (segmenter, _, _) = makeSegmenter(clock)

        _ = try await segmenter.process(
            TranscriptionResult(text: "Hello world", isFinal: false, emotion: nil),
            isFinal: false
        )
        clock.advance(6.5)
        _ = try await segmenter.process(
            TranscriptionResult(text: "Hello world", isFinal: false, emotion: nil),
            isFinal: false
        )

        let out = try await segmenter.process(
            TranscriptionResult(text: "Hi", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(out?.text, "Hi", "shrinkage resets cursor; delta = full new text")
        XCTAssertEqual(out?.isFinal, false)
        XCTAssertEqual(out?.sequence, 2)
    }
}
