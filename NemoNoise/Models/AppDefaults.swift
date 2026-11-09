import Foundation

/// Centralised string keys used with `UserDefaults` / `@AppStorage`.
/// Add new keys here so they are discoverable and don't drift via typos.
nonisolated enum AppDefaults {
    enum Keys {
        static let engineType = "engineType"
        static let recordingMode = "recordingMode"
        static let languagePreference = "languagePreference"
        static let preferredMicUID = "preferredMicUID"
        static let echoCancellation = "echoCancellation"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let sentryEnabled = "sentryEnabled"
        /// JSON-encoded `[CorrectionRule]` the user has added on top of the
        /// built-in `TextCorrections.presets`. Read by `TextCorrections.active()`.
        static let textCorrectionRules = "textCorrectionRules"
        /// JSON-encoded `[LexiconEntry]` for recognition-side biasing.
        /// Read by `UserLexicon.active()`.
        static let vocabularyTerms = "vocabularyTerms"
        /// Set once the process tap has delivered real (non-zero) system audio.
        /// Distinguishes "quiet meeting" from "System Audio Recording permission
        /// denied" — denied taps deliver exact digital zeros with no error.
        /// Read by `ProcessTapAudioSource`.
        static let systemAudioTapProven = "systemAudioTapProven"
        /// Opt-in: refine the final dictation transcript with Apple
        /// Intelligence before insertion (`TranscriptCleanupService`).
        static let llmTranscriptCleanup = "llmTranscriptCleanup"
        /// Legacy hotkey key — read once by `HotkeyMigration` and then deleted.
        static let legacyHotkeyOption = "hotkeyOption"
    }

    enum Defaults {
        static let engineType = "apple"
        static let recordingMode = "pushToTalk"
        static let languagePreference = "auto"
    }
}
