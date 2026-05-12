import Foundation
import ApplicationServices

// MARK: - ASR Models

struct TranscriptionSegment: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let emotion: String?
}

struct TranscriptionResult: Sendable {
    let text: String
    let isFinal: Bool
    let emotion: String?
}

// MARK: - State

enum RecordingState: Equatable {
    case ready
    case recording
    case processing
    case failed(String)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.ready, .ready), (.recording, .recording), (.processing, .processing):
            return true
        case (.failed(let l), .failed(let r)):
            return l == r
        default:
            return false
        }
    }
}

enum RecordingMode: String, CaseIterable, Codable {
    case pushToTalk = "Push to Talk"
    case toggle = "Toggle"
}

enum HotkeyOption: String, CaseIterable, Codable {
    case option = "⌥ Option"
    case rightCommand = "⌘ Right Command"

    var cgFlags: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .rightCommand: return .maskCommand
        }
    }
}

// MARK: - Errors

enum ASRError: Error {
    case modelNotFound
    case audioCaptureFailed(String)
    case invalidPythonPath
    case socketDisconnected
    case engineUnavailable
    case engineInitFailed
}
