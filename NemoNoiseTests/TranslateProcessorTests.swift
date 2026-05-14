import XCTest
@testable import NemoNoise

final class StubTranslationService: TranslationService, @unchecked Sendable {
    var translateCalls: [String] = []
    var resultText: String = "translated"
    var shouldThrow: Error?

    func translate(_ text: String) async throws -> String {
        translateCalls.append(text)
        if let err = shouldThrow { throw err }
        return resultText
    }
}

final class TranslateProcessorTests: XCTestCase {

    func testPartialPassesThroughUnchanged() async throws {
        let service = StubTranslationService()
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "hello", isFinal: false, emotion: nil)

        let out = try await processor.process(input, isFinal: false)
        XCTAssertNil(out, "partial should not be transformed (return nil = passthrough)")
        XCTAssertTrue(service.translateCalls.isEmpty)
    }

    func testFinalTranslates() async throws {
        let service = StubTranslationService()
        service.resultText = "你好"
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "hello", isFinal: true, emotion: nil)

        let out = try await processor.process(input, isFinal: true)
        XCTAssertEqual(out?.text, "你好")
        XCTAssertTrue(out?.isFinal == true)
        XCTAssertEqual(service.translateCalls, ["hello"])
    }

    func testTranslationErrorReturnsOriginalNotNil() async throws {
        let service = StubTranslationService()
        service.shouldThrow = NSError(domain: "translate", code: 1)
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "hello", isFinal: true, emotion: nil)

        let out = try await processor.process(input, isFinal: true)
        XCTAssertEqual(out?.text, "hello", "on translation failure, keep the source text")
    }

    func testEmptyTextSkipsTranslation() async throws {
        let service = StubTranslationService()
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "", isFinal: true, emotion: nil)

        let out = try await processor.process(input, isFinal: true)
        XCTAssertNil(out)
        XCTAssertTrue(service.translateCalls.isEmpty)
    }
}
