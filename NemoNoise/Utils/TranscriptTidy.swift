import Foundation

/// Cleanup for recognizer output before it is shown, stored or inserted.
nonisolated enum TranscriptTidy {

    // MARK: - tidy

    private static let dots: Set<Character> = [".", "。"]
    private static let commas: Set<Character> = [",", "，"]
    /// Marks that never take a space before them and never start a line.
    private static let marks: Set<Character> = [
        ".", "。", ",", "，", "、", "…", "?", "？", "!", "！", ";", "；", ":", "："
    ]
    private static let dashes: Set<Character> = ["-", "–", "—"]

    /// Removes what recognizers leave around real words: a mark carried over
    /// from the previous sentence at the start ("。下一句"), a space before a
    /// mark ("先这样 ，再看"), dot runs from breaths ("我想想。。。"), doubled
    /// commas, a comma against an ellipsis, and runs of spaces. Line breaks
    /// and single dots inside text ("2.5", "p.m.") are left alone.
    static func tidy(_ text: String) -> String {
        var out: [Character] = []
        var pendingSpace = false
        let chars = Array(text)
        var i = 0

        func append(_ c: Character) {
            if pendingSpace, let last = out.last, last != "\n" { out.append(" ") }
            pendingSpace = false
            out.append(c)
        }
        /// Last non-space character written (pending space aside).
        func lastWritten() -> Character? { out.last }

        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" {
                pendingSpace = true
                i += 1
                continue
            }
            if c == "\n" || c == "\r" {
                pendingSpace = false
                out.append(c)
                i += 1
                continue
            }

            let startsDotRun = dots.contains(c) && i + 1 < chars.count && dots.contains(chars[i + 1])
            if c == "…" || startsDotRun {
                // Swallow the whole run, including spaces/commas between dots
                // and further ellipses: one pause, one ellipsis.
                var j = i + 1
                while j < chars.count,
                      dots.contains(chars[j]) || chars[j] == "…"
                        || ((chars[j] == " " || commas.contains(chars[j])) && j + 1 < chars.count
                            && (dots.contains(chars[j + 1]) || chars[j + 1] == "…")) {
                    j += 1
                }
                pendingSpace = false
                if let last = lastWritten(), commas.contains(last) { out.removeLast() }
                if lastWritten() != "…" { out.append("…") }
                i = j
                continue
            }

            if commas.contains(c) {
                pendingSpace = false
                // ",," / ", ," keep one; a comma right after an ellipsis adds nothing.
                if let last = lastWritten(), commas.contains(last) || last == "…" {
                    i += 1
                    continue
                }
                out.append(c)
                i += 1
                continue
            }

            if marks.contains(c) {
                pendingSpace = false
                out.append(c)
                i += 1
                continue
            }

            append(c)
            i += 1
        }

        // Nothing real starts with a mark; a leading dash stays only as the
        // sign of a number ("-3度").
        var start = 0
        while start < out.count {
            let c = out[start]
            if dashes.contains(c), start + 1 < out.count, out[start + 1].isNumber { break }
            guard marks.contains(c) || dashes.contains(c) || c.isWhitespace else { break }
            start += 1
        }
        return String(out[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - recoverDroppedWords

    /// SpeechAnalyzer's final pass can lose phrases its last draft of the same
    /// utterance had (fast speech). Returns the tidied draft when it carries
    /// clearly more content — at least 6 units more and 20 % more — otherwise
    /// the final. A misheard word in the draft costs less than a lost phrase.
    /// Callers must only pass a draft that covers the final's range, not audio
    /// past it.
    static func recoverDroppedWords(final: String, draft: String) -> String {
        let finalUnits = contentUnits(final)
        let draftUnits = contentUnits(draft)
        guard draftUnits >= finalUnits + 6,
              Double(draftUnits) >= Double(finalUnits) * 1.2 else { return final }
        return tidy(draft)
    }

    /// Rough amount of speech in `text`: each CJK character (ideograph, kana,
    /// hangul) counts 1; each run of Latin letters or digits — about one
    /// spoken word — counts 2, so mixed text compares on one scale.
    static func contentUnits(_ text: String) -> Int {
        var units = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                units += 1
                inWord = false
            } else if scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
                if !inWord { units += 2 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return units
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
