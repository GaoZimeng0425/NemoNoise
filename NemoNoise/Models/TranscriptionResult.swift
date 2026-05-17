// NemoNoise/Models/TranscriptionResult.swift
import Foundation

struct TranscriptionSegment: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let emotion: String?
}

struct TranscriptionResult: Sendable {
    let text: String
    let isFinal: Bool
    let emotion: String?
    let originalText: String?
    let sequence: Int?

    init(
        text: String,
        isFinal: Bool,
        emotion: String?,
        originalText: String? = nil,
        sequence: Int? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.emotion = emotion
        self.originalText = originalText
        self.sequence = sequence
    }
}
