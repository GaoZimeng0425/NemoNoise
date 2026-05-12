import XCTest
@testable import NemoNoise

final class SpeechOrchestratorTests: XCTestCase {

    func testIsStreamingDefaultsToTrue() {
        let orchestrator = SpeechOrchestrator(modelManager: ModelManager())
        XCTAssertTrue(orchestrator.isStreaming)
    }

    func testFinalizeReturnsEmptyWhenNoEngine() async throws {
        let orchestrator = SpeechOrchestrator(modelManager: ModelManager())
        let result = try await orchestrator.finalize()
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.isFinal)
        XCTAssertNil(result.emotion)
    }

    func testStopIsSafeWithoutEngine() {
        let orchestrator = SpeechOrchestrator(modelManager: ModelManager())
        orchestrator.stop()
        XCTAssertTrue(orchestrator.isStreaming)
    }

    func testEngineFallbackCallbackNotSetByDefault() {
        let orchestrator = SpeechOrchestrator(modelManager: ModelManager())
        XCTAssertNil(orchestrator.onEngineFallback)
    }

    func testEngineFallbackCallbackCanBeSet() {
        let orchestrator = SpeechOrchestrator(modelManager: ModelManager())
        orchestrator.onEngineFallback = { _ in }
        XCTAssertNotNil(orchestrator.onEngineFallback)
    }

    func testFinalizeAfterStopReturnsEmpty() async throws {
        let orchestrator = SpeechOrchestrator(modelManager: ModelManager())
        orchestrator.stop()
        let result = try await orchestrator.finalize()
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.isFinal)
    }
}
