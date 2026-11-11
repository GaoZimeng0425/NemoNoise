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
/// `feedChunk` and returns scripted text from `finish()` (FIFO). Conforms to
/// `BiasableDecodeEngine` so prior-context and guard behaviour is observable.
private final class OfflineDecodeSpy: ASREngine, BiasableDecodeEngine, @unchecked Sendable {
    let isStreaming = false
    private(set) var resetCount = 0
    private(set) var fedSegments: [[Float]] = []
    /// One entry per decode cycle: the bias set before it (nil = default).
    private(set) var biasCalls: [String?] = []
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
    func setNextDecodeBias(_ bias: String?) { biasCalls.append(bias) }
}

/// An offline inner engine WITHOUT bias support — guards and prior context
/// must be skipped entirely for such engines (SenseVoice's CTC decoder).
private final class PlainDecodeSpy: ASREngine, @unchecked Sendable {
    let isStreaming = false
    private(set) var fedSegments: [[Float]] = []
    var finishTexts: [String] = []

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        fedSegments.append(samples)
        return TranscriptionResult(text: "", isFinal: false, emotion: nil)
    }
    func finish() async throws -> TranscriptionResult {
        let t = finishTexts.isEmpty ? "" : finishTexts.removeFirst()
        return TranscriptionResult(text: t, isFinal: true, emotion: nil)
    }
    func reset() {}
}

private struct DummyError: Error {}

