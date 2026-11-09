import XCTest
@testable import NemoNoise

nonisolated final class ParaformerStreamingEngineTests: XCTestCase {

    @MainActor func testBuildResultAtEndpointMarksFinalWithoutAddingPunctuation() {
        let result = ParaformerStreamingEngine.buildResult(rawText: "hello world", isEndpoint: true)
        XCTAssertTrue(result.isFinal)
        // Punctuation is PunctuationProcessor's job downstream; the engine must not add "。".
        XCTAssertEqual(result.text, "hello world")
    }

    @MainActor func testBuildResultAtEndpointWithEmptyTextStaysEmpty() {
        let result = ParaformerStreamingEngine.buildResult(rawText: "", isEndpoint: true)
        XCTAssertTrue(result.isFinal)
        XCTAssertEqual(result.text, "")
    }

    @MainActor func testBuildResultMidStreamMarksPartial() {
        let result = ParaformerStreamingEngine.buildResult(rawText: "partial", isEndpoint: false)
        XCTAssertFalse(result.isFinal)
        XCTAssertEqual(result.text, "partial")
    }
}
