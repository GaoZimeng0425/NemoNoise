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

// MARK: - Errors

enum ASRError: Error {
    case modelNotFound
    case audioCaptureFailed(String)
    case invalidPythonPath
    case socketDisconnected
}
