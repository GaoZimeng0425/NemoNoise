# Text Injection — Keystroke Path Design

**Date:** 2026-05-18
**Status:** Spec — awaiting implementation plan
**Touches:** `Services/Output/TextInjector.swift`, `Services/Output/OutputDispatcher.swift`, `Services/Sinks/TextInjectorSink.swift`, tests

## Problem

After successful ASR, the final transcript reliably reaches the clipboard but does not appear inside the user's target text field when the target is an Electron app (VS Code, Cursor, Slack, Discord, Notion, WeChat). The user sees the Toast `Copied to clipboard — press ⌘V to paste` instead of `Inserted (N chars)`.

### Root cause

Two layered failures in `TextInjector.injectAX`:

1. **`kAXSelectedTextAttribute` is unsupported by Electron's Chromium text system.** The `AXUIElementSetAttributeValue(…, kAXSelectedTextAttribute, …)` call returns a non-success status for every Electron target. This is a known Electron / macOS gap, not a NemoNoise bug.

2. **The ⌘V fallback after AX failure is unreliable.** The current fallback (`TextInjector.swift:54-71`) tries to bring the target app to the front with `app.activate(options: [])` then sleeps 50 ms before posting a CGEvent ⌘V keystroke. On macOS 14+, `activate` with empty options frequently fails to make the target frontmost, and 50 ms is below the actual activation latency. The CGEvent then arrives at whatever app actually holds focus — often NemoNoise itself or the previous frontmost — and the ⌘V is silently consumed by the wrong target.

A secondary cost of the ⌘V fallback (orthogonal to the bug): it hijacks the user's clipboard. Even when ⌘V succeeds, the user loses whatever they had previously copied.

## Market survey (2026)

Leading macOS dictation apps converge on **`CGEventKeyboardSetUnicodeString` character-by-character injection** as the primary path:

| Approach | Used by | Electron support | Touches clipboard |
|---|---|---|---|
| `CGEventKeyboardSetUnicodeString` | Wispr Flow, Superwhisper (Type mode), Aqua Voice | ≈ 95 % | No |
| AX `kAXSelectedTextAttribute` → ⌘V | MacWhisper, Spokenly, Whispo, current NemoNoise | Depends on activation timing | Yes |
| AX `kAXValueAttribute` substring replace | Older AX patterns | Same Electron gap | No |
| User-selectable Type / Paste mode | Superwhisper | Configurable | Configurable |

Keystroke injection wins because each character is delivered as a HID-tap event carrying a Unicode payload that Cocoa, Chromium, terminals, and JetBrains all consume as text. It bypasses AX (so Electron is reachable), bypasses the clipboard (no hijack), and bypasses IMEs (the ASR output is already the final string, no pinyin pass needed).

## Decision

Replace the current `AX → ⌘V fallback` path with `AX → keystroke fallback`. Drop the simulated ⌘V entirely.

New injection order inside `TextInjector.inject(_:)`:

1. If `targetElement` has `kAXSubrole == AXSecureTextField` → return `.skippedSecureField` (do not write clipboard either)
2. Try `AXUIElementSetAttributeValue(…, kAXSelectedTextAttribute, …)` → if success, return `.injectedAX`
3. Activate `targetApp` and poll up to 300 ms for `NSWorkspace.frontmostApplication.processIdentifier == targetApp` → if timeout, return `.failed(reason:)`
4. For each `Unicode.Scalar` in text, post a `keyDown`/`keyUp` pair via `CGEventKeyboardSetUnicodeString` on `.cghidEventTap`, with 3 ms delay between scalars → return `.injectedKeystroke`

`OutputDispatcher` keeps its current shape — write clipboard, write history, call `inject`, show Toast — but switches the Toast on the new outcome enum.

## Architecture

### Protocol shape

```swift
// Services/Output/TextInjector.swift

enum InjectionOutcome: Sendable {
    case injectedAX            // AX kAXSelectedTextAttribute succeeded
    case injectedKeystroke     // CGEventKeyboardSetUnicodeString succeeded
    case skippedSecureField    // detected AXSecureTextField, deliberately did not inject
    case failed(reason: String) // both paths failed — caller must surface clipboard fallback
}

protocol TextInjecting: Sendable {
    func captureTarget()
    func inject(_ text: String) async -> InjectionOutcome
}
```

The old `injectAX(_:) async -> Bool` method is removed. `captureTarget()` is unchanged.

### Keystroke implementation details

