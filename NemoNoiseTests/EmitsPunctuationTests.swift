import XCTest
@testable import NemoNoise

/// An engine whose `emitsPunctuation` capability is controllable, for testing
/// that the decorator delegates the flag to its inner engine.
private final class PunctCapabilitySpy: ASREngine, @unchecked Sendable {
    let isStreaming = false
    private let emits: Bool
    init(emits: Bool) { self.emits = emits }
    var emitsPunctuation: Bool { emits }
    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        TranscriptionResult(text: "", isFinal: false, emotion: nil)
    }
    func finish() async throws -> TranscriptionResult {
        TranscriptionResult(text: "", isFinal: true, emotion: nil)
    }
    func reset() {}
}

private final class StubDetector: VADSpeechDetector {
    let windowSize = 512
    func isSpeech(_ window: [Float]) -> Bool { false }
    func reset() {}
}

final class EmitsPunctuationTests: XCTestCase {
    /// Engines that don't override the flag default to "needs punctuation".
    func testDefaultIsFalse() {
        // MockASREngine (in ASREngineMockTests) does not override emitsPunctuation.
        XCTAssertFalse(MockASREngine().emitsPunctuation)
    }

    /// The segmenting decorator must report its inner engine's capability, so
    /// PipelineProvider can decide whether to attach the CT-Transformer based on
    /// the wrapped offline engine.
    func testVADSegmentingEngineDelegatesToInner() {
        let wrapsSelfPunctuating = VADSegmentingEngine(inner: PunctCapabilitySpy(emits: true), detector: StubDetector())
        XCTAssertTrue(wrapsSelfPunctuating.emitsPunctuation)

        let wrapsRawEngine = VADSegmentingEngine(inner: PunctCapabilitySpy(emits: false), detector: StubDetector())
        XCTAssertFalse(wrapsRawEngine.emitsPunctuation)
    }
}
