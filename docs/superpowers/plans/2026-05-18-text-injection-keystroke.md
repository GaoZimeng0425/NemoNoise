# Text Injection Keystroke Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken AX-then-simulated-⌘V text injection fallback with `CGEventKeyboardSetUnicodeString` per-scalar keystroke injection so dictation reliably lands in Electron, web, and terminal targets.

**Architecture:** `TextInjecting` protocol returns a new `InjectionOutcome` enum instead of `Bool`. `TextInjector.inject(_:)` orchestrates: secure-field skip → AX `kAXSelectedTextAttribute` → activate target + poll frontmost ≤ 300 ms → keystroke loop via `CGEventKeyboardSetUnicodeString` on `.privateState` source. `OutputDispatcher` writes clipboard after `inject` and skips clipboard for secure-field outcomes.

**Tech Stack:** Swift 6, SwiftUI 6, ApplicationServices (AX), CoreGraphics (CGEvent), AppKit (NSWorkspace, NSRunningApplication, NSPasteboard), XCTest.

**Spec:** `docs/superpowers/specs/2026-05-18-text-injection-keystroke-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `NemoNoise/Services/Output/TextInjector.swift` | Modify | Defines `InjectionOutcome`, `TextInjecting` protocol, `TextInjector` class with new injection orchestration |
| `NemoNoise/Services/Output/OutputDispatcher.swift` | Modify | Reorders clipboard write after `inject`; switches Toast on outcome |
| `NemoNoise/Services/Sinks/TextInjectorSink.swift` | Modify | Updates to new protocol signature (kept compiling though unused in app paths) |
| `NemoNoiseTests/TextInjectorTests.swift` | Modify | Replaces `injectAX` assertions; adds outcome-specific tests |
| `NemoNoiseTests/TextInjectorSinkTests.swift` | Modify | Updates `StubInjector` and assertions for new protocol |

---

## Task 1: Add `InjectionOutcome` + new protocol method (bridge state)

Goal: introduce the new protocol surface without changing observable behaviour. `inject(_:)` initially delegates to the existing AX-then-⌘V code, returns `.injectedAX` on success and `.failed(reason: "ax_failed")` on failure. Subsequent tasks replace the failure path. Project builds, all existing tests still pass.

**Files:**
- Modify: `NemoNoise/Services/Output/TextInjector.swift`
- Modify: `NemoNoise/Services/Output/OutputDispatcher.swift`
- Modify: `NemoNoise/Services/Sinks/TextInjectorSink.swift`
- Modify: `NemoNoiseTests/TextInjectorTests.swift`
- Modify: `NemoNoiseTests/TextInjectorSinkTests.swift`

- [ ] **Step 1.1: Update `TextInjector.swift` — add enum, new protocol method, bridge implementation**

Replace the entire contents of `NemoNoise/Services/Output/TextInjector.swift` with:

```swift
import AppKit
import ApplicationServices

enum InjectionOutcome: Sendable, Equatable {
    case injectedAX
    case injectedKeystroke
    case skippedSecureField
    case failed(reason: String)
}

protocol TextInjecting: Sendable {
    func captureTarget()
    func inject(_ text: String) async -> InjectionOutcome
}

final class TextInjector: TextInjecting, @unchecked Sendable {
    private var targetElement: AXUIElement?
    private var targetApp: pid_t?

    func captureTarget() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard status == .success, let element = focusedElement else {
            LogService.debug("No focused element captured (AX error: \(status.rawValue))", category: "TextInjection")
            targetElement = nil
            targetApp = nil
            return
        }
        let axElement = unsafeBitCast(element, to: AXUIElement.self)
        targetElement = axElement

        var pid: pid_t = 0
        AXUIElementGetPid(axElement, &pid)
        targetApp = pid
        LogService.debug("Captured target AXUIElement, pid: \(pid)", category: "TextInjection")
    }

    func inject(_ text: String) async -> InjectionOutcome {
        guard let element = targetElement else {
            LogService.info("inject — no captured element", category: "TextInjection")
            return .failed(reason: "no_target")
        }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if status == .success {
            LogService.info("inject — path=AX, len=\(text.count)", category: "TextInjection")
            return .injectedAX
        }
        LogService.info("inject — path=AX failed (status=\(status.rawValue)), bridge returns .failed", category: "TextInjection")
        return .failed(reason: "ax_failed_status_\(status.rawValue)")
    }
}
```

- [ ] **Step 1.2: Update `OutputDispatcher.swift` — switch on outcome (preserve existing clipboard-first ordering for now)**

Replace the entire contents of `NemoNoise/Services/Output/OutputDispatcher.swift` with:

```swift
import AppKit

