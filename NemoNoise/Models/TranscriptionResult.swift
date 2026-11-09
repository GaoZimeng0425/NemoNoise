// NemoNoise/Models/TranscriptionResult.swift
import Foundation

struct TranscriptionSegment: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let emotion: String?
}

nonisolated struct TranscriptionResult: Sendable {
    let text: String
    let isFinal: Bool
    let emotion: String?
    let originalText: String?
    let sequence: Int?
    /// When the utterance began, in seconds of session audio (the engine's
    /// own timeline from its first chunk). Set on finals: precisely by
    /// engines that know it, otherwise by `TranscriptionPipeline`.
    let audioStart: TimeInterval?
    /// Wall-clock time the utterance began — `audioStart` placed on the
    /// session's first-audio wall clock. Set on finals by the pipeline.
    let spokenAt: Date?

    init(
        text: String,
        isFinal: Bool,
        emotion: String?,
        originalText: String? = nil,
        sequence: Int? = nil,
        audioStart: TimeInterval? = nil,
        spokenAt: Date? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.emotion = emotion
        self.originalText = originalText
        self.sequence = sequence
        self.audioStart = audioStart
        self.spokenAt = spokenAt
    }

    /// A copy with the timing fields set.
    func stamped(audioStart: TimeInterval?, spokenAt: Date?) -> TranscriptionResult {
        TranscriptionResult(text: text, isFinal: isFinal, emotion: emotion, originalText: originalText,
                            sequence: sequence, audioStart: audioStart, spokenAt: spokenAt)
    }
}
