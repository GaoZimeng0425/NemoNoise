import XCTest
import os
@testable import NemoNoise

nonisolated final class TextInjectorSinkTests: XCTestCase {

    @MainActor func testSuccessfulInjectionDoesNotTriggerFallback() async {
        let injector = StubInjector(outcome: .injectedAX)
        let failureCalled = OSAllocatedUnfairLock(initialState: false)
        let sink = TextInjectorSink(
            injector: injector,
            clipboardFallback: TextInjectorSinkRecordingClipboard(),
            onInjectionFailed: { failureCalled.withLock { $0 = true } }
        )

        await sink.deliver(TranscriptionResult(text: "hi", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(injector.injectCalls, ["hi"])
        XCTAssertFalse(failureCalled.withLock { $0 })
    }

    @MainActor func testFailedInjectionFallsBackToClipboardAndFiresCallback() async {
        let injector = StubInjector(outcome: .failed(reason: "test"))
        let clipboard = TextInjectorSinkRecordingClipboard()
        let failureCalled = OSAllocatedUnfairLock(initialState: false)
        let sink = TextInjectorSink(
            injector: injector,
            clipboardFallback: clipboard,
            onInjectionFailed: { failureCalled.withLock { $0 = true } }
        )

        await sink.deliver(TranscriptionResult(text: "fallback me", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(injector.injectCalls, ["fallback me"])
        XCTAssertEqual(clipboard.delivered, ["fallback me"])
        XCTAssertTrue(failureCalled.withLock { $0 })
    }

    @MainActor func testSecureFieldOutcomeAlsoFallsBack() async {
        let injector = StubInjector(outcome: .skippedSecureField)
        let clipboard = TextInjectorSinkRecordingClipboard()
        let failureCalled = OSAllocatedUnfairLock(initialState: false)
        let sink = TextInjectorSink(
            injector: injector,
            clipboardFallback: clipboard,
            onInjectionFailed: { failureCalled.withLock { $0 = true } }
        )

        await sink.deliver(TranscriptionResult(text: "pwd", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(clipboard.delivered, ["pwd"])
        XCTAssertTrue(failureCalled.withLock { $0 })
    }

    @MainActor func testIgnoresPartialAndEmpty() async {
        let injector = StubInjector(outcome: .injectedAX)
        let sink = TextInjectorSink(
            injector: injector,
            clipboardFallback: TextInjectorSinkRecordingClipboard(),
            onInjectionFailed: { }
        )

        await sink.deliver(TranscriptionResult(text: "partial", isFinal: false, emotion: nil), isFinal: false)
        await sink.deliver(TranscriptionResult(text: "", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertTrue(injector.injectCalls.isEmpty)
    }
}

// MARK: - Test doubles

final class StubInjector: TextInjecting, @unchecked Sendable {
    private(set) var injectCalls: [String] = []
    private let outcome: InjectionOutcome
    init(outcome: InjectionOutcome) { self.outcome = outcome }
    func captureTarget() {}
    func inject(_ text: String) async -> InjectionOutcome {
        injectCalls.append(text)
        return outcome
    }
}

final class TextInjectorSinkRecordingClipboard: Sink, @unchecked Sendable {
    private(set) var delivered: [String] = []
    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        delivered.append(result.text)
    }
}
