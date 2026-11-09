import Foundation

// Ported from cicada `Sources/Cicada/HeardText.swift` (`clean`, `fuller`),
// Copyright wquguru, Apache License 2.0 — github.com/wquguru/cicada @ 0c1dda2.
// Changes: only these two functions taken; made `nonisolated` for use from the
// Apple engine's lock-guarded state; whitespace collapsing keeps line breaks;
// a leading "-" before a digit (a negative number) is kept.
// License text: LICENSES/cicada-Apache-2.0.txt.

/// Tidying for what a recognizer heard, before it is shown, stored or inserted.
nonisolated enum HeardText {
    /// Speech recognition leaves stray marks where it hears breaths and
    /// hesitations: "in..........", ", , that", ". , that is". Collapse them,
    /// and never start a line with what was left of the last one.
    static func clean(_ text: String) -> String {
        var s = text
        // Two dots or more, with or without spaces or commas between: one ellipsis.
        s = s.replacingOccurrences(of: #"\s*[.。]{2,}|\s*…+"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"…(?:[\s,，]*…)+"#, with: "…", options: .regularExpression)
        // ", ," and ",," are one comma; a comma against an ellipsis adds nothing.
        s = s.replacingOccurrences(of: #"([,，])(?:\s*[,，])+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[,，]\s*…|…\s*[,，]"#, with: "…", options: .regularExpression)
        // "UALE ," → "UALE,".
        s = s.replacingOccurrences(of: #"\s+([,，.。…?？!！;；:：])"#, with: "$1", options: .regularExpression)
        // Runs of spaces/tabs only — dictated paragraph breaks stay.
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        let lead: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "、", "，", "。", "；", "：", "！", "？", "-", "–", "—"]
        while let first = s.first, lead.contains(first) || first.isWhitespace {
            // "-5°" is a number, not a leftover mark.
            if first == "-", s.dropFirst().first?.isNumber == true { break }
            s.removeFirst()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The final text, unless it lost a good part of what the last draft of
    /// the utterance had. In fast speech the recognizer's final pass drops
    /// whole phrases its drafts had heard (cicada issue #1). The draft may
    /// misspell a word; that beats losing five. Kept when the draft is longer
    /// by ≥3 words (≥6 CJK characters) and ≥1.15×.
    static func fuller(final: String, draft: String) -> String {
        // Words, or characters in Chinese and Japanese (about two to a word).
        let cjk = (final + draft).unicodeScalars.contains { $0.properties.isIdeographic }
        func size(_ s: String) -> Int {
            cjk ? s.filter { $0.isLetter || $0.isNumber }.count
                : s.split(whereSeparator: { $0.isWhitespace })
                    .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
        }
        let f = size(final), d = size(draft)
        guard d >= f + (cjk ? 6 : 3), Double(d) >= Double(f) * 1.15 else { return final }
        return clean(draft)
    }
}
