import Foundation

/// Centralised string keys used with `UserDefaults` / `@AppStorage`.
/// Add new keys here so they are discoverable and don't drift via typos.
enum AppDefaults {
    enum Keys {
        static let engineType = "engineType"
        static let recordingMode = "recordingMode"
        static let languagePreference = "languagePreference"
        static let preferredMicUID = "preferredMicUID"
        static let echoCancellation = "echoCancellation"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let sentryEnabled = "sentryEnabled"
        /// Legacy hotkey key — read once by `HotkeyMigration` and then deleted.
        static let legacyHotkeyOption = "hotkeyOption"
    }

    enum Defaults {
        static let engineType = "apple"
        static let recordingMode = "pushToTalk"
        static let languagePreference = "auto"
    }
}
