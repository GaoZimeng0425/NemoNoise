import XCTest
@testable import NemoNoise

final class MockASRService: ASREngine {
    var isStreaming: Bool = true
    private(set) var feedChunkCallCount = 0
    private(set) var finishCallCount = 0
    private(set) var resetCallCount = 0
    private(set) var lastFeedSamples: [Float]?
    private(set) var lastFeedSampleRate: Int?

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        feedChunkCallCount += 1
        lastFeedSamples = samples
        lastFeedSampleRate = sampleRate
        return TranscriptionResult(text: "mock partial", isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        finishCallCount += 1
        return TranscriptionResult(text: "mock final", isFinal: true, emotion: "neutral")
    }

    func reset() {
        resetCallCount += 1
    }
}

final class ASREngineMockTests: XCTestCase {

    func testMockConformsToProtocol() {
        let mock: any ASREngine = MockASRService()
        XCTAssertTrue(mock.isStreaming)
    }

    func testIsStreamingProperty() {
        let streamingMock = MockASRService()
        streamingMock.isStreaming = true
        XCTAssertTrue(streamingMock.isStreaming)

        let nonStreamingMock = MockASRService()
        nonStreamingMock.isStreaming = false
        XCTAssertFalse(nonStreamingMock.isStreaming)
    }

    func testFeedChunkReturnsResult() async throws {
        let mock = MockASRService()
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        let result = try await mock.feedChunk(samples, sampleRate: 16000)
        XCTAssertEqual(result.text, "mock partial")
        XCTAssertFalse(result.isFinal)
        XCTAssertEqual(mock.feedChunkCallCount, 1)
        XCTAssertEqual(mock.lastFeedSamples, samples)
        XCTAssertEqual(mock.lastFeedSampleRate, 16000)
    }

    func testFinishReturnsFinalResult() async throws {
        let mock = MockASRService()
        let result = try await mock.finish()
        XCTAssertEqual(result.text, "mock final")
        XCTAssertTrue(result.isFinal)
        XCTAssertEqual(result.emotion, "neutral")
        XCTAssertEqual(mock.finishCallCount, 1)
    }

    func testReset() {
        let mock = MockASRService()
        mock.reset()
        XCTAssertEqual(mock.resetCallCount, 1)
    }

    func testMultipleFeedChunks() async throws {
        let mock = MockASRService()
        _ = try await mock.feedChunk([0.1], sampleRate: 16000)
        _ = try await mock.feedChunk([0.2], sampleRate: 16000)
        _ = try await mock.feedChunk([0.3], sampleRate: 16000)
        XCTAssertEqual(mock.feedChunkCallCount, 3)
    }
}

final class ShouldTranslateTests: XCTestCase {

    private let controller = TranslationController()

    func testPureEnglishText() {
        XCTAssertTrue(controller.shouldTranslate("Hello world this is a test"))
    }

    func testPureChineseText() {
        XCTAssertFalse(controller.shouldTranslate("你好世界这是一个测试"))
    }

    func testMixedMostlyEnglish() {
        XCTAssertTrue(controller.shouldTranslate("Hello 你好 world"))
    }

    func testMixedMostlyChinese() {
        XCTAssertFalse(controller.shouldTranslate("你好世界这是一个测试 hello"))
    }

    func testEmptyString() {
        XCTAssertFalse(controller.shouldTranslate(""))
    }

    func testNumbersOnly() {
        XCTAssertFalse(controller.shouldTranslate("12345"))
    }

    func testSingleEnglishWord() {
        XCTAssertTrue(controller.shouldTranslate("Hello"))
    }

    func testSingleChineseWord() {
        XCTAssertFalse(controller.shouldTranslate("你好"))
    }
}
