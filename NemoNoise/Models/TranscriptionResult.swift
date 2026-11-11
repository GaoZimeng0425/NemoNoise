// NemoNoise/Models/TranscriptionResult.swift
import Foundation

struct TranscriptionSegment: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let emotion: String?
    /// Measured silence before this segment's first speech (seconds); nil
    /// when unknown. Used at join time to keep sentence marks only at real
    /// sentence ends (see `TranscriptJoin.sentences(_:pauseBefore:)`).
    let pauseBefore: TimeInterval?
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
    /// Silence before this utterance's first speech, in seconds of session
    /// audio — the seam pause into the previous utterance. Set by engines
    /// that segment by speech pauses (`VADSegmentingEngine`); nil elsewhere.
    let pauseBefore: TimeInterval?

    init(
        text: String,
        isFinal: Bool,
        emotion: String?,
        originalText: String? = nil,
        sequence: Int? = nil,
        audioStart: TimeInterval? = nil,
        spokenAt: Date? = nil,
        pauseBefore: TimeInterval? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.emotion = emotion
        self.originalText = originalText
        self.sequence = sequence
        self.audioStart = audioStart
        self.spokenAt = spokenAt
        self.pauseBefore = pauseBefore
    }

    /// A copy with the timing fields set. A nil `pauseBefore` keeps the
    /// receiver's own (postprocessors that rebuild a result must not lose it).
    func stamped(audioStart: TimeInterval?, spokenAt: Date?, pauseBefore: TimeInterval? = nil) -> TranscriptionResult {
        TranscriptionResult(text: text, isFinal: isFinal, emotion: emotion, originalText: originalText,
                            sequence: sequence, audioStart: audioStart, spokenAt: spokenAt,
                            pauseBefore: pauseBefore ?? self.pauseBefore)
    }
}
