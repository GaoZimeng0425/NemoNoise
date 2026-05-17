import XCTest
@testable import NemoNoise

final class ParaformerStreamingEngineTests: XCTestCase {

    func testBuildResultAtEndpointAddsPeriodAndMarksFinal() {
        let result = ParaformerStreamingEngine.buildResult(rawText: "hello world", isEndpoint: true)
        XCTAssertTrue(result.isFinal)
        XCTAssertEqual(result.text, "hello world。")
    }

    func testBuildResultAtEndpointWithEmptyTextStaysEmpty() {
        let result = ParaformerStreamingEngine.buildResult(rawText: "", isEndpoint: true)
        XCTAssertTrue(result.isFinal)
        XCTAssertEqual(result.text, "")
    }

    func testBuildResultMidStreamMarksPartial() {
        let result = ParaformerStreamingEngine.buildResult(rawText: "partial", isEndpoint: false)
        XCTAssertFalse(result.isFinal)
        XCTAssertEqual(result.text, "partial")
    }
}
