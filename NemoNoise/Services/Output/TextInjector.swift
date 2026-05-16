import AppKit
import ApplicationServices

protocol TextInjecting: Sendable {
    func injectAX(_ text: String) async -> Bool
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

    /// Returns true only when AX selectedText truly succeeded. If that fails,
    /// best-effort fires a synthesised ⌘V keystroke and still returns false —
    /// because CGEvent posting yields no signal about whether the target app
    /// consumed it, claiming success would silently swallow failures. The
    /// caller (OutputDispatcher) always writes the pasteboard and shows a
    /// toast, so a false return still leaves the user with a usable result.
    @discardableResult
    func injectAX(_ text: String) async -> Bool {
        guard let element = targetElement else {
            LogService.info("AX injection — no captured element, skipping", category: "TextInjection")
            return false
        }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if status == .success {
            LogService.info("AX injection — selectedText succeeded, length: \(text.count)", category: "TextInjection")
            return true
        }
        LogService.info("AX injection — selectedText failed (AX status \(status.rawValue)); attempting ⌘V keystroke", category: "TextInjection")

        // Best-effort ⌘V into the target app. We deliberately do not return
        // true: in web views, Electron, terminals etc. this often does paste,
        // but there's no API to confirm. Toast still reads "Copied to
        // clipboard — press ⌘V to paste" which is accurate either way.
        guard let pid = targetApp,
              let app = NSRunningApplication(processIdentifier: pid) else {
            LogService.info("AX injection — no target pid for ⌘V fallback", category: "TextInjection")
            return false
        }
        try? await Task.sleep(for: .milliseconds(50))
        app.activate(options: [])
        try? await Task.sleep(for: .milliseconds(50))

        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) // V
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        LogService.info("AX injection — ⌘V keystroke posted to pid \(pid) (outcome unverifiable)", category: "TextInjection")
        return false
    }
}
