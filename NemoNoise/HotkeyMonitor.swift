import AppKit
import ApplicationServices

final class HotkeyMonitor: @unchecked Sendable {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var optionWasDown = false

    func start() {
        requestAccessibilityIfNeeded()

        guard AXIsProcessTrusted() else {
            print("[HotkeyMonitor] Accessibility permission not granted — hotkey disabled")
            return
        }

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.handleFlagsChangedSync(event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: selfPtr
        )

        guard let tap else {
            print("[HotkeyMonitor] CGEvent.tapCreate failed — check Accessibility permission")
            Unmanaged<HotkeyMonitor>.fromOpaque(selfPtr).release()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[HotkeyMonitor] Event tap started")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // nonisolated: called from CGEventTap callback off the main thread
    nonisolated private func handleFlagsChangedSync(event: CGEvent) {
        let flags = event.flags
        let optionNowDown = flags.contains(.maskAlternate)
        let onlyOption = flags.intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate]) == .maskAlternate

        var wasDown: Bool
        wasDown = optionWasDown  // read (safe: only toggled here, single CGEventTap queue)

        if optionNowDown && !wasDown && onlyOption {
            optionWasDown = true
            let cb = onKeyDown
            DispatchQueue.main.async { cb?() }
        } else if !optionNowDown && wasDown {
            optionWasDown = false
            let cb = onKeyUp
            DispatchQueue.main.async { cb?() }
        }
    }

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    deinit { stop() }
}
