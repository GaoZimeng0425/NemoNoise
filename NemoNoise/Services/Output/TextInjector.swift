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

    private func isSecureField(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard status == .success, let str = subrole as? String else { return false }
        return str == (kAXSecureTextFieldSubrole as String)
    }
}
