import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// In-house shortcut recorder, replacing `KeyboardShortcuts.Recorder`.
///
/// The library recorder is an `NSSearchField` that captures keys with a
/// local event monitor installed in `becomeFirstResponder`. On this
/// machine's macOS 26 the monitor never sees the events, so the control
/// degrades into a plain text field (typing inserts characters). This
/// control is an ordinary `NSView` that overrides `keyDown(_:)` — AppKit
/// guarantees the first responder receives every key press, no event
/// monitor involved, and a non-text view can never accept typed text.
struct ShortcutRecorderField: NSViewRepresentable {
    let name: KeyboardShortcuts.Name
    var onChange: ((KeyboardShortcuts.Shortcut?) -> Void)?

    func makeNSView(context: Context) -> RecorderControl {
        RecorderControl(name: name, onChange: onChange)
    }

    func updateNSView(_ nsView: RecorderControl, context: Context) {
        nsView.shortcutName = name
        nsView.onChange = onChange
    }

    final class RecorderControl: NSView {
        /// Every hotkey the app registers. All of them are paused while
        /// recording so the key the user presses to record never fires the
        /// old global shortcut. Paused with `disable`/`enable`, which only
        /// unregister/register — never with `setShortcut(nil)`, which is
        /// persisted: a recording that ended any other way (window closed,
        /// app quit, focus lost) used to leave both hotkeys erased.
        private static let managedNames: [KeyboardShortcuts.Name] = [
            .toggleRecording, .translationMode
        ]

        private let modifierKeyCodes: Set<UInt16> = [
            UInt16(kVK_Shift), UInt16(kVK_RightShift),
            UInt16(kVK_Control), UInt16(kVK_RightControl),
            UInt16(kVK_Option), UInt16(kVK_RightOption),
            UInt16(kVK_Command), UInt16(kVK_RightCommand),
            UInt16(kVK_Function), UInt16(kVK_CapsLock),
        ]

        /// F1–F12 — recordable without other modifiers, matching the library.
        private let functionKeyCodes: Set<UInt16> = [
            UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3),
            UInt16(kVK_F4), UInt16(kVK_F5), UInt16(kVK_F6),
            UInt16(kVK_F7), UInt16(kVK_F8), UInt16(kVK_F9),
            UInt16(kVK_F10), UInt16(kVK_F11), UInt16(kVK_F12),
        ]

        private var name: KeyboardShortcuts.Name
        var onChange: ((KeyboardShortcuts.Shortcut?) -> Void)?
        private var isRecording = false
        private var resignKeyObserver: NSObjectProtocol?

        init(name: KeyboardShortcuts.Name, onChange: ((KeyboardShortcuts.Shortcut?) -> Void)?) {
            self.name = name
            self.onChange = onChange
            super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        var shortcutName: KeyboardShortcuts.Name {
            get { name }
            set {
                guard newValue != name else { return }
                name = newValue
                needsDisplay = true
            }
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: 160, height: 24)
        }

        override var canBecomeKeyView: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // MARK: - Recording lifecycle

        /// Recording starts on an explicit click (or Space/Return when
        /// focused) — not on gaining focus, which a window can hand to its
        /// first key view on open without the user asking.
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            beginRecording()
        }

        override func resignFirstResponder() -> Bool {
            endRecording()
            return super.resignFirstResponder()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endRecording() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func beginRecording() {
            guard !isRecording else { return }
            KeyboardShortcuts.disable(Self.managedNames)
            isRecording = true
            // Switching to another app or closing the window ends recording.
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.endRecording() }
            }
            needsDisplay = true
        }

        /// Re-registers every hotkey from storage — whatever `apply(_:)` just
        /// saved for this one, the untouched values for the others.
        private func endRecording() {
            guard isRecording else { return }
            isRecording = false
            if let resignKeyObserver {
                NotificationCenter.default.removeObserver(resignKeyObserver)
            }
            resignKeyObserver = nil
            KeyboardShortcuts.enable(Self.managedNames)
            needsDisplay = true
        }

        // MARK: - Key capture

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                if event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) {
                    beginRecording()
                } else {
                    super.keyDown(with: event)
                }
                return
            }

            // Bare modifier presses only change the modifiers — wait for the
            // actual key.
            guard !modifierKeyCodes.contains(event.keyCode) else { return }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if modifiers.isEmpty {
                switch event.keyCode {
                case UInt16(kVK_Escape):
                    window?.makeFirstResponder(nil)  // cancel via resignFirstResponder
                    return
                case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete):
                    apply(shortcut: nil)
                    return
                case UInt16(kVK_Tab):
                    window?.selectNextKeyView(self)
                    return
                default:
                    break
                }
            }

            // Same rule as the library: a shortcut needs at least one
            // non-shift modifier, unless it is a bare function key.
            let hasRealModifier = !modifiers.subtracting([.shift, .function]).isEmpty
            guard hasRealModifier || functionKeyCodes.contains(event.keyCode),
                  let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
                NSSound.beep()
                return
            }

            apply(shortcut: shortcut)
        }

        private func apply(shortcut: KeyboardShortcuts.Shortcut?) {
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            endRecording()
            onChange?(shortcut)
            window?.makeFirstResponder(nil)
        }

        // MARK: - Drawing

        private var displayText: String {
            if isRecording { return "Recording… (Esc to cancel)" }
            return KeyboardShortcuts.getShortcut(for: name).map { "\($0)" } ?? "Click to record"
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)

            if isRecording {
                NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            } else {
                NSColor.textBackgroundColor.setFill()
            }
            path.fill()

            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isRecording ? 1.5 : 1
            path.stroke()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small)),
                .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
            ]
            let textSize = (displayText as NSString).size(withAttributes: attributes)
            (displayText as NSString).draw(
                at: NSPoint(
                    x: (bounds.width - textSize.width) / 2,
                    y: (bounds.height - textSize.height) / 2
                ),
                withAttributes: attributes
            )
        }
    }
}