/// Single chokepoint for the post-transcription side effects: clipboard, history,
/// AX/keystroke injection, and user feedback. Clipboard is written unconditionally
/// here in Task 1; Task 4 reorders so secure-field outcomes skip the clipboard.
@MainActor
enum OutputDispatcher {
    static func dispatch(
        text: String,
        injector: any TextInjecting,
        historyStore: TranscriptHistoryStore,
        engineLabel: String?
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            LogService.info("OutputDispatcher — empty text, nothing to do", category: "Output")
            return
        }

        NSPasteboard.general.clearContents()
        let wrote = NSPasteboard.general.setString(trimmed, forType: .string)
        LogService.info("OutputDispatcher — clipboard wrote=\(wrote), len=\(trimmed.count)", category: "Output")

        historyStore.add(text: trimmed, engineLabel: engineLabel)
        LogService.info("OutputDispatcher — history saved, total=\(historyStore.records.count)", category: "Output")

        let outcome = await injector.inject(trimmed)
        LogService.info("OutputDispatcher — inject outcome=\(outcome)", category: "Output")

        switch outcome {
        case .injectedAX, .injectedKeystroke:
            ToastWindowController.show(
                "Inserted (\(trimmed.count) chars)",
                style: .success,
                duration: 2.5
            )
        case .skippedSecureField:
            ToastWindowController.show(
                "Secure field detected — not auto-typed",
                style: .info,
                duration: 4
            )
        case .failed:
            ToastWindowController.show(
                "Copied to clipboard — press ⌘V to paste",
                style: .info,
                duration: 4
            )
        }
    }
}
```

- [ ] **Step 1.3: Update `TextInjectorSink.swift` to match new protocol**

Replace the entire contents of `NemoNoise/Services/Sinks/TextInjectorSink.swift` with:

```swift
import Foundation

/// Sink that delivers final transcriptions via injection. On failure, falls back to
/// `clipboardFallback` and notifies via `onInjectionFailed`. Currently unused in app
/// paths (OutputDispatcher took over); retained for potential future composition.
final class TextInjectorSink: Sink {
    private let injector: any TextInjecting
    private let clipboardFallback: any Sink
    private let onInjectionFailed: @Sendable () -> Void

    init(
        injector: any TextInjecting,
        clipboardFallback: any Sink,
        onInjectionFailed: @escaping @Sendable () -> Void
    ) {
        self.injector = injector
        self.clipboardFallback = clipboardFallback
        self.onInjectionFailed = onInjectionFailed
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        LogService.info("TextInjectorSink.deliver — isFinal=\(isFinal), textLength=\(result.text.count)", category: "TextInjection")
        guard isFinal, !result.text.isEmpty else {
            LogService.info("TextInjectorSink — skipped (isFinal=\(isFinal), empty=\(result.text.isEmpty))", category: "TextInjection")
            return
        }
        let outcome = await injector.inject(result.text)
        LogService.info("TextInjectorSink — inject outcome=\(outcome)", category: "TextInjection")
        switch outcome {
        case .injectedAX, .injectedKeystroke:
            return
        case .skippedSecureField, .failed:
            LogService.info("TextInjectorSink — entering fallback: writing clipboard + firing onInjectionFailed", category: "TextInjection")
            await clipboardFallback.deliver(result, isFinal: true)
            onInjectionFailed()
        }
    }
}
```

- [ ] **Step 1.4: Update `NemoNoiseTests/TextInjectorTests.swift` for new API**

Replace the entire contents of `NemoNoiseTests/TextInjectorTests.swift` with:

```swift
import XCTest
@testable import NemoNoise

final class TextInjectorTests: XCTestCase {

    func testInjectReturnsFailedWhenNoTarget() async {
        let injector = TextInjector()
        let outcome = await injector.inject("hello world")
        XCTAssertEqual(outcome, .failed(reason: "no_target"))
    }

    func testCaptureTargetWithNoFocusedElement() async {
        let injector = TextInjector()
        injector.captureTarget()
        let outcome = await injector.inject("test")
        if case .failed = outcome {
            // expected — running under XCTest, no focused element
        } else {
            XCTFail("expected .failed when no focused element, got \(outcome)")
        }
    }

