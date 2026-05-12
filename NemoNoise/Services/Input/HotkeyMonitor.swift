import ApplicationServices
import Combine
import KeyboardShortcuts
import os

@MainActor
final class HotkeyMonitor: ObservableObject {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var eventTask: Task<Void, Never>?
    private var isActive = true

    /// For testing: simulate a keyDown event
    func simulateKeyDown() {
        guard isActive else { return }
        onKeyDown?()
    }

    /// For testing: simulate a keyUp event
    func simulateKeyUp() {
        guard isActive else { return }
        onKeyUp?()
    }

    func start() {
        guard AXIsProcessTrusted() else {
            LogService.warn("Accessibility permission not granted — hotkey disabled", category: "HotkeyMonitor")
            return
        }

        isActive = true
        eventTask = Task { [weak self] in
            for await event in KeyboardShortcuts.events(for: .toggleRecording) {
                guard let self else { return }
                switch event {
                case .keyDown:
                    self.onKeyDown?()
                case .keyUp:
                    self.onKeyUp?()
                }
            }
        }
        LogService.info("Hotkey event stream started", category: "HotkeyMonitor")
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        isActive = false
    }

    deinit {
        eventTask?.cancel()
    }
}
