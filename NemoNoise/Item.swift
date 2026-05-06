import Foundation

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
    case idle
    case recording
    case processing
}

enum RecordingMode: String, CaseIterable, Codable {
    case pushToTalk = "Push to Talk"
    case toggle = "Toggle"
}

import ApplicationServices

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
}
