import ApplicationServices
import KeyboardShortcuts
import os

@MainActor
final class HotkeyMonitor {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var eventTask: Task<Void, Never>?
    private var isActive = true
    private var shortcutObserver: NSObjectProtocol?

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
        guard eventTask == nil else { return }

        isActive = true
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .recordingShortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restartEventStream()
        }

        startEventStream()
        LogService.info("Hotkey event stream started", category: "HotkeyMonitor")
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        isActive = false
        if let observer = shortcutObserver {
            NotificationCenter.default.removeObserver(observer)
            shortcutObserver = nil
        }
    }

    private func startEventStream() {
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
    }

    private func restartEventStream() {
        eventTask?.cancel()
        eventTask = nil
        startEventStream()
        LogService.info("Hotkey event stream restarted after shortcut change", category: "HotkeyMonitor")
    }

    deinit {
        eventTask?.cancel()
        if let observer = shortcutObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
