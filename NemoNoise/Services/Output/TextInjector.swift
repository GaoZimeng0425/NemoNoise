import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

enum InjectionOutcome: Sendable, Equatable {
    case injectedAX
    case injectedPaste
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
    /// `true` when the target app has an unreliable AX write bridge — AX
    /// `setValue` / `kAXSelectedText` return `.success` but the writes are
    /// no-ops in the actual text storage. Two root causes seen in the wild:
    /// (1) Electron/Chromium's AX bridge stubbing writes at the renderer
    /// boundary, (2) hybrid native apps (e.g. WeChat) shipping custom text
    /// controls that expose `AXTextArea` for read but reject writes silently.
    /// Behavior is the same → skip AX, go straight to `paste:` selector on
    /// the NSResponder chain, which both classes of app implement natively.
    private var skipAXWrites: Bool = false

    /// Bundle IDs known to silently reject AX writes. Mixed origins: Electron
    /// apps (Slack, VSCode, Discord) and Chinese hybrid apps (WeChat). For
    /// Electron, `isAXWriteHostile` also checks for `Electron Framework`, so
    /// unlisted Electron apps still get caught. Native-ish hybrids (WeChat,
    /// Lark, etc.) must be listed explicitly — no framework signature to detect.
    private static let axHostileBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",        // Slack            (Electron)
        "com.microsoft.VSCode",              // VS Code          (Electron)
        "com.hnc.Discord",                   // Discord          (Electron)
        "notion.id",                         // Notion           (Electron)
        "com.figma.Desktop",                 // Figma            (Electron)
        "com.linear",                        // Linear           (Electron)
        "com.github.GitHubClient",           // GitHub Desktop   (Electron)
        "com.tencent.xinWeChat",             // WeChat for Mac   (hybrid native)
    ]

    private static func isAXWriteHostile(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier, axHostileBundleIDs.contains(id) {
            return true
        }
        guard let bundleURL = app.bundleURL else { return false }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let fm = FileManager.default
        // Electron — standard electron-builder / electron-packager output.
        let electron = frameworks.appendingPathComponent("Electron Framework.framework", isDirectory: true)
        if fm.fileExists(atPath: electron.path) { return true }
        // CEF (Chromium Embedded Framework) — Spotify old versions, some game
        // launchers / Adobe tools. Same Chromium AX bridge → same no-op problem.
        let cef = frameworks.appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
        return fm.fileExists(atPath: cef.path)
    }

    func captureTarget() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostBundle = frontmost?.bundleIdentifier ?? "<unknown>"
        // Always record frontmost pid — even when AX query returns no element
        // (common for Electron / WebView targets), the paste path still works
        // because ⌘V routes through the frontmost app, not via an AX handle.
        targetApp = frontmost?.processIdentifier
        skipAXWrites = frontmost.map(Self.isAXWriteHostile) ?? false
        if skipAXWrites {
            LogService.info("captureTarget — AX-hostile target detected (\(frontmostBundle)), AX writes will be skipped", category: "TextInjection")
        }
        if let frontmost {
            enableElectronAccessibility(for: frontmost)
        }

        let systemWide = AXUIElementCreateSystemWide()
        // Cap AX messaging at 1 s — default is 6 s, which freezes inject when
        // the target app (Electron / Chrome) is slow to respond to AX queries.
        AXUIElementSetMessagingTimeout(systemWide, 1.0)
        var focusedElement: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard status == .success, let element = focusedElement else {
            targetElement = nil
            LogService.info("captureTarget — frontmost=\(frontmostBundle) (pid=\(targetApp ?? -1)), AX status=\(status.rawValue), no element — paste/keystroke fallback only", category: "TextInjection")
            return
        }
        let axElement = element as! AXUIElement
        AXUIElementSetMessagingTimeout(axElement, 1.0)
        targetElement = axElement

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subrole)
        LogService.info("captureTarget — frontmost=\(frontmostBundle) (pid=\(targetApp ?? -1)), role=\(role as? String ?? "?"), subrole=\(subrole as? String ?? "?")", category: "TextInjection")
    }

    private static let maxTextLength = 5_000
    private static let charDelayMs = 3
    private static let activationTimeoutMs = 300
    private static let safeVirtualKey: CGKeyCode = 0xCC

    /// Electron apps expose their AX tree only when `AXManualAccessibility`
    /// is set (an officially supported Electron switch). Turning it on here
    /// means secure-field detection and AX reads work for Electron targets
    /// instead of silently falling back (FluidVoice's preparation pattern).
    /// Done once per app; a bounded messaging timeout keeps a hung app from
    /// stalling the hotkey path.
    private static let electronAxCandidates = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    private func enableElectronAccessibility(for app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier ?? app.bundleURL?.absoluteString else { return }
        let alreadyHandled = Self.electronAxCandidates.withLock { handled -> Bool in
            guard !handled.contains(bundleID) else { return true }
            handled.insert(bundleID)
            return false
        }
        guard !alreadyHandled else { return }

        guard let bundleURL = app.bundleURL else { return }
        let framework = bundleURL
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        guard FileManager.default.fileExists(atPath: framework.path) else { return }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        let status = AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if status == .success {
            LogService.info("Enabled AXManualAccessibility for Electron app \(bundleID)", category: "TextInjection")
        }
    }

    /// Physical modifiers still held (e.g. the push-to-talk hotkey's ⌥ at
    /// release time) merge with a synthetic ⌘V into ⌥⌘V — which is not
    /// Paste in most apps. Wait for release, bounded (FluidVoice pattern).
    private func waitForPhysicalModifiersToRelease(timeout: TimeInterval = 1.5) async {
        // Both sides of ⌘/⌥/⌃/⇧.
        let modifierKeys: [CGKeyCode] = [55, 54, 58, 61, 59, 62, 56, 60]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let anyDown = modifierKeys.contains { CGEventSource.keyState(.hidSystemState, key: $0) }
            if !anyDown {
                // Let the system's modifier state machine flush the release.
                try? await Task.sleep(for: .milliseconds(30))
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

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
        await waitForPhysicalModifiersToRelease()
        // .hidSystemState: events look like they came from real hardware.
        // Electron/Chromium input layers reject events from .privateState even
        // when posted to .cghidEventTap, so we use system state and rely on
        // flags=[] below to neutralise any held modifiers.
        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            // Short-circuit if the surrounding task was cancelled mid-typing.
            // Up to 5000 chars × ~4 ms = ~20 s loop; cancellation must land fast.
            if Task.isCancelled { return }
            let utf16 = Array(String(scalar).utf16)

            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.safeVirtualKey, keyDown: true) {
                keyDown.flags = []
                utf16.withUnsafeBufferPointer { buf in
                    keyDown.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                keyDown.post(tap: .cghidEventTap)
            }

            // Playbook 07 Pitfall 1: ≥1 ms between keyDown and keyUp of the same
            // char so Electron/Chromium IPC queues (Slack, Discord) don't drop it.
            try? await Task.sleep(for: .milliseconds(1))

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

    func inject(_ text: String) async -> InjectionOutcome {
        guard text.count <= Self.maxTextLength else {
            LogService.info("inject — path=failed, reason=text_too_long, len=\(text.count)", category: "TextInjection")
            return .failed(reason: "text_too_long_\(text.count)")
        }

        guard let pid = targetApp else {
            LogService.info("inject — path=failed, reason=no_target", category: "TextInjection")
            return .failed(reason: "no_target")
        }

        // AX paths only run if a focused element was captured. Electron / WebView
        // targets (Slack, Discord, WeChat) often don't expose their renderer's
        // focused element through systemwide AX query, so targetElement may be
        // nil — that's OK, paste path doesn't need it.
        if let element = targetElement {
            if isSecureField(element) {
                LogService.info("inject — path=secure_field", category: "TextInjection")
                return .skippedSecureField
            }

            if skipAXWrites {
                // AX writes on this target return .success but don't land
                // (Chromium AX bridge or WeChat-style hybrid stub). Paste path
                // goes through paste: on NSResponder chain, which these apps
                // all implement natively.
                LogService.info("inject — AX-hostile target, bypassing AX paths", category: "TextInjection")
            } else if let outcome = tryAXWrite(element, text) {
                return outcome
            }
            // tryAXWrite returned nil → the write failed OR acked .success but
            // was a verified no-op (web content / terminals that aren't in the
            // hostile list). Fall through to the paste path, which lands there.
        } else {
            // No element means AX can't tell whether this is a password field
            // (Electron/web fields often expose none — and Electron builds its
            // AX tree asynchronously, so the first dictation per app gets nil).
            // Secure event input is the system-level signal a password field
            // is focused; never paste or type into one.
            if IsSecureEventInputEnabled() {
                LogService.info("inject — path=secure_field (secure event input on, no AX element)", category: "TextInjection")
                return .skippedSecureField
            }
            LogService.info("inject — no AX element captured, skipping AX paths, going straight to paste", category: "TextInjection")
        }

        // Modifiers first, frontmost check second: a ⌘ still held from ⌘-Tab
        // during the wait would otherwise land ⌘V in whatever app became
        // frontmost after the check.
        await waitForPhysicalModifiersToRelease()
        let isFrontmost = await waitUntilFrontmost(pid: pid)
        guard isFrontmost else {
            LogService.info("inject — path=failed, reason=not_frontmost_after_\(Self.activationTimeoutMs)ms, target_pid=\(pid)", category: "TextInjection")
            return .failed(reason: "not_frontmost_after_\(Self.activationTimeoutMs)ms")
        }

        // Playbook 07 step 1: only the keystroke path needs CGEvent post access;
        // AX writes above use a different permission. Without it CGEvent.post
        // returns success but events are silently dropped.
        guard CGPreflightPostEventAccess() else {
            LogService.info("inject — path=failed, reason=input_access_denied", category: "TextInjection")
            return .failed(reason: "input_access_denied")
        }

        // Playbook 07 §8.1 Step 2: AX press re-focuses the captured element in
        // the renderer process — app activation alone doesn't restore per-element
        // focus inside Electron. 50 ms lets the renderer IPC settle. Skip if we
        // never captured an element to begin with.
        if let element = targetElement {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            try? await Task.sleep(for: .milliseconds(50))
        }

        // Paste path: covers Slack/Discord/WeChat where AX writes are rejected
        // and raw keystrokes get IPC-dropped or IME-intercepted. ⌘V goes through
        // the standard paste: command and is accepted by virtually every text
        // input that accepts paste at all.
        if await pasteViaCmdV(text) {
            LogService.info("inject — path=paste, len=\(text.count)", category: "TextInjection")
            return .injectedPaste
        }
        LogService.info("inject — paste path setup failed, falling through to keystroke", category: "TextInjection")

        let start = Date()
        await postKeystrokes(text)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        LogService.info("inject — path=keystroke, len=\(text.count), charDelayMs=\(Self.charDelayMs), elapsed=\(elapsedMs)ms", category: "TextInjection")
        return .injectedKeystroke
    }

    /// Writes `text` to the general pasteboard and synthesizes ⌘V to the
    /// frontmost app. Returns `true` if the events were posted (no signal that
    /// the target actually consumed them — same trust model as `postKeystrokes`).
    private func pasteViaCmdV(_ text: String) async -> Bool {
        await waitForPhysicalModifiersToRelease()
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            return false
        }

        let source = CGEventSource(stateID: .hidSystemState)
        // kVK_ANSI_V = 0x09. Cmd+V is dispatched by the system as the paste:
        // selector — keycode for 'v' is not layout-dependent for this purpose
        // because the menu equivalent is looked up by character.
        let vKey: CGKeyCode = 0x09

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        // Playbook 07 Pitfall 2: keyUp must carry the same modifier flags as
        // keyDown so the system modifier state machine ends cleanly.
        up.flags = .maskCommand

        var upPosted = false
        defer {
            if !upPosted {
                // Guarantee Cmd-up posts even on task cancellation, otherwise
                // the Cmd flag leaks into the user's next real keystroke.
                up.post(tap: .cghidEventTap)
            }
        }

        down.post(tap: .cghidEventTap)
        // Playbook 07 Pitfall 1: ≥1 ms between down and up for Electron IPC.
        try? await Task.sleep(for: .milliseconds(2))
        up.post(tap: .cghidEventTap)
        upPosted = true

        // Give the target a moment to handle paste: before any caller continues.
        try? await Task.sleep(for: .milliseconds(50))
        return true
    }

    /// Attempts the AX write paths against `element`. Returns `.injectedAX`
    /// ONLY when the write is confirmed to have changed the field. Returns nil
    /// when the write failed, or acked `.success` but was a verified no-op —
    /// web content (Safari/Chromium) and terminals expose a focused text
    /// element that accepts `kAXSelectedText`/`kAXValue` writes with `.success`
    /// and silently drops them. The caller then falls through to the paste path.
    private func tryAXWrite(_ element: AXUIElement, _ text: String) -> InjectionOutcome? {
        // AX path A: replace selected text (caret-aware, preserves rest of field).
        let beforeA = stringValue(element)
        var axStatus = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if axStatus == .success {
            if Self.axWriteChanged(beforeValue: beforeA, afterValue: stringValue(element)) == false {
                LogService.info("inject — AX kAXSelectedText acked .success but value unchanged (no-op), bypassing AX → paste", category: "TextInjection")
                return nil
            }
            LogService.info("inject — path=AX_selected, len=\(text.count)", category: "TextInjection")
            return .injectedAX
        }
        LogService.info("inject — AX kAXSelectedText failed (status=\(axStatus.rawValue))", category: "TextInjection")

        // AX path B: kAXValue full-value write — gated on empty field so we
        // don't clobber a user draft. Many Electron AXTextArea targets reject
        // kAXSelectedText but accept this path.
        var currentValue: CFTypeRef?
        let readStatus = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue)
        let beforeB = currentValue as? String
        let fieldIsEmpty = (readStatus == .success) && (beforeB?.isEmpty ?? false)
        if fieldIsEmpty {
            axStatus = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
            if axStatus == .success {
                if Self.axWriteChanged(beforeValue: beforeB, afterValue: stringValue(element)) == false {
                    LogService.info("inject — AX kAXValue acked .success but value unchanged (no-op), bypassing AX → paste", category: "TextInjection")
                    return nil
                }
                LogService.info("inject — path=AX_value, len=\(text.count)", category: "TextInjection")
                return .injectedAX
            }
            LogService.info("inject — AX kAXValue failed (status=\(axStatus.rawValue))", category: "TextInjection")
        } else {
            LogService.info("inject — field non-empty (readStatus=\(readStatus.rawValue)), skipping kAXValue replace", category: "TextInjection")
        }
        return nil
    }

    /// Decides whether an AX write that returned `.success` actually modified
    /// the field, by comparing the field value before and after:
    ///  - `true`  — value changed → the write landed.
    ///  - `false` — value identical → silent no-op (web content / terminals).
    ///  - `nil`   — a value read failed, so the result is unknown; the caller
    ///    must keep the status quo (trust `.success`) rather than fall through
    ///    to paste, which would double-insert if the write had in fact landed.
    static func axWriteChanged(beforeValue: String?, afterValue: String?) -> Bool? {
        guard let before = beforeValue, let after = afterValue else { return nil }
        return before != after
    }

    /// Reads the element's text value (`kAXValue`) as a String, or nil if the
    /// attribute is absent or unreadable.
    private func stringValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    private func isSecureField(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard status == .success, let str = subrole as? String else { return false }
        return str == (kAXSecureTextFieldSubrole as String)
    }
}
