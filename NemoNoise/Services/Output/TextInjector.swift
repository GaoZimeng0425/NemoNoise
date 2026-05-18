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