    func testInjectEmptyStringWithNoTarget() async {
        let injector = TextInjector()
        let outcome = await injector.inject("")
        XCTAssertEqual(outcome, .failed(reason: "no_target"))
    }
}
```

- [ ] **Step 1.5: Update `NemoNoiseTests/TextInjectorSinkTests.swift` for new protocol**

Replace the entire contents of `NemoNoiseTests/TextInjectorSinkTests.swift` with:

```swift
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
```

- [ ] **Step 1.6: Build and run all tests**

Run:
```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **`. All four `TextInjectorTests` + four `TextInjectorSinkTests` cases pass.

- [ ] **Step 1.7: Commit**

```bash
git add NemoNoise/Services/Output/TextInjector.swift \
        NemoNoise/Services/Output/OutputDispatcher.swift \
        NemoNoise/Services/Sinks/TextInjectorSink.swift \
        NemoNoiseTests/TextInjectorTests.swift \
        NemoNoiseTests/TextInjectorSinkTests.swift
git commit -m "$(cat <<'EOF'
refactor(injection): introduce InjectionOutcome enum + new protocol shape

Bridge state — inject() still uses AX-only path and returns .failed on
miss. Subsequent commits add keystroke fallback, secure-field skip, and
clipboard reordering. No observable behaviour change in this commit.
EOF
)"
```

---

## Task 2: Reorder clipboard write in `OutputDispatcher` (write after inject)

Goal: prepare for secure-field clipboard skip. Move clipboard write to after `inject`. Outcome-specific clipboard skip (for `.skippedSecureField`) lands in Task 3.

**Files:**
- Modify: `NemoNoise/Services/Output/OutputDispatcher.swift`

- [ ] **Step 2.1: Reorder dispatch flow — history first, then inject, then clipboard**

Replace the entire contents of `NemoNoise/Services/Output/OutputDispatcher.swift` with:

```swift
import AppKit

/// Single chokepoint for the post-transcription side effects: history, injection,
/// clipboard, and user feedback. Clipboard write happens after injection so
/// secure-field outcomes (Task 3) can skip pasteboard pollution.
@MainActor
enum OutputDispatcher {
    static func dispatch(
        text: String,
        injector: any TextInjecting,
        historyStore: TranscriptHistoryStore,
        engineLabel: String?
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            LogService.info("OutputDispatcher — empty text, nothing to do", category: "Output")
            return
        }

        // History first — always recorded, regardless of target type.
        historyStore.add(text: trimmed, engineLabel: engineLabel)
        LogService.info("OutputDispatcher — history saved, total=\(historyStore.records.count)", category: "Output")

        // Inject.
        let outcome = await injector.inject(trimmed)
        LogService.info("OutputDispatcher — inject outcome=\(outcome)", category: "Output")

        // Clipboard — written for everything except secure-field skip (Task 3).
        // For now (Task 2), always write to preserve current observable behaviour.
        NSPasteboard.general.clearContents()
        let wrote = NSPasteboard.general.setString(trimmed, forType: .string)
        LogService.info("OutputDispatcher — clipboard wrote=\(wrote), len=\(trimmed.count)", category: "Output")

        // Toast.
        switch outcome {
        case .injectedAX, .injectedKeystroke:
            ToastWindowController.show(
                "Inserted (\(trimmed.count) chars)",
                style: .success,
                duration: 2.5
            )
        case .skippedSecureField:
            ToastWindowController.show(
                "Secure field detected — not auto-typed",
                style: .info,
                duration: 4
            )
        case .failed:
            ToastWindowController.show(
                "Copied to clipboard — press ⌘V to paste",
                style: .info,
                duration: 4
            )
        }
    }
}
```

- [ ] **Step 2.2: Build and run tests**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2.3: Commit**

```bash
git add NemoNoise/Services/Output/OutputDispatcher.swift
git commit -m "$(cat <<'EOF'
refactor(injection): reorder OutputDispatcher — history → inject → clipboard

Prepares for secure-field clipboard skip in the next commit. No
behaviour change yet; clipboard still written unconditionally.
EOF
)"
```

---

## Task 3: Secure-field detection + clipboard skip on secure outcome

Goal: detect `AXSecureTextField` subrole on the captured element and short-circuit `inject` to `.skippedSecureField`. `OutputDispatcher` skips clipboard for that outcome so the transcript does not leak into the pasteboard.

**Files:**
- Modify: `NemoNoise/Services/Output/TextInjector.swift`
- Modify: `NemoNoise/Services/Output/OutputDispatcher.swift`

- [ ] **Step 3.1: Add `isSecureField(_:)` helper and wire into `inject(_:)`**

Update `NemoNoise/Services/Output/TextInjector.swift`. Inside the `TextInjector` class, add the helper at the end:

```swift
    private func isSecureField(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard status == .success, let str = subrole as? String else { return false }
        return str == (kAXSecureTextFieldSubrole as String)
    }