```swift
private let charDelayMs: Int = 3
private let SAFE_VIRTUAL_KEY: CGKeyCode = 0xCC  // unused keycode; safe guard against payload-drop

let source = CGEventSource(stateID: .privateState)

for scalar in text.unicodeScalars {
    let utf16 = Array(String(scalar).utf16)

    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: SAFE_VIRTUAL_KEY, keyDown: true)
    keyDown?.flags = []
    keyDown?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    keyDown?.post(tap: .cghidEventTap)

    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: SAFE_VIRTUAL_KEY, keyDown: false)
    keyUp?.flags = []
    keyUp?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    keyUp?.post(tap: .cghidEventTap)

    try? await Task.sleep(for: .milliseconds(charDelayMs))
}
```

Key choices and the reason for each:

- **`.privateState`** event source, not the current `.hidSystemState`. A private state means the injected events are not contaminated by whatever modifier keys the user happens to be holding. With `.hidSystemState`, an inadvertent Shift hold during recording can capitalise injected characters; an inadvertent Cmd hold can turn injected letters into command combinations.
- **Safe virtual keycode `0xCC`** (unassigned). If `keyboardSetUnicodeString` is ignored downstream for any reason, a `0xCC` keypress is a no-op rather than an unexpected character.
- **`flags = []`** on both events to clear any inherited modifier state.
- **Iterate `unicodeScalars`, not `Character`s.** Emoji and CJK ideographs that involve modifier scalars (skin tone, ZWJ sequences) decompose cleanly per scalar. Each scalar's UTF-16 representation handles surrogate pairs naturally.
- **3 ms inter-scalar delay.** Below 2 ms, Electron drops events under load. Above 10 ms, users feel typing lag. 3 ms keeps 500-char utterances under 1.5 s.
- **`.cghidEventTap`** posting tap (matches existing code, lowest-level injection point).

### Activation + frontmost wait

```swift
guard let pid = targetApp,
      let app = NSRunningApplication(processIdentifier: pid) else {
    return .failed(reason: "no target pid")
}

app.activate(options: [.activateIgnoringOtherApps])

let deadline = Date().addingTimeInterval(0.3)
while Date() < deadline {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
        break
    }
    try? await Task.sleep(for: .milliseconds(20))
}

guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
    return .failed(reason: "target not frontmost after 300ms")
}
```

This replaces the current two fixed 50 ms sleeps. The poll cap of 300 ms is an empirical ceiling — if activation has not completed by then, the user has likely switched apps or the system is overloaded, and injecting into whatever is now frontmost is worse than failing into the clipboard path.

`.activateIgnoringOtherApps` is technically deprecated on macOS 14+ in favour of parameterless `activate()`, but both behaviours are equivalent in our context. The deprecated form is used to keep behaviour identical across the macOS versions we support.

### `OutputDispatcher` adjustments

```swift
let outcome = await injector.inject(trimmed)
LogService.info("OutputDispatcher — inject outcome=\(outcome)", category: "Output")

switch outcome {
case .injectedAX, .injectedKeystroke:
    ToastWindowController.show("Inserted (\(trimmed.count) chars)", style: .success, duration: 2.5)
case .skippedSecureField:
    ToastWindowController.show("Secure field detected — not auto-typed", style: .info, duration: 4)
case .failed:
    ToastWindowController.show("Copied to clipboard — press ⌘V to paste", style: .info, duration: 4)
}
```

**Ordering change.** Clipboard write moves from before `inject` to after, gated on outcome. The new dispatcher flow:

1. History save — always (record-keeping inside the app is acceptable regardless of target type)
2. `inject` — get outcome
3. Clipboard write — only when outcome is `.injectedAX`, `.injectedKeystroke`, or `.failed`. **Skipped for `.skippedSecureField`** so a captured password-field target produces zero transcript persistence outside the in-app history
4. Toast — switch on outcome as above

This is a behavioural change from the current dispatcher, which writes the clipboard unconditionally before injecting. The reason: writing first means we cannot retract on secure-field detection, and leaving the password in the system pasteboard is the failure mode users care about most.

## Edge cases

### Secure-field detection limit

`kAXSubrole == AXSecureTextField` is only set by Cocoa native password fields. Browser and Electron `<input type=password>` elements have no AX subrole exposing their secure status. Every dictation app on the market has the same limit; the spec accepts it. The 1Password / KeePass etc. native apps are covered because they use Cocoa secure fields.

### Long text

Hard upper bound of 5 000 characters:

```swift
guard text.count <= 5000 else {
    return .failed(reason: "text too long (\(text.count) chars)")
}
```

This caps worst-case injection time at ~15 s. Beyond that, falling back to clipboard is more respectful of the user's time. Normal dictation utterances are well under 200 characters, so the cap is a guardrail against pathological inputs, not a routine path.

### Mid-injection target switch

No cancellation token. If the user switches apps while keystroke injection is in flight, the remainder lands in the new frontmost app. This is annoying but not catastrophic. Adding cancellation requires polling `NSWorkspace.frontmostApplication` between every scalar (cheap but noisy) and provides no rollback for already-injected characters. Deferred to a future iteration if user reports surface this as a real-world problem.

