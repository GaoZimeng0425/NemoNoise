import Foundation

/// Runs `TranscriptTidy.tidy` on every result: a period carried over to the
/// start of a line ("。记住…", seen from Apple SpeechAnalyzer), a space before
/// a mark ("回来 ，直到"), dot runs from breaths. Engine-agnostic, so every
/// pipeline runs it.
///
/// Order matters: after `SentenceSegmenter` (which slices by character
/// offsets of the raw text) and after punctuation / corrections (it cleans
/// what will be shown), before translation (the translator gets clean text).
/// Partials too, so the live line doesn't flash the stray mark.
nonisolated struct TranscriptTidyProcessor: PostProcessor {
    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        guard !result.text.isEmpty else { return nil }
        let tidied = TranscriptTidy.tidy(result.text)
        guard tidied != result.text else { return nil }
        return TranscriptionResult(text: tidied, isFinal: result.isFinal, emotion: result.emotion,
                                   originalText: result.originalText, sequence: result.sequence,
                                   audioStart: result.audioStart, spokenAt: result.spokenAt)
    }
}
