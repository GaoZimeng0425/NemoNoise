import Foundation

/// Joins already-punctuated transcription segments into one string.
///
/// VAD-cut offline engines (Qwen3 / SenseVoice via `VADSegmentingEngine`) decode
/// each segment independently and self-punctuate it, so the boundary between two
/// segments is already delimited by a terminal mark. Inserting an ASCII space
/// there is correct for Latin scripts ("Hi there." + "How are you.") but wrong
/// for CJK, where it surfaces as a stray space after a full-width mark
/// ("你好。 走吧。") and reads as broken punctuation.
///
/// Rule: insert a single space at a boundary only when *both* sides are non-CJK;
/// otherwise concatenate directly. Empty / whitespace-only pieces are dropped and
/// each piece is edge-trimmed (callers already trim, this keeps the helper total).
///
/// `nonisolated`: a pure function, also called from the Apple engine's
/// lock-guarded state off the main actor.
nonisolated enum TranscriptJoin {
    /// A seam pause shorter than this is a breath, not a sentence end, so the
    /// previous piece's terminal mark is dropped there. 1.2 s — the breath vs
    /// sentence-end split measured in reference-project dogfooding of
    /// per-segment offline decoding.
    static let sentencePause: TimeInterval = 1.2

    static func sentences(_ pieces: [String]) -> String {
        sentences(pieces.map { (text: $0, pauseBefore: nil) })
    }

    /// Seam-aware join: like `sentences(_:)`, but a piece whose `pauseBefore`
    /// is known and shorter than `sentencePause` first strips the previous
    /// piece's trailing sentence-final mark — each VAD-cut segment is decoded
    /// as a complete utterance and always ends in one, which would otherwise
    /// punctuate every breath. A nil pause (unknown — streaming engines)
    /// keeps the mark. The last piece always keeps its mark.
    static func sentences(_ pieces: [(text: String, pauseBefore: TimeInterval?)]) -> String {
        var out = ""
        for piece in pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let pause = piece.pauseBefore, pause < sentencePause {
                out = strippingSentenceEnd(out)
            }
            guard let lhs = out.last, let rhs = text.first else {
                out = text
                continue
            }
            if isCJK(lhs) || isCJK(rhs) {
                out += text
            } else {
                out += " " + text
            }
        }
        return out
    }

    /// Drop trailing sentence-final marks (ASCII and full-width runs,
    /// e.g. "。。" or "!?"). Commas and other pauses are left alone.
    private static func strippingSentenceEnd(_ s: String) -> String {
        var out = s
        while let last = out.last, isSentenceEnd(last) {
            out.removeLast()
        }
        return out
    }

    /// Sentence-final marks: ASCII and full-width stops, exclamations, and
    /// questions. Written as scalar values so the set is unambiguous.
    private static let sentenceEndScalars: Set<UInt32> = [
        0x2E,    // . full stop
        0x3002,  // 。 ideographic full stop
        0x21,    // ! exclamation
        0xFF01,  // ！ full-width exclamation
        0x3F,    // ? question
        0xFF1F,  // ？ full-width question
    ]

    private static func isSentenceEnd(_ c: Character) -> Bool {
        c.unicodeScalars.count == 1 && sentenceEndScalars.contains(c.unicodeScalars.first!.value)
    }

    /// True for CJK ideographs, kana, Hangul, and CJK / full-width punctuation —
    /// the scripts that don't separate sentences with spaces.
    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            (0x3000...0x303F).contains(s.value) ||   // CJK symbols & punctuation
            (0x3040...0x30FF).contains(s.value) ||   // Hiragana + Katakana
            (0x3400...0x4DBF).contains(s.value) ||   // CJK Unified Ideographs Ext A
            (0x4E00...0x9FFF).contains(s.value) ||   // CJK Unified Ideographs
            (0xAC00...0xD7AF).contains(s.value) ||   // Hangul syllables
            (0xF900...0xFAFF).contains(s.value) ||   // CJK compatibility ideographs
            (0xFF00...0xFFEF).contains(s.value)      // full-width / half-width forms
        }
    }
}