```

Then update the `inject(_:)` method body to check secure-field before AX set. Replace the existing `inject(_:)` method with:

```swift
    func inject(_ text: String) async -> InjectionOutcome {
        guard let element = targetElement else {
            LogService.info("inject — no captured element", category: "TextInjection")
            return .failed(reason: "no_target")
        }

        if isSecureField(element) {
            LogService.info("inject — path=secure_field", category: "TextInjection")
            return .skippedSecureField
        }

        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if status == .success {
            LogService.info("inject — path=AX, len=\(text.count)", category: "TextInjection")
            return .injectedAX
        }
        LogService.info("inject — path=AX failed (status=\(status.rawValue))", category: "TextInjection")
        return .failed(reason: "ax_failed_status_\(status.rawValue)")
    }
```

- [ ] **Step 3.2: Skip clipboard for `.skippedSecureField` in `OutputDispatcher`**

In `NemoNoise/Services/Output/OutputDispatcher.swift`, replace the clipboard block (the `NSPasteboard.general.clearContents() ... LogService.info("OutputDispatcher — clipboard wrote=...")` lines) with:

```swift
        // Clipboard — written for every outcome EXCEPT secure-field skip.
        // Writing the transcript to the pasteboard after a captured password
        // field would leak the password to any clipboard manager.
        if case .skippedSecureField = outcome {
            LogService.info("OutputDispatcher — skipping clipboard write (secure field)", category: "Output")
        } else {
            NSPasteboard.general.clearContents()
            let wrote = NSPasteboard.general.setString(trimmed, forType: .string)
            LogService.info("OutputDispatcher — clipboard wrote=\(wrote), len=\(trimmed.count)", category: "Output")
        }
```

- [ ] **Step 3.3: Build and run tests**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. The existing `TextInjectorTests` still pass (no captured element → `.failed`, not `.skippedSecureField`, because the subrole check requires a real element).

- [ ] **Step 3.4: Commit**

```bash
git add NemoNoise/Services/Output/TextInjector.swift \
        NemoNoise/Services/Output/OutputDispatcher.swift
git commit -m "$(cat <<'EOF'
feat(injection): detect AXSecureTextField and skip pasteboard write

Returns .skippedSecureField before attempting AX set. OutputDispatcher
skips the clipboard write for that outcome so a captured password
field does not leak the transcript to the system pasteboard.

