import XCTest
@testable import NemoNoise

/// `TranscriptTidy.tidy` as the last text step of every pipeline. From the
/// 2026-11-09 device meeting: with `.fastResults` the Apple engine committed a
/// sentence before knowing it had ended, and its period came out at the start
/// of the next line ("。记住它靠…"), plus "回来 ，直到".
nonisolated final class TranscriptTidyProcessorTests: XCTestCase {

    @MainActor func testFinalLosesLeadingPeriodAndSpaceBeforeComma() async throws {
        let out = try await TranscriptTidyProcessor().process(
            TranscriptionResult(text: "。记住它会一直回来 ，直到你真的会", isFinal: true, emotion: nil),
            isFinal: true)
        XCTAssertEqual(out?.text, "记住它会一直回来，直到你真的会")
        XCTAssertEqual(out?.isFinal, true)
    }

    @MainActor func testPartialIsCleanedToo() async throws {
        let out = try await TranscriptTidyProcessor().process(
            TranscriptionResult(text: "。记住", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(out?.text, "记住")
        XCTAssertEqual(out?.isFinal, false)
    }

    @MainActor func testOtherFieldsSurvive() async throws {
        let spoken = Date(timeIntervalSinceReferenceDate: 42)
        let input = TranscriptionResult(text: "，你好", isFinal: true, emotion: "joy", originalText: "hello",
                                        sequence: 7, audioStart: 1.5, spokenAt: spoken)
        let processed = try await TranscriptTidyProcessor().process(input, isFinal: true)
        let out = try XCTUnwrap(processed)
        XCTAssertEqual(out.text, "你好")
        XCTAssertEqual(out.emotion, "joy")
        XCTAssertEqual(out.originalText, "hello")
        XCTAssertEqual(out.sequence, 7)
        XCTAssertEqual(out.audioStart, 1.5)
        XCTAssertEqual(out.spokenAt, spoken)
    }

    /// Punctuation-only output is nothing heard; sinks already skip empty text.
    @MainActor func testPunctuationOnlyBecomesEmpty() async throws {
        let out = try await TranscriptTidyProcessor().process(
            TranscriptionResult(text: "。。", isFinal: true, emotion: nil), isFinal: true)
        XCTAssertEqual(out?.text, "")
    }

    @MainActor func testCleanTextPassesThrough() async throws {
        let out = try await TranscriptTidyProcessor().process(
            TranscriptionResult(text: "我们周四上线。", isFinal: true, emotion: nil), isFinal: true)
        XCTAssertNil(out, "unchanged text passes through untouched")
    }
}
