import Foundation

/// Tidies recognizer leftovers with `HeardText.clean`: a period that belongs
/// to the previous line ("。记住…" — seen from Apple with `.fastResults`), a
/// space before a mark ("回来 ，直到"), breath marks ("in.........."). Engine-
/// agnostic, so every pipeline runs it.
///
/// Order matters: after `SentenceSegmenter` (which slices by character
/// offsets of the raw text) and after punctuation / corrections (it cleans
/// what will be shown), before translation (the translator gets clean text).
/// Partials too, so the live line doesn't flash the stray mark.
nonisolated struct HeardTextProcessor: PostProcessor {
    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        guard !result.text.isEmpty else { return nil }
        let cleaned = HeardText.clean(result.text)
        guard cleaned != result.text else { return nil }
        return TranscriptionResult(text: cleaned, isFinal: result.isFinal, emotion: result.emotion,
                                   originalText: result.originalText, sequence: result.sequence,
                                   audioStart: result.audioStart, spokenAt: result.spokenAt)
    }
}
