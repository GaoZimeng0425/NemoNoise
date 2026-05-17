import XCTest
@testable import NemoNoise

@MainActor
final class StubSubtitleWriter: SubtitleWriter {
    var englishText: String = ""
    var partialText: String = ""
    var chineseText: String = ""
    var isTranslating: Bool = false
    var displayedSeq: Int = -1

    private(set) var applyCalls: [(seq: Int, chinese: String)] = []
    func applyTranslation(seq: Int, chinese: String) {
        applyCalls.append((seq, chinese))
        if seq == displayedSeq { chineseText = chinese }
    }
}

final class ControlledTranslationService: TranslationService, @unchecked Sendable {
    enum Response { case success(String); case failure(Error) }
    var nextResponse: Response = .success("translated")
    var observedCalls: [String] = []

    func translate(_ text: String) async throws -> String {
        observedCalls.append(text)
        switch nextResponse {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}

@MainActor
final class AsyncTranslateProcessorTests: XCTestCase {

    func testPartialIsPassthrough() async throws {
        let service = ControlledTranslationService()
        let writer = StubSubtitleWriter()
        let p = AsyncTranslateProcessor(service: service, writer: writer)
        let out = try await p.process(
            TranscriptionResult(text: "hi", isFinal: false, emotion: nil, originalText: nil, sequence: 1),
            isFinal: false
        )
        XCTAssertNil(out)
        XCTAssertTrue(service.observedCalls.isEmpty)
        XCTAssertFalse(writer.isTranslating)
    }

    func testFinalWithoutSeqIsPassthrough() async throws {
        let service = ControlledTranslationService()
        let writer = StubSubtitleWriter()
        let p = AsyncTranslateProcessor(service: service, writer: writer)
        let out = try await p.process(
            TranscriptionResult(text: "dictation", isFinal: true, emotion: nil, originalText: nil, sequence: nil),
            isFinal: true
        )
        XCTAssertNil(out, "seq-less finals pass through (not the translation pipeline)")
        XCTAssertTrue(service.observedCalls.isEmpty)
    }

    func testFinalReturnsEnglishImmediatelyAndSetsIsTranslating() async throws {
        let service = ControlledTranslationService()
        service.nextResponse = .success("你好")
        let writer = StubSubtitleWriter()
        writer.displayedSeq = 1
        let p = AsyncTranslateProcessor(service: service, writer: writer)

        let out = try await p.process(
            TranscriptionResult(text: "Hello", isFinal: true, emotion: nil, originalText: nil, sequence: 1),
            isFinal: true
        )
        XCTAssertEqual(out?.text, "Hello", "english returned synchronously")
        XCTAssertEqual(out?.isFinal, true)
        XCTAssertEqual(out?.sequence, 1)
        XCTAssertTrue(writer.isTranslating, "spawning a translation flips isTranslating true")

        // Yield so the detached Task can complete + hop back to MainActor.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(writer.chineseText, "你好")
        XCTAssertFalse(writer.isTranslating, "inflight clears after success")
        XCTAssertEqual(writer.applyCalls.map(\.seq), [1])
    }

    func testFailureClearsIsTranslatingAndDoesNotWriteChinese() async throws {
        let service = ControlledTranslationService()
        service.nextResponse = .failure(NSError(domain: "t", code: 0))
        let writer = StubSubtitleWriter()
        writer.displayedSeq = 1
        let p = AsyncTranslateProcessor(service: service, writer: writer)

        _ = try await p.process(
            TranscriptionResult(text: "Hello", isFinal: true, emotion: nil, originalText: nil, sequence: 1),
            isFinal: true
        )

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(writer.chineseText, "", "no write on failure")
        XCTAssertFalse(writer.isTranslating, "counter clears on failure")
        XCTAssertTrue(writer.applyCalls.isEmpty)
    }

    func testStaleSeqIsDroppedBySink() async throws {
        let service = ControlledTranslationService()
        service.nextResponse = .success("你好 A")
        let writer = StubSubtitleWriter()
        let p = AsyncTranslateProcessor(service: service, writer: writer)

        writer.displayedSeq = 1
        _ = try await p.process(
            TranscriptionResult(text: "Hello A", isFinal: true, emotion: nil, originalText: nil, sequence: 1),
            isFinal: true
        )
        writer.displayedSeq = 2   // sink moves on before A completes

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(writer.applyCalls.map(\.seq), [1], "called with seq=1")
        XCTAssertEqual(writer.chineseText, "", "writer dropped because seq != displayedSeq")
    }

    func testResetInflightClearsCounterAndIsTranslating() async throws {
        let service = ControlledTranslationService()
        // Configure a slow translation so the task is still in-flight when we reset.
        service.nextResponse = .success("你好")
        let writer = StubSubtitleWriter()
        writer.displayedSeq = 1
        let p = AsyncTranslateProcessor(service: service, writer: writer)

        // Start a translation — inflight goes 0 → 1, isTranslating → true.
        _ = try await p.process(
            TranscriptionResult(text: "Hello", isFinal: true, emotion: nil, originalText: nil, sequence: 1),
            isFinal: true
        )
        XCTAssertTrue(writer.isTranslating, "in-flight after process")

        // Simulate new session: reset.
        p.resetInflight()
        XCTAssertFalse(writer.isTranslating, "resetInflight clears isTranslating")

        // The pending detached Task will eventually complete. Wait for it.
        try await Task.sleep(nanoseconds: 100_000_000)

        // Counter floor at 0 even after the old task's endTranslating decrements
        // — verify isTranslating did NOT go negative or get re-enabled spuriously.
        XCTAssertFalse(writer.isTranslating,
                       "endTranslating from completed old task must not spuriously toggle isTranslating")
    }
}
