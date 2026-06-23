import XCTest
@testable import NemoNoise

final class UserLexiconTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "UserLexiconTests.\(UUID().uuidString)")!
        return d
    }

    func testActiveIsEmptyByDefault() {
        XCTAssertEqual(UserLexicon.active(defaults: makeDefaults()), [])
    }

    func testSaveThenActiveRoundTrips() {
        let d = makeDefaults()
        let entries = [LexiconEntry(term: "NemoNoise", weight: 2.0),
                       LexiconEntry(term: "sherpa-onnx", weight: 3.0)]
        UserLexicon.save(entries, defaults: d)
        XCTAssertEqual(UserLexicon.active(defaults: d), entries)
    }

    func testBiasStringsTrimsDropsEmptyAndDedupesPreservingOrder() {
        let d = makeDefaults()
        UserLexicon.save([
            LexiconEntry(term: "  React  ", weight: 2),
            LexiconEntry(term: "", weight: 2),
            LexiconEntry(term: "React", weight: 5),     // duplicate after trim
            LexiconEntry(term: "Qwen3", weight: 2),
        ], defaults: d)
        XCTAssertEqual(UserLexicon.biasStrings(defaults: d), ["React", "Qwen3"])
    }

    func testBiasStringsStripsCommasToProtectQwen3Format() {
        let d = makeDefaults()
        UserLexicon.save([LexiconEntry(term: "Goodman, Sachs", weight: 2)], defaults: d)
        XCTAssertEqual(UserLexicon.biasStrings(defaults: d), ["Goodman Sachs"])
    }
}