Limit: only Cocoa native secure fields expose AXSecureTextField subrole.
Browser/Electron <input type=password> elements are not detectable via AX.
EOF
)"
```

---

## Task 4: Keystroke injection, frontmost wait, long-text guard

Goal: replace the AX-only failure path with `CGEventKeyboardSetUnicodeString` per-scalar injection. Drop the existing ⌘V simulation completely. Add long-text guard at 5 000 chars and 300 ms activation poll.

**Files:**
- Modify: `NemoNoise/Services/Output/TextInjector.swift`
- Modify: `NemoNoiseTests/TextInjectorTests.swift`

- [ ] **Step 4.1: Write failing test for long-text guard**

Append to `NemoNoiseTests/TextInjectorTests.swift` (inside the existing `final class TextInjectorTests`, before the closing `}`):

```swift
    func testInjectLongTextReturnsFailedWithoutAttempting() async {
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
```

- [ ] **Step 4.2: Run test, verify it fails**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/TextInjectorTests/testInjectLongTextReturnsFailedWithoutAttempting 2>&1 | tail -20
```

Expected: test fails — currently returns `.failed(reason: "no_target")` because the long-text guard does not exist yet.

- [ ] **Step 4.3: Add constants, helpers, and keystroke loop to `TextInjector`**

In `NemoNoise/Services/Output/TextInjector.swift`, add the following private constants and methods inside the `TextInjector` class, after `captureTarget()` and before `inject(_:)`:

```swift
    private static let maxTextLength = 5_000
    private static let charDelayMs = 3
    private static let activationTimeoutMs = 300
    private static let safeVirtualKey: CGKeyCode = 0xCC

    private func waitUntilFrontmost(pid: pid_t) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        app.activate(options: [.activateIgnoringOtherApps])

        let deadline = Date().addingTimeInterval(Double(Self.activationTimeoutMs) / 1000.0)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func postKeystrokes(_ text: String) async {
        let source = CGEventSource(stateID: .privateState)
        for scalar in text.unicodeScalars {
            let utf16 = Array(String(scalar).utf16)

            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.safeVirtualKey, keyDown: true) {
                keyDown.flags = []
                utf16.withUnsafeBufferPointer { buf in
                    keyDown.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                keyDown.post(tap: .cghidEventTap)
            }

            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.safeVirtualKey, keyDown: false) {
                keyUp.flags = []
                utf16.withUnsafeBufferPointer { buf in
                    keyUp.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                keyUp.post(tap: .cghidEventTap)
            }

            try? await Task.sleep(for: .milliseconds(Self.charDelayMs))
        }
    }
```

- [ ] **Step 4.4: Replace `inject(_:)` with full orchestration**

In `NemoNoise/Services/Output/TextInjector.swift`, replace the existing `inject(_:)` method with the full implementation:

```swift
    func inject(_ text: String) async -> InjectionOutcome {
        guard text.count <= Self.maxTextLength else {
            LogService.info("inject — path=failed, reason=text_too_long, len=\(text.count)", category: "TextInjection")
            return .failed(reason: "text_too_long_\(text.count)")
        }

        guard let element = targetElement else {
            LogService.info("inject — path=failed, reason=no_target", category: "TextInjection")
            return .failed(reason: "no_target")
        }

        if isSecureField(element) {
            LogService.info("inject — path=secure_field", category: "TextInjection")
            return .skippedSecureField
        }

        let axStatus = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if axStatus == .success {
            LogService.info("inject — path=AX, len=\(text.count)", category: "TextInjection")
            return .injectedAX
        }
        LogService.info("inject — AX set failed (status=\(axStatus.rawValue)), trying keystroke", category: "TextInjection")

        guard let pid = targetApp else {
            LogService.info("inject — path=failed, reason=no_pid_for_keystroke", category: "TextInjection")
            return .failed(reason: "no_pid_for_keystroke")
        }

        let isFrontmost = await waitUntilFrontmost(pid: pid)
        guard isFrontmost else {
            LogService.info("inject — path=failed, reason=not_frontmost_after_\(Self.activationTimeoutMs)ms, target_pid=\(pid)", category: "TextInjection")
            return .failed(reason: "not_frontmost_after_\(Self.activationTimeoutMs)ms")
        }

        let start = Date()
        await postKeystrokes(text)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        LogService.info("inject — path=keystroke, len=\(text.count), charDelayMs=\(Self.charDelayMs), elapsed=\(elapsedMs)ms", category: "TextInjection")
        return .injectedKeystroke
    }
```

- [ ] **Step 4.5: Run all tests, verify the long-text test passes and others still pass**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. The new `testInjectLongTextReturnsFailedWithoutAttempting` passes; the existing four `TextInjectorTests` and four `TextInjectorSinkTests` still pass.

- [ ] **Step 4.6: Commit**

```bash
git add NemoNoise/Services/Output/TextInjector.swift \
        NemoNoiseTests/TextInjectorTests.swift
git commit -m "$(cat <<'EOF'
feat(injection): keystroke fallback via CGEventKeyboardSetUnicodeString

Replaces the unreliable simulated ⌘V fallback. When AX selectedText
fails (Electron, Chrome, terminals), activates the captured target app,
waits up to 300ms for it to become frontmost, then posts per-Unicode-
scalar keyboard events with the text payload.

Uses .privateState event source to avoid contamination from the user's
held modifier keys. Caps text at 5000 chars; long-text inputs return
.failed and fall back to the clipboard toast.

Fixes the empty-text-field bug in Electron targets (VS Code, Cursor,
Slack, Discord, Notion, WeChat).
EOF
)"
```

---

## Task 5: Manual verification matrix

Goal: confirm each path in the spec's test matrix works in practice. Unit tests do not exercise real CGEvent / AX behaviour — this is the actual verification.

**Files:** none modified.

- [ ] **Step 5.1: Build the app**

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5.2: Launch the app and open Console.app with `category=TextInjection` filter**

Launch the built `.app` from Xcode (⌘R) or from Finder. In Console.app, type `category:TextInjection` in the search bar to filter only injection logs.

- [ ] **Step 5.3: Run through the test matrix**

For each row, place the cursor in the listed target, hold the push-to-talk hotkey, speak a short phrase, release, and verify both the visible result and the Console log line:

| # | Target | Expected outcome | Expected log substring |
|---|---|---|---|
| 1 | TextEdit | Text appears at cursor; Toast `Inserted (N chars)` | `path=AX` |
| 2 | Notes.app | Same as above | `path=AX` |
| 3 | Safari address bar | Same as above | `path=AX` |
| 4 | Cursor or VS Code | Text appears, ~3 ms/char visible; Toast `Inserted (N chars)` | `path=keystroke` |
| 5 | Chrome textarea (Gmail compose) | Text appears; Toast `Inserted (N chars)` | `path=keystroke` |
| 6 | iTerm2 prompt | Text appears at prompt; Toast `Inserted (N chars)` | `path=keystroke` |
| 7 | WeChat compose field | Text appears; Toast `Inserted (N chars)` | `path=keystroke` |
| 8 | A Cocoa native password field (e.g. Keychain Access search-then-add → password field, or any system password prompt) | Nothing typed; Toast `Secure field detected — not auto-typed`; clipboard NOT updated | `path=secure_field` |
| 9 | TextEdit, then immediately ⌘-Tab away during the recording | Text NOT injected; Toast `Copied to clipboard — press ⌘V to paste`; clipboard contains text | `path=failed, reason=not_frontmost` |

- [ ] **Step 5.4: Investigate any deviations**

If any row's actual outcome differs from the expected:
- Check the Console log for the unexpected path (e.g. row 4 shows `path=AX` succeeding in Electron — surprising but acceptable, just note it).
- For genuine failures (e.g. row 4 keystroke produces no text), check:
  - Accessibility permission still granted to the built bundle (rebuild may have invalidated the previous grant — re-add NemoNoise in System Settings → Privacy & Security → Accessibility).
  - The Console shows `elapsed >> charCount × 3ms` — if so, the system is throttling event posting; bump `charDelayMs` from `3` to `5` in `TextInjector.swift:maxTextLength`-area constants and re-test.

- [ ] **Step 5.5: Update the spec with any documented deviations and commit**

If any row's expected behaviour was wrong (e.g. a target the spec said would use `path=AX` actually uses `path=keystroke`), update the spec's test matrix and commit:

```bash
git add docs/superpowers/specs/2026-05-18-text-injection-keystroke-design.md
git commit -m "docs: update test matrix with verified outcomes"
```

If no updates needed, skip the commit and proceed.

---

## Self-Review Notes (executed at plan-write time)

**Spec coverage check:**
- Root-cause description: covered in plan preamble.
- `InjectionOutcome` enum: Task 1.1.
- `TextInjecting` protocol shape: Task 1.1.
- Secure-field check via `kAXSubrole`: Task 3.1.
- AX `kAXSelectedTextAttribute` primary path: Task 3.1 / Task 4.4.
- Activation + 300 ms frontmost poll: Task 4.3 (`waitUntilFrontmost`).
- `CGEventKeyboardSetUnicodeString` per-scalar loop, `.privateState`, safe virtual key `0xCC`, empty flags, UTF-16 surrogate handling: Task 4.3 (`postKeystrokes`).
- 3 ms inter-scalar delay: Task 4.3 (`charDelayMs`).
- 5 000 char guard: Task 4.4 (`maxTextLength`).
- OutputDispatcher reordering: Task 2.1.
- Skip clipboard for secure: Task 3.2.
- Toast mapping: Task 1.2 / Task 2.1 / Task 3.2.
- TextInjectorSink updated: Task 1.3.
- Test updates: Task 1.4, 1.5, 4.1.
- Structured logging: present in every relevant task.
- Manual test matrix: Task 5.3.

**Placeholder scan:** no TBD / TODO / "appropriate error handling" / "similar to Task N" left. Code blocks present for every code step.

**Type / signature consistency:**
- `InjectionOutcome` cases used identically across `TextInjector`, `OutputDispatcher`, `TextInjectorSink`, and tests.
- `inject(_:) async -> InjectionOutcome` signature consistent across protocol, class, stubs.
- Private static constants (`maxTextLength`, `charDelayMs`, `activationTimeoutMs`, `safeVirtualKey`) defined once in Task 4.3 and referenced in Task 4.4.
