import CoreGraphics

/// Global ESC watcher for the dictation two-stage cancel (#3).
///
/// The overlay is a nonactivating panel: keyboard focus stays in the target
/// app, so `NSEvent.addLocalMonitorForEvents` only sees ESC when our own app
/// happens to be frontmost — which it almost never is during dictation. A
/// CGEvent tap watches HID events directly AND consumes ESC so the target app
/// doesn't also react to what is, during a recording, our cancel key.
///
/// Event taps need Accessibility trust — dictation already demands it, so the
/// precondition holds wherever this is used. If the tap cannot be created
/// (trust missing, sandbox refusal), `start` returns false and the caller
/// falls back to the old local monitor: no regression versus pre-fix
/// behavior. The tap runs on the main run loop, so the C callback is always
/// on the main thread and `MainActor.assumeIsolated` is safe there.
@MainActor
final class GlobalEscMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onEsc: (() -> Void)?

    /// Returns false when the tap could not be installed — caller should fall
    /// back to a local event monitor.
    @discardableResult
    func start(onEsc: @escaping () -> Void) -> Bool {
        stop()

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GlobalEscMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout:
                // The watchdog disabled us because a previous callback was
                // slow — standard practice is to re-enable immediately.
                MainActor.assumeIsolated {
                    monitor.reenableTap()
                }
                return Unmanaged.passUnretained(event)
            case .keyDown:
                guard GlobalEscMonitor.isCancelPress(
                    keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                    isAutoRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                    flags: event.flags
                ) else {
                    return Unmanaged.passUnretained(event)
                }
                MainActor.assumeIsolated {
                    monitor.fireEsc()
                }
                // Consumed: while a recording owns ESC, the key must not also
                // land in the target app.
                return nil
            default:
                return Unmanaged.passUnretained(event)
            }
        }

        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            LogService.warn("Global ESC tap unavailable — caller should fall back to local monitor", category: "Recording")
            return false
        }

        tap = port
        self.onEsc = onEsc
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: port, enable: true)
        LogService.info("Global ESC tap installed", category: "Recording")
        return true
    }

    /// Idempotent: safe alongside `start` failure paths and session teardown.
    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        if let tap {
            CFMachPortInvalidate(tap)
        }
        tap = nil
        onEsc = nil
    }

    isolated deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
    }

    /// A deliberate, unmodified Esc press. Auto-repeat is not a second press
    /// (holding Esc would arm and fire the two-stage cancel at once), and a
    /// modified Esc (⌘⌥Esc Force Quit, ⌘Esc …) belongs to the system or the
    /// app, never to us. 53 == kVK_Escape.
    nonisolated static func isCancelPress(keyCode: Int64, isAutoRepeat: Bool, flags: CGEventFlags) -> Bool {
        guard keyCode == 53, !isAutoRepeat else { return false }
        return flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }

    private func fireEsc() {
        onEsc?()
    }

    private func reenableTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}
