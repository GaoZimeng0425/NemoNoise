import XCTest
@testable import NemoNoise

/// Assembly rules for the live (meeting / translation) pipelines, from the
/// 2026-11-09 device meeting: the Them track printed "。。" / "，，" because the
/// CT-Transformer re-punctuated the self-punctuating Apple engine.
nonisolated final class LiveAssemblyTests: XCTestCase {

    nonisolated private final class PunctEngine: ASREngine, @unchecked Sendable {
        let emitsPunctuation: Bool
        init(emits: Bool) { emitsPunctuation = emits }
        func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
            TranscriptionResult(text: "", isFinal: false, emotion: nil)
        }
        func finish() async throws -> TranscriptionResult { TranscriptionResult(text: "", isFinal: true, emotion: nil) }
        func reset() {}
    }

    // MARK: - Punctuation

    @MainActor func testSelfPunctuatingEngineGetsNoPunctuator() {
        XCTAssertNil(PipelineProvider.punctuator(for: PunctEngine(emits: true), from: "ct-transformer"))
    }

    @MainActor func testRawEngineGetsThePunctuator() {
        XCTAssertEqual(PipelineProvider.punctuator(for: PunctEngine(emits: false), from: "ct-transformer"),
                       "ct-transformer")
    }

    @MainActor func testNoPunctuatorLoadedMeansNone() {
        XCTAssertNil(PipelineProvider.punctuator(for: PunctEngine(emits: false), from: String?.none))
    }
}
