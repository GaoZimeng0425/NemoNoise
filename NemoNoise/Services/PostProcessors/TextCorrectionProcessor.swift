import Foundation

/// One find→replace entry in the correction dictionary.
struct CorrectionRule: Codable, Equatable {
    let from: String
    let to: String
}

/// The correction dictionary: built-in `presets` plus user-added rules stored
/// in `UserDefaults`. `active()` is what the pipeline actually applies.
///
/// These mappings repair the most common way a Chinese-first ASR mangles inline
/// English — either by transcribing spelled letter names into homophone Hanzi
/// ("u爱" for "UI") or by emitting an acronym in the wrong case ("ui" for "UI").
/// Exact mis-transcriptions are model-dependent, so treat the presets as a seed
/// and extend them via user rules as new errors show up.
enum TextCorrections {
    static let presets: [CorrectionRule] = [
        // 1) CJK homophones of spelled-out terms (the reported failure mode).
        CorrectionRule(from: "u爱", to: "UI"),
        CorrectionRule(from: "优艾", to: "UI"),
        CorrectionRule(from: "优爱", to: "UI"),
        CorrectionRule(from: "诶批艾", to: "API"),
        CorrectionRule(from: "诶屁艾", to: "API"),
        CorrectionRule(from: "瑞艾克特", to: "React"),
        CorrectionRule(from: "歪艾", to: "Wi-Fi"),

        // 2) Case / written-form normalisation for acronyms the model already
        //    spelled in Latin but lower-cased. ASCII keys match as a standalone
        //    token (case-insensitive), so legitimate words are left untouched.
        CorrectionRule(from: "ui", to: "UI"),
        CorrectionRule(from: "ux", to: "UX"),
        CorrectionRule(from: "api", to: "API"),
        CorrectionRule(from: "url", to: "URL"),
        CorrectionRule(from: "css", to: "CSS"),
        CorrectionRule(from: "html", to: "HTML"),
        CorrectionRule(from: "json", to: "JSON"),
        CorrectionRule(from: "sql", to: "SQL"),
        CorrectionRule(from: "sdk", to: "SDK"),
        CorrectionRule(from: "ide", to: "IDE"),
        CorrectionRule(from: "cli", to: "CLI"),
        CorrectionRule(from: "http", to: "HTTP"),
        CorrectionRule(from: "https", to: "HTTPS"),
        CorrectionRule(from: "id", to: "ID"),
        CorrectionRule(from: "ok", to: "OK"),
        CorrectionRule(from: "ai", to: "AI"),

        // 3) Brand / proper-noun casing.
        CorrectionRule(from: "ios", to: "iOS"),
        CorrectionRule(from: "macos", to: "macOS"),
        CorrectionRule(from: "iphone", to: "iPhone"),
        CorrectionRule(from: "ipad", to: "iPad"),
        CorrectionRule(from: "github", to: "GitHub"),
        CorrectionRule(from: "javascript", to: "JavaScript"),
        CorrectionRule(from: "typescript", to: "TypeScript"),
    ]

    /// User rules override a preset with the same `from` and add new ones,
    /// preserving order (presets first, then new user entries).
    static func merge(presets: [CorrectionRule], user: [CorrectionRule]) -> [CorrectionRule] {
        var byFrom: [String: CorrectionRule] = [:]
        var order: [String] = []
        for rule in presets + user {
            if byFrom[rule.from] == nil { order.append(rule.from) }
            byFrom[rule.from] = rule
        }
        return order.map { byFrom[$0]! }
    }

    static func userRules(defaults: UserDefaults = .standard) -> [CorrectionRule] {
        guard let data = defaults.data(forKey: AppDefaults.Keys.textCorrectionRules),
              let rules = try? JSONDecoder().decode([CorrectionRule].self, from: data) else {
            return []
        }
        return rules
    }

    static func active(defaults: UserDefaults = .standard) -> [CorrectionRule] {
        merge(presets: presets, user: userRules(defaults: defaults))
    }
}

/// `PostProcessor` that applies the correction dictionary to final ASR text.
/// Partials pass through untouched — corrections only make sense on settled text.
final class TextCorrectionProcessor: PostProcessor {
    private let provider: @Sendable () -> [CorrectionRule]

    /// Fixed rule set — used by tests and static configs.
    init(rules: [CorrectionRule]) {
        self.provider = { rules }
    }

    /// Dynamic rule set, re-read on every final result so edits made in Settings
    /// take effect on the next utterance without rebuilding the pipeline.
    init(provider: @escaping @Sendable () -> [CorrectionRule]) {
        self.provider = provider
    }

    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        guard isFinal, !result.text.isEmpty else { return nil }
        // Longest source first so a longer phrase isn't pre-empted by a prefix
        // rule ("诶批艾"→"API" must win over "诶"→"A").
        let rules = provider()
            .filter { !$0.from.isEmpty }
            .sorted { $0.from.count > $1.from.count }
        guard !rules.isEmpty else { return nil }
        var text = result.text
        for rule in rules {
            text = Self.apply(rule, to: text)
        }
        guard text != result.text else { return nil }
        return TranscriptionResult(text: text, isFinal: true, emotion: result.emotion, sequence: result.sequence)
    }

    private static func apply(_ rule: CorrectionRule, to text: String) -> String {
        guard rule.from.allSatisfy(\.isASCII) else {
            // CJK / mixed key: plain substring replace (no word boundaries in CJK).
            return text.replacingOccurrences(of: rule.from, with: rule.to)
        }
        // Pure-ASCII key: match as a standalone token — abutting ASCII letters or
        // digits block the match (so "ui" won't fire inside "building"), while
        // CJK, spaces and string edges count as boundaries. Case-insensitive so
        // "ui" / "Ui" / "UI" all normalise to the canonical form.
        let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: rule.from) + "(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text.replacingOccurrences(of: rule.from, with: rule.to)
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: rule.to)
        )
    }
}