nonisolated final class VADSegmentingEngineTests: XCTestCase {
    private let W = 512

    /// The test host is the real app: blank the vocabulary so bias/guard
    /// behaviour is deterministic regardless of the user's terms. Call site
    /// owns the snapshot: `let saved = blankVocabulary(); defer { saved.restore() }`.
    @MainActor private func blankVocabulary() -> UserDefaultsSnapshot {
        let saved = UserDefaultsSnapshot([AppDefaults.Keys.vocabularyTerms])
        UserLexicon.save([])
        return saved
    }

    /// minSilence = 2 windows, minSpeech = 1 window, no pre-speech for clean counts.
    @MainActor private func cfg() -> VADConfig {
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
    @MainActor private func samples(_ n: Int) -> [Float] { [Float](repeating: 0.5, count: n * 512) }

    @MainActor func testIsStreamingReportsTrue() {
        // Reports true so the overlay shows the progressive text it now emits,
        // even though the inner engine is offline.
        let engine = VADSegmentingEngine(
            inner: OfflineDecodeSpy(),
            detector: ScriptedDetector([]),
            config: cfg()
        )
        XCTAssertTrue(engine.isStreaming)
    }

    @MainActor func testBufferingReturnsEmptyPartialAndNoDecode() async throws {
        let spy = OfflineDecodeSpy()
        let engine = VADSegmentingEngine(inner: spy, detector: ScriptedDetector([false]), config: cfg())
        let r = try await engine.feedChunk(samples(1), sampleRate: 16000)
        XCTAssertEqual(r.text, "")
        XCTAssertFalse(r.isFinal)
        XCTAssertEqual(spy.fedSegments.count, 0)
    }

    @MainActor func testSegmentCommitDecodesAndEmitsFinal() async throws {
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

    @MainActor func testTwoSegmentsAcrossChunksEmitProgressively() async throws {
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

    @MainActor func testMultipleSegmentsInOneChunkAreJoined() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["A", "B"]
        let detector = ScriptedDetector([true, false, false, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(6), sampleRate: 16000)
        XCTAssertEqual(r.text, "A B")
        XCTAssertTrue(r.isFinal)
    }

    @MainActor func testFinishFlushesTrailingSegment() async throws {
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

    @MainActor func testSegmentDecodeFailureIsSwallowed() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishError = DummyError()
        let detector = ScriptedDetector([true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        // Must NOT throw; the bad segment yields no text, session continues.
        let r = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r.text, "")
        XCTAssertFalse(r.isFinal)
    }

    @MainActor func testResetClearsSegmenterAndInner() async throws {
        let spy = OfflineDecodeSpy()
        let detector = ScriptedDetector([true, true])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())
        _ = try await engine.feedChunk(samples(2), sampleRate: 16000)   // open segment

        engine.reset()
        // After reset, finish() finds no open segment -> empty final.
        let final = try await engine.finish()
        XCTAssertEqual(final.text, "")
    }
    // MARK: - When the segment was spoken

    /// A segment is contiguous audio ending at the window that closed it, so
    /// its start is known exactly — not when the decode happened to finish.
    @MainActor func testSegmentFinalCarriesItsAudioStart() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["你好"]
        // 3 silence, speech, speech, silence, silence -> segment opens at window 3
        let detector = ScriptedDetector([false, false, false, true, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(7), sampleRate: 16000)
        XCTAssertTrue(r.isFinal)
        XCTAssertEqual(r.audioStart ?? -1, Double(3 * W) / 16000, accuracy: 1e-9)
    }

    @MainActor func testSegmentStartCountsAudioFromEarlierChunks() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["A", "B"]
        let detector = ScriptedDetector([true, false, false, false, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        _ = try await engine.feedChunk(samples(4), sampleRate: 16000)
        let r2 = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r2.text, "B")
        XCTAssertEqual(r2.audioStart ?? -1, Double(4 * W) / 16000, accuracy: 1e-9)
    }

    @MainActor func testFlushedSegmentCarriesItsAudioStart() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["尾巴"]
        let detector = ScriptedDetector([false, false, true, true])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        _ = try await engine.feedChunk(samples(4), sampleRate: 16000)
        let final = try await engine.finish()
        XCTAssertEqual(final.text, "尾巴")
        XCTAssertEqual(final.audioStart ?? -1, Double(2 * W) / 16000, accuracy: 1e-9)
    }

    // MARK: - Prior context (cross-segment bias)

    @MainActor func testSecondSegmentDecodeCarriesPriorContext() async throws {
        let saved = blankVocabulary(); defer { saved.restore() }
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["第一段话。", "第二段话。"]
        let detector = ScriptedDetector([true, false, false, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        _ = try await engine.feedChunk(samples(3), sampleRate: 16000)
        _ = try await engine.feedChunk(samples(3), sampleRate: 16000)

        // First decode: no prior, no terms -> default bias (nil).
        // Second decode: the first segment's text is the prior.
        XCTAssertEqual(spy.biasCalls, [nil, "第一段话。"])
        XCTAssertEqual(spy.fedSegments.count, 2)
    }

    @MainActor func testPriorContextIsCappedToItsTail() async throws {
        let saved = blankVocabulary(); defer { saved.restore() }
        let spy = OfflineDecodeSpy()
        let long = String(repeating: "字", count: DecodeBias.priorLimit + 10)
        spy.finishTexts = [long, "尾段。"]
        let detector = ScriptedDetector([true, false, false, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        _ = try await engine.feedChunk(samples(3), sampleRate: 16000)
        _ = try await engine.feedChunk(samples(3), sampleRate: 16000)

        // Second bias = only the last `priorLimit` characters of the prior.
        XCTAssertEqual(spy.biasCalls[1], String(repeating: "字", count: DecodeBias.priorLimit))
    }

    // MARK: - Seam pause stamping

    @MainActor func testFirstSegmentHasNoPauseBefore() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["你好"]
        let detector = ScriptedDetector([true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertNil(r.pauseBefore, "the session's first segment has no seam")
    }

    @MainActor func testSecondSegmentPauseIsTheSilenceBetweenSpeech() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["A", "B"]
        // speech, close(2 silence), 1 extra silence, speech, close → pause = 4 windows
        let detector = ScriptedDetector([true, false, false, false, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        _ = try await engine.feedChunk(samples(3), sampleRate: 16000)
        let r2 = try await engine.feedChunk(samples(4), sampleRate: 16000)
        XCTAssertEqual(r2.pauseBefore ?? -1, Double(4 * W) / 16000, accuracy: 1e-9)
    }

    // MARK: - Seam punctuation in the joined result

    @MainActor func testShortSeamInOneChunkStripsSentenceMark() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["你好。", "走吧。"]
        let detector = ScriptedDetector([true, false, false, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(6), sampleRate: 16000)
        // 3 windows ≈ 96 ms of seam pause < 1.2 s: a breath, not a sentence end.
        XCTAssertEqual(r.text, "你好走吧。")
    }

    @MainActor func testLongSeamInOneChunkKeepsSentenceMark() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["你好。", "走吧。"]
        // seg1 closes at window 3; 37 silent windows; onset at window 41 →
        // pause = 40 windows = 1.28 s ≥ 1.2 s.
        let script = [true, false, false] + [Bool](repeating: false, count: 37) + [true, false, false]
        let detector = ScriptedDetector(script)
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(script.count), sampleRate: 16000)
        XCTAssertEqual(r.text, "你好。走吧。")
    }

    // MARK: - Hallucination guards

    @MainActor func testLexiconDumpGuardReDecodesWithoutTerms() async throws {
        let saved = blankVocabulary(); defer { saved.restore() }
        UserLexicon.save([
            LexiconEntry(term: "Claude Code", weight: 2),
            LexiconEntry(term: "Codex", weight: 2),
            LexiconEntry(term: "blurt", weight: 2),
        ])
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["Claude Code、Codex、blurt", "今天天气不错。"]
        let detector = ScriptedDetector([true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r.text, "今天天气不错。")
        XCTAssertEqual(spy.fedSegments.count, 2, "the same audio is decoded once more")
        XCTAssertEqual(spy.biasCalls.count, 2)
        XCTAssertEqual(spy.biasCalls[0], "Claude Code, Codex, blurt")
        XCTAssertNil(spy.biasCalls[1], "the retry drops the lexicon")
    }

    @MainActor func testLexiconDumpGuardKeepsOriginalWhenRetryStillDumps() async throws {
        let saved = blankVocabulary(); defer { saved.restore() }
        UserLexicon.save([
            LexiconEntry(term: "Claude Code", weight: 2),
            LexiconEntry(term: "Codex", weight: 2),
            LexiconEntry(term: "blurt", weight: 2),
        ])
        let spy = OfflineDecodeSpy()
        let dump = "Claude Code、Codex、blurt"
        spy.finishTexts = [dump, dump]
        let detector = ScriptedDetector([true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r.text, dump, "a retry that still dumps must not replace the text")
    }

    @MainActor func testPriorEchoGuardAcceptsClearlyShorterRetry() async throws {
        let saved = blankVocabulary(); defer { saved.restore() }
        let spy = OfflineDecodeSpy()
        // Segment 2's first decode echoes segment 1 verbatim; the retry hears it.
        spy.finishTexts = ["我今天用了豆包写代码。", "我今天用了豆包写代码。", "再见。"]
        let detector = ScriptedDetector([true, false, false, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(6), sampleRate: 16000)
        // Segment 2's audio is 3 windows ≈ 96 ms — far too short for the
        // 10-character echo of segment 1. The retry is accepted.
        XCTAssertEqual(r.text, "我今天用了豆包写代码再见。")
        XCTAssertEqual(spy.biasCalls.count, 3)
        XCTAssertNil(spy.biasCalls[0])
        XCTAssertEqual(spy.biasCalls[1], "我今天用了豆包写代码。")
        XCTAssertNil(spy.biasCalls[2], "the retry drops the prior")
    }

    @MainActor func testPriorEchoGuardKeepsOriginalWhenRetryNotShorter() async throws {
        let saved = blankVocabulary(); defer { saved.restore() }
        let spy = OfflineDecodeSpy()
        // The retry is as long as the echo (a real repeat): keep the original.
        spy.finishTexts = ["我今天用了豆包写代码。", "我今天用了豆包写代码。", "我今天用了豆包写代码而且很好用。"]
        let detector = ScriptedDetector([true, false, false, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(6), sampleRate: 16000)
        XCTAssertEqual(spy.biasCalls.count, 3, "the echo fired a retry")
        XCTAssertEqual(r.text, "我今天用了豆包写代码我今天用了豆包写代码。",
                       "the echo text itself is kept when the retry is not clearly shorter")
    }

    @MainActor func testGuardsAndBiasSkipNonBiasableInner() async throws {
        let saved = blankVocabulary(); defer { saved.restore() }
        UserLexicon.save([
            LexiconEntry(term: "Claude Code", weight: 2),
            LexiconEntry(term: "Codex", weight: 2),
            LexiconEntry(term: "blurt", weight: 2),
        ])
        let spy = PlainDecodeSpy()
        spy.finishTexts = ["Claude Code、Codex、blurt"]
        let detector = ScriptedDetector([true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r.text, "Claude Code、Codex、blurt")
        XCTAssertEqual(spy.fedSegments.count, 1, "no bias channel → no retry")
    }
}
