import AppKit

enum ScreenRecordingAlert {
    /// Returns true if the user clicked "Open System Settings", false otherwise.
    @MainActor @discardableResult
    static func present() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "NemoNoise needs screen recording permission to capture system audio.\n\nGo to System Settings → Privacy & Security → Screen Recording, then enable NemoNoise."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let response = alert.runModal()
        let openSettings = response == .alertFirstButtonReturn
        if openSettings {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return openSettings
    }
}
