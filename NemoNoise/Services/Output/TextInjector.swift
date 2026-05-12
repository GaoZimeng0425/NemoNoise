import AppKit
import ApplicationServices

final class TextInjector {
    private var targetElement: AXUIElement?

    func captureTarget() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard status == .success, let element = focusedElement else {
            LogService.debug("No focused element captured (AX error: \(status.rawValue))", category: "TextInjection")
            targetElement = nil
            return
        }
        targetElement = (element as! AXUIElement)
        LogService.debug("Captured target AXUIElement", category: "TextInjection")
    }

    @discardableResult
    func inject(_ text: String) async -> Bool {
        guard let element = targetElement else {
            LogService.info("Injection method: clipboard (no target element), length: \(text.count)", category: "TextInjection")
            await pasteViaPasteboard(text)
            return false
        }

        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        if result == .success {
            LogService.info("Injection method: AX, length: \(text.count)", category: "TextInjection")
            return true
        }

        LogService.warn("AX injection failed (error: \(result.rawValue)), falling back to clipboard", category: "TextInjection")
        await pasteViaPasteboard(text)
        return false
    }

    private func pasteViaPasteboard(_ text: String) async {
        let previousContents = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 0x09
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        if let previous = previousContents {
            try? await Task.sleep(for: .milliseconds(200))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(previous, forType: .string)
        }
    }
}
