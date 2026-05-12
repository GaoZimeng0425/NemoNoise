import AppKit
import ApplicationServices

final class TextInjector {
    private var targetElement: AXUIElement?

    // Call this at hotkey DOWN to snapshot the focused element before recording starts
    func captureTarget() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else {
            targetElement = nil
            return
        }
        targetElement = (element as! AXUIElement)
    }

    // Returns true if text was injected, false if fallback (paste) was needed
    @discardableResult
    func inject(_ text: String) async -> Bool {
        guard let element = targetElement else {
            await pasteViaPasteboard(text)
            return false
        }

        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        if result == .success {
            return true
        }

        // AXUIElement write failed (read-only field, app doesn't support it, etc.)
        // Fall back to pasteboard + Cmd+V
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

        // Restore previous clipboard contents after a short delay
        if let previous = previousContents {
            try? await Task.sleep(for: .milliseconds(200))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(previous, forType: .string)
        }
    }
}
