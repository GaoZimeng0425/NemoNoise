import AppKit

enum MicPermissionAlert {
    @MainActor @discardableResult
    static func present() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "NemoNoise needs microphone access to record your voice.\n\nGo to System Settings → Privacy & Security → Microphone, then enable NemoNoise."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let response = alert.runModal()
        let openSettings = response == .alertFirstButtonReturn
        if openSettings {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
        return openSettings
    }
}
