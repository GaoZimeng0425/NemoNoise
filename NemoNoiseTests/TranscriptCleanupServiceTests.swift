import XCTest
import os
@testable import NemoNoise

/// Exercises the TranscriptCleanupService guard stack with an injected fake
/// model — no Apple Intelligence needed. Contract under test: every failure
/// or suspicious output returns nil (keep the original transcript).
nonisolated final class TranscriptCleanupServiceTests: XCTestCase {

    private func makeService(responder: @escaping @Sendable (String) async throws -> String,
                             watchdog: Double = 10) -> TranscriptCleanupService {
        TranscriptCleanupService(responder: responder, watchdogSeconds: watchdog)
    }

    @MainActor func testLightCleanupPasses() async {
        let service = makeService { input in
            input.replacingOccurrences(of: "嗯", with: "")
        }
        let cleaned = await service.cleanup("今天嗯开个会")
        XCTAssertEqual(cleaned, "今天开个会")
    }

    @MainActor func testModelFailureKeepsOriginal() async {
        struct Boom: Error {}
        let service = makeService { _ in throw Boom() }
        let cleaned = await service.cleanup("hello world transcript")
        XCTAssertNil(cleaned)
    }

    @MainActor func testWatchdogTimeoutKeepsOriginal() async {
        let service = makeService(responder: { _ in
            try await Task.sleep(for: .seconds(5))
            return "never happens"
        }, watchdog: 0.2)
        let cleaned = await service.cleanup("some transcript words here")
        XCTAssertNil(cleaned)
    }

    @MainActor func testHallucinatedAnswerRejectedByExpansion() async {
        // Input is a question; the model "helpfully" answers it with new
        // content far longer than the input.
        let service = makeService { _ in
            "好的,我很乐意帮您查询当前的时间信息,请稍等片刻即可获得准确的结果"
        }
        let cleaned = await service.cleanup("现在几点了")
        XCTAssertNil(cleaned)
    }

    @MainActor func testLowFidelityOutputRejected() async {
        // Similar length, but almost no content overlap — the model responded
        // instead of cleaning.
        let service = makeService { _ in
            "let us schedule the gathering today"
        }
        let cleaned = await service.cleanup("meeting notes tomorrow")
        XCTAssertNil(cleaned)
    }

    @MainActor func testShortInputExpansionCap() async {
        let service = makeService { _ in "这是一段完全新造出来的句子" }
        let cleaned = await service.cleanup("好的")
        XCTAssertNil(cleaned)
    }

    @MainActor func testEchoedTagsAreStripped() async {
        let service = makeService { input in
            "<transcript>\n\(input.replacingOccurrences(of: "uh ", with: ""))\n</transcript>"
        }
        let cleaned = await service.cleanup("uh hello world there")
        XCTAssertEqual(cleaned, "hello world there")
    }

    @MainActor func testWrappingQuotesAreStripped() async {
        let service = makeService { input in
            "\"\(input.replacingOccurrences(of: "um ", with: ""))\""
        }
        let cleaned = await service.cleanup("um hello world there")
        XCTAssertEqual(cleaned, "hello world there")
    }

    @MainActor func testEmptyOutputKeepsOriginal() async {
        let service = makeService { _ in "   \n  " }
        let cleaned = await service.cleanup("real transcript text")
        XCTAssertNil(cleaned)
    }

    @MainActor func testTooLongInputSkippedWithoutCallingModel() async {
        let called = OSAllocatedUnfairLock<Bool>(initialState: false)
        let service = makeService { _ in
            called.withLock { $0 = true }
            return "nope"
        }
        let long = String(repeating: "字", count: 6001)
        let cleaned = await service.cleanup(long)
        XCTAssertNil(cleaned)
        XCTAssertFalse(called.withLock { $0 })
    }

    @MainActor func testTinyInputSkipped() async {
        let called = OSAllocatedUnfairLock<Bool>(initialState: false)
        let service = makeService { _ in
            called.withLock { $0 = true }
            return "nope"
        }
        let cleaned = await service.cleanup("好")
        XCTAssertNil(cleaned)
        XCTAssertFalse(called.withLock { $0 })
    }

    // MARK: - Pure helpers

    func testSanitizeStripsTagsAndQuotes() {
        XCTAssertEqual(TranscriptCleanupService.sanitize("<transcript>abc</transcript>"), "abc")
        XCTAssertEqual(TranscriptCleanupService.sanitize("“你好”"), "你好")
        XCTAssertEqual(TranscriptCleanupService.sanitize("  plain  "), "plain")
    }

    func testPassesGuardsAcceptsFaithfulEdit() {
        XCTAssertTrue(TranscriptCleanupService.passesGuards(
            input: "今天嗯开个会",
            output: "今天开个会"
        ))
    }

    func testPassesGuardsRejectsEnglishPreamble() {
        // Classic prompt leakage: preamble words are not in the input, and the
        // expansion stays under the cap so ONLY the fidelity check rejects it.
        XCTAssertFalse(TranscriptCleanupService.passesGuards(
            input: "fix this sentence now please carefully",
            output: "Here is the cleaned transcript: fix this sentence"
        ))
    }
}
