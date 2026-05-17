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

    func testFinalPopulatesOriginalText() async throws {
        let service = StubTranslationService()
        service.resultText = "你好"
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "hello", isFinal: true, emotion: "joy")

        let out = try await processor.process(input, isFinal: true)
        XCTAssertEqual(out?.originalText, "hello",
                       "successful translation must preserve the source in originalText")
        XCTAssertEqual(out?.emotion, "joy", "emotion must survive the processor")
    }

    func testTranslationErrorReturnsOriginalNotNil() async throws {
        let service = StubTranslationService()
        service.shouldThrow = NSError(domain: "translate", code: 1)
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "hello", isFinal: true, emotion: nil)

        let out = try await processor.process(input, isFinal: true)
        XCTAssertEqual(out?.text, "hello", "on failure, keep the source text as the primary text")
    }

    func testFailureLeavesOriginalTextNil() async throws {
        let service = StubTranslationService()
        service.shouldThrow = NSError(domain: "translate", code: 1)
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "hello", isFinal: true, emotion: nil)

        let out = try await processor.process(input, isFinal: true)
        XCTAssertNil(out?.originalText,
                     "on failure, originalText must be nil so the sink treats this as un-translated")
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
