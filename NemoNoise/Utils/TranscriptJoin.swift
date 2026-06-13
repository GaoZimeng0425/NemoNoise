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
enum TranscriptJoin {
    static func sentences(_ pieces: [String]) -> String {
        var out = ""
        for raw in pieces {
            let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            guard let lhs = out.last, let rhs = piece.first else {
                out = piece
                continue
            }
            if isCJK(lhs) || isCJK(rhs) {
                out += piece
            } else {
                out += " " + piece
            }
        }
        return out
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
