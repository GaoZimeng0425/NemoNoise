import XCTest
@testable import NemoNoise

nonisolated final class TextInjectorTests: XCTestCase {

    @MainActor func testInjectReturnsFailedWhenNoTarget() async {
        let injector = TextInjector()
        let outcome = await injector.inject("hello world")
        XCTAssertEqual(outcome, .failed(reason: "no_target"))
    }

    // No test for "target captured but no focused element": by design that path
    // goes straight to ⌘V (Electron/WebView targets expose no AX element), so
    // exercising it pastes into whatever app is frontmost and overwrites the
    // user's clipboard.

    @MainActor func testInjectEmptyStringWithNoTarget() async {
        let injector = TextInjector()
        let outcome = await injector.inject("")
        XCTAssertEqual(outcome, .failed(reason: "no_target"))
    }

    @MainActor func testInjectLongTextReturnsFailedWithoutAttempting() async {
        let injector = TextInjector()
        // Long text guard fires before the no_target guard would, so we should
        // get failed(reason: "text_too_long...") even without a captured target.
        let bigText = String(repeating: "x", count: 5001)
        let outcome = await injector.inject(bigText)
        if case .failed(let reason) = outcome {
            XCTAssertTrue(reason.contains("too_long"), "expected too_long reason, got: \(reason)")
        } else {
            XCTFail("expected .failed for 5001-char text, got \(outcome)")
        }
    }

    // MARK: - verify-after-write decision

    @MainActor func testAXWriteChangedDetectsInsertion() {
        // Field value grew → the AX write landed.
        XCTAssertEqual(TextInjector.axWriteChanged(beforeValue: "abc", afterValue: "abchello"), true)
    }

    @MainActor func testAXWriteChangedDetectsSelectionReplacement() {
        // Replacing a selection changes the value even if length differs → landed.
        XCTAssertEqual(TextInjector.axWriteChanged(beforeValue: "selection", afterValue: "x"), true)
    }

    @MainActor func testAXWriteChangedDetectsNoOpOnUnchangedValue() {
        // AX acked .success but value is identical → silent no-op (Safari/terminal).
        XCTAssertEqual(TextInjector.axWriteChanged(beforeValue: "", afterValue: ""), false)
        XCTAssertEqual(TextInjector.axWriteChanged(beforeValue: "foo", afterValue: "foo"), false)
    }

    @MainActor func testAXWriteChangedReturnsNilWhenValueUnreadable() {
        // A failed read on either side is "unknown" — caller must keep status quo
        // (trust the .success) rather than risk a double insert via paste.
        XCTAssertNil(TextInjector.axWriteChanged(beforeValue: nil, afterValue: "foo"))
        XCTAssertNil(TextInjector.axWriteChanged(beforeValue: "foo", afterValue: nil))
        XCTAssertNil(TextInjector.axWriteChanged(beforeValue: nil, afterValue: nil))
    }
}
