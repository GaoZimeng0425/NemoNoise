import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
    static let translationMode = Self("translationMode")
}

extension Notification.Name {
    static let recordingShortcutDidChange = Self("recordingShortcutDidChange")
}

enum HotkeyMigration {
    static func run() {
        guard let old = UserDefaults.standard.string(forKey: AppDefaults.Keys.legacyHotkeyOption) else { return }

        if KeyboardShortcuts.getShortcut(for: .toggleRecording) != nil {
            UserDefaults.standard.removeObject(forKey: AppDefaults.Keys.legacyHotkeyOption)
            return
        }

        switch old {
        case "option":
            KeyboardShortcuts.setShortcut(
                .init(carbonKeyCode: 0, carbonModifiers: optionCarbonModifiers),
                for: .toggleRecording
            )
        case "rightCommand":
            KeyboardShortcuts.setShortcut(
                .init(carbonKeyCode: 0, carbonModifiers: cmdCarbonModifiers),
                for: .toggleRecording
            )
        default:
            break
        }

        UserDefaults.standard.removeObject(forKey: AppDefaults.Keys.legacyHotkeyOption)
    }

    private static let optionCarbonModifiers: Int = 0x0800
    private static let cmdCarbonModifiers: Int = 0x0100
}
