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

    @discardableResult
    func injectAX(_ text: String) async -> Bool {
        // Strategy 1: Insert via kAXSelectedTextAttribute (inserts at cursor)
        if let element = targetElement {
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            if result == .success {
                LogService.info("Injection method: AX selectedText, length: \(text.count)", category: "TextInjection")
                return true
            }
            LogService.debug("AX selectedText failed (\(result.rawValue)), trying paste", category: "TextInjection")
        }

        // Strategy 2: Clipboard + Cmd+V paste
        if await pasteViaClipboard(text) {
            LogService.info("Injection method: clipboard paste, length: \(text.count)", category: "TextInjection")
            return true
        }

        LogService.warn("All injection methods failed", category: "TextInjection")
        return false
    }

    private func pasteViaClipboard(_ text: String) async -> Bool {
        guard let pid = targetApp,
              let app = NSRunningApplication(processIdentifier: pid) else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Yield to let the pasteboard settle, then activate the target app and yield again
        // before synthesising Cmd+V so the keystroke lands in the right process.
        try? await Task.sleep(for: .milliseconds(50))
        app.activate(options: [])
        try? await Task.sleep(for: .milliseconds(50))

        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        return true
    }
}
