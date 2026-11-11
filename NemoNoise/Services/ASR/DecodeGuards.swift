import Foundation

/// Composes the per-decode bias text for engines that accept one (Qwen3's
/// per-stream hotwords). The VAD-segmented decode path calls this before each
/// segment so the decoder sees the session's confirmed transcript so far —
/// each segment is otherwise decoded as an isolated utterance, which lets a
/// name drift between segments (豆包 in one, 德宝 in the next).
nonisolated enum DecodeBias {
    /// Characters of prior transcript kept in the bias. Qwen3's decode budget
    /// (`max_total_len` 512) is shared between prompt and audio tokens (~8 per
    /// second of speech), so a 15 s segment leaves room for roughly this much
    /// prompt text.
    static let priorLimit = 120

    /// - Parameters:
    ///   - terms: cleaned lexicon terms (`UserLexicon.biasStrings()` — already
    ///     comma-free so they survive sherpa's comma-separated hotword format).
    ///   - prior: the session's confirmed transcript so far; only its tail is used.
    ///   - priorLimit: tail cut, overridable for tests.
    /// - Returns: the bias string, or nil when there is nothing to bias with.
    static func compose(terms: [String], prior: String, priorLimit: Int = DecodeBias.priorLimit) -> String? {
        let termsPart = terms.filter { !$0.isEmpty }.joined(separator: ", ")
        let priorPart = String(prior.suffix(priorLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch (termsPart.isEmpty, priorPart.isEmpty) {
        case (false, false): return termsPart + "; " + priorPart
        case (false, true): return termsPart
        case (true, false): return priorPart
        case (true, true): return nil
        }
    }
}

/// Heuristics that catch the two ways a prompt-driven decoder (Qwen3-ASR)
/// hallucinates instead of transcribing, observed in reference-project
/// dogfooding on noisy audio the model could not make out:
///
///  * **lexicon dump** — the output enumerates the bias terms themselves
///    ("Claude Code、Codex、blurt") rather than any speech;
///  * **prior echo** — the output reproduces the prior transcript instead of
///    the (short) audio it was given.
///
/// Both only *trigger* a second decode with a reduced bias; the acceptance
/// rules (not a dump / clearly shorter) decide whether the retry's text is
/// used, so a false positive costs one decode, never the real transcript.
nonisolated enum DecodeGuards {
    /// Distinct lexicon terms that must appear in the output before it can
    /// count as a dump.
    static let lexiconDumpMinTerms = 3
    /// Fraction of the output's normalized characters that matched terms must
    /// cover for a dump. A real dump is terms plus separators only (~1.0 —
    /// separators vanish under normalization); real speech naming three terms
    /// still carries a third connective characters and must not fire.
    static let lexiconDumpCoverage = 0.8
    /// How much of the output must match the prior's tail (longest common
    /// suffix) to look like an echo.
    static let echoSuffixRatio = 0.8
    /// Fastest plausible dictation (CJK characters per second of audio).
    /// Output longer than audio × this was not spoken in that audio.
    static let echoMaxCharsPerSecond = 30.0
    /// A retry after an echo is only accepted when it is clearly shorter
    /// than the original (a speaker who genuinely repeats themself gets the
    /// same text back, and the original must survive).
    static let echoAcceptRatio = 0.8

    /// Lowercased letters/numbers only — punctuation, whitespace, and symbols
    /// dropped, so "Claude Code、Codex!" and "claude code codex" compare equal.
    private static func normalized(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// True when `text` looks like the lexicon itself read back: at least
    /// `lexiconDumpMinTerms` distinct terms appear, and together they cover
    /// at least `lexiconDumpCoverage` of the normalized text.
    static func isLexiconDump(_ text: String, terms: [String]) -> Bool {
        let normalizedText = normalized(text)
        guard normalizedText.count >= lexiconDumpMinTerms else { return false }
        let matched = terms
            .map { normalized($0) }
            .filter { !$0.isEmpty && normalizedText.contains($0) }
        guard matched.count >= lexiconDumpMinTerms else { return false }
        let covered = matched.reduce(0) { $0 + Swift.min($1.count, normalizedText.count) }
        return Double(covered) >= lexiconDumpCoverage * Double(normalizedText.count)
    }

    /// True when `text` reproduces the tail of `prior` and is too long for
    /// the segment's audio — the decoder echoed its context instead of
    /// listening.
    static func echoesPrior(_ text: String, prior: String, audioSeconds: TimeInterval) -> Bool {
        let normalizedText = normalized(text)
        let normalizedPrior = normalized(prior)
        guard !normalizedText.isEmpty, !normalizedPrior.isEmpty, audioSeconds > 0 else { return false }
        guard Double(normalizedText.count) > audioSeconds * echoMaxCharsPerSecond else { return false }
        let common = zip(normalizedText.reversed(), normalizedPrior.reversed())
            .prefix { $0.0 == $0.1 }
            .count
        return Double(common) >= echoSuffixRatio * Double(normalizedText.count)
    }
}
