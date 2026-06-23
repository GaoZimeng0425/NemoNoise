import Foundation

/// One user-taught vocabulary term that should be biased toward at recognition
/// time (where the engine supports it). Unlike `CorrectionRule` (find→replace
/// applied AFTER decoding), a lexicon term nudges the decoder to produce the
/// term in the first place. Engines without biasing support ignore it and rely
/// on the correction dictionary instead.
struct LexiconEntry: Codable, Equatable {
    var term: String
    var weight: Float   // bias strength; engine-specific scaling. Default 2.0.
}

enum UserLexicon {
    static func active(defaults: UserDefaults = .standard) -> [LexiconEntry] {
        guard let data = defaults.data(forKey: AppDefaults.Keys.vocabularyTerms),
              let entries = try? JSONDecoder().decode([LexiconEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func save(_ entries: [LexiconEntry], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: AppDefaults.Keys.vocabularyTerms)
    }

    /// Cleaned, de-duplicated, order-preserving term list for feeding into an
    /// engine's biasing API.
    static func biasStrings(defaults: UserDefaults = .standard) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in active(defaults: defaults) {
            let t = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !seen.contains(t) else { continue }
            seen.insert(t)
            out.append(t)
        }
        return out
    }
}
