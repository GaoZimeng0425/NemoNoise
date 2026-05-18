import XCTest
@testable import NemoNoise

final class TextInjectorSinkTests: XCTestCase {

    func testSuccessfulInjectionDoesNotTriggerFallback() async {
        let injector = StubInjector(outcome: .injectedAX)
        var failureCalled = false
        let sink = TextInjectorSink(
            injector: injector,
            clipboardFallback: TextInjectorSinkRecordingClipboard(),
            onInjectionFailed: { failureCalled = true }
        )

        await sink.deliver(TranscriptionResult(text: "hi", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(injector.injectCalls, ["hi"])
        XCTAssertFalse(failureCalled)
    }

    func testFailedInjectionFallsBackToClipboardAndFiresCallback() async {
        let injector = StubInjector(outcome: .failed(reason: "test"))
        let clipboard = TextInjectorSinkRecordingClipboard()
        var failureCalled = false
        let sink = TextInjectorSink(
            injector: injector,
            clipboardFallback: clipboard,
            onInjectionFailed: { failureCalled = true }
        )

        await sink.deliver(TranscriptionResult(text: "fallback me", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(injector.injectCalls, ["fallback me"])
        XCTAssertEqual(clipboard.delivered, ["fallback me"])
        XCTAssertTrue(failureCalled)
    }

    func testSecureFieldOutcomeAlsoFallsBack() async {
        let injector = StubInjector(outcome: .skippedSecureField)
        let clipboard = TextInjectorSinkRecordingClipboard()
        var failureCalled = false
        let sink = TextInjectorSink(
            injector: injector,
            clipboardFallback: clipboard,
            onInjectionFailed: { failureCalled = true }
        )

        await sink.deliver(TranscriptionResult(text: "pwd", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(clipboard.delivered, ["pwd"])
        XCTAssertTrue(failureCalled)
    }

    func testIgnoresPartialAndEmpty() async {
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