### IME state

`CGEventKeyboardSetUnicodeString` payloads bypass IMEs in Cocoa. The ASR output is the final string, so this is the desired behaviour. A rare class of Electron apps with custom IME bridges may misinterpret the events (e.g. show "nihao" instead of "你好"). This is the target app's bug, not addressable from our side, and is documented as a known limit.

### AX permission revoked mid-session

Both the AX set call and the CGEvent post require the same Accessibility permission. If the user revokes mid-session, both paths fail — `inject` returns `.failed`. The existing `AccessibilityAlert` flow handles re-prompting; nothing new is needed here.

## Testing

### Manual test matrix (pre-release)

| Target | Expected outcome | Verification |
|---|---|---|
| TextEdit | `injectedAX` | Text at cursor, Toast `Inserted (N chars)` |
| Notes | `injectedAX` | Text at cursor |
| Safari address bar | `injectedAX` | Text at cursor |
| Cursor / VS Code | `injectedKeystroke` | Text at cursor, ~3 ms/char visible but tolerable |
| Chrome textarea (Gmail) | `injectedKeystroke` | Text at cursor |
| iTerm2 | `injectedKeystroke` | Text at shell prompt |
| WeChat (new) | `injectedKeystroke` | Text in compose field |
| Safari `<input type=password>` | `injectedKeystroke` (subrole undetectable) | Text appears (documented limit) |
| Lock screen between record and inject | `failed: not frontmost` | Toast "Copied to clipboard" |

Filter Console.app on `category=TextInjection` to verify the decision path matches the expected outcome.

### Unit tests

Test the protocol surface and decision boundaries, not real system calls.

```swift
// NemoNoiseTests/TextInjectorTests.swift
final class TextInjectorOutcomeTests: XCTestCase {
    func test_emptyText_doesNothing() async { … }
    func test_longText_returnsFailed() async { … }
    func test_secureField_returnsSkipped() async { … }
    func test_unicodeScalars_emoji_handlesSurrogatePair() { /* string decomposition only */ }
}
```

CGEvent post behaviour, AX system status, and frontmost polling are not unit-tested — they require real OS state and are covered by the manual matrix.

`NemoNoiseTests/TextInjectorSinkTests.swift` needs signature updates (`injectAX` → `inject`, return `InjectionOutcome`) to keep compiling. `TextInjectorSink` itself remains dead code in production paths (see below).

### Logging

Each path logs a structured line for in-the-wild diagnosis:

```
inject — path=AX, len=42
inject — path=keystroke, len=42, charDelayMs=3, elapsed=128ms
inject — path=secure_field
inject — path=failed, reason=not_frontmost_after_300ms, target_pid=1234
```

## Files touched

| File | Change |
|---|---|
| `NemoNoise/Services/Output/TextInjector.swift` | Add `InjectionOutcome`; rename `injectAX` → `inject`; add secure-field check, keystroke loop, frontmost polling; remove ⌘V simulation |
| `NemoNoise/Services/Output/OutputDispatcher.swift` | Switch on `InjectionOutcome`; map outcomes to Toast styles |
| `NemoNoise/Services/Sinks/TextInjectorSink.swift` | Update to new protocol signature (file is dead in app paths but kept compiling) |
| `NemoNoiseTests/TextInjectorTests.swift` | Update existing tests for new signature; add outcome-specific tests |
| `NemoNoiseTests/TextInjectorSinkTests.swift` | Update `StubInjector` and assertions for new protocol |

## Not in scope

- Deleting `TextInjectorSink`. It is unused since `OutputDispatcher` took over the dictation path, but lives outside this fix. A one-line note in `docs/architecture.md` flagging it as currently-unused-but-retained is a reasonable add for context.
- User-facing Type-vs-Paste mode toggle (Superwhisper-style). Single mode (this design) covers the common case; a toggle is YAGNI until a user explicitly requests it.
- Per-app injection profile (e.g. "for app X, always use keystroke"). Same YAGNI argument.
- Mid-injection cancellation when user switches apps.

## Risks and rollback

- **`.privateState` event source change** may surface a regression in a niche app where the modifier-clean behaviour interacts differently with that app's input handler. Rollback: change one line back to `.hidSystemState`; functionality remains, only the modifier-pollution mitigation is lost.
- **macOS HID event-rate limiting.** If diagnostic logs show `elapsed >> charDelayMs × charCount`, the 3 ms inter-scalar delay is being throttled. Bump to 5 ms; reassess if persistent.
- **`.activateIgnoringOtherApps` deprecation.** When Apple eventually removes it, swap to parameterless `activate()`. Behavioural equivalent in our context.
