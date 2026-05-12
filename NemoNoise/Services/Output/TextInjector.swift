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
    func injectAX(_ text: String) -> Bool {
        guard let element = targetElement else {
            LogService.info("No target element for AX injection, length: \(text.count)", category: "TextInjection")
            return false
        }
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        if result == .success {
            LogService.info("Injection method: AX, length: \(text.count)", category: "TextInjection")
            return true
        }
        LogService.warn("AX injection failed (error: \(result.rawValue))", category: "TextInjection")
        return false
    }
}
