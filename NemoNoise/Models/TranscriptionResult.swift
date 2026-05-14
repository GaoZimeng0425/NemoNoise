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
}
