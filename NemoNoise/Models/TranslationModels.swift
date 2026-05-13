import Foundation

enum TranslationState: Equatable {
    case idle
    case capturing
    case error(String)
}

enum TranslationError: Error, LocalizedError {
    case screenRecordingDenied
    case noDisplay
    case translationUnavailable
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            "Screen recording permission required. Enable in System Settings → Privacy & Security → Screen Recording."
        case .noDisplay:
            "No display found for audio capture."
        case .translationUnavailable:
            "Translation unavailable. Check that language packs are downloaded in System Settings."
        case .captureFailed(let message):
            "Audio capture failed: \(message)"
        }
    }
}
