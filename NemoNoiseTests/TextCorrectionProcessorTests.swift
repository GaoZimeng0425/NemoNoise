import XCTest
@testable import NemoNoise

nonisolated final class TextCorrectionProcessorTests: XCTestCase {
    @MainActor private func corrected(_ text: String, _ rules: [CorrectionRule]) async -> String? {
        let p = TextCorrectionProcessor(rules: rules)
        let r = try? await p.process(
            TranscriptionResult(text: text, isFinal: true, emotion: nil), isFinal: true
        )
        return r?.text
    }

    // MARK: - CJK-mangled term replacement

    @MainActor func testReplacesCJKMangledTerm() async {
        let out = await corrected("这个u爱做得不错。", [CorrectionRule(from: "u爱", to: "UI")])
        XCTAssertEqual(out, "这个UI做得不错。")
    }

    @MainActor func testLongerRuleAppliesBeforeShorterPrefix() async {
        let out = await corrected("调用诶批艾接口", [
            CorrectionRule(from: "诶", to: "A"),
            CorrectionRule(from: "诶批艾", to: "API"),
        ])
        XCTAssertEqual(out, "调用API接口")
    }

    // MARK: - Pass-through

    @MainActor func testNoMatchReturnsNil() async throws {
        let p = TextCorrectionProcessor(rules: [CorrectionRule(from: "u爱", to: "UI")])
        let res = try await p.process(
            TranscriptionResult(text: "今天天气不错。", isFinal: true, emotion: nil), isFinal: true
        )
        XCTAssertNil(res)
    }

    @MainActor func testPartialResultsAreIgnored() async throws {
        let p = TextCorrectionProcessor(rules: [CorrectionRule(from: "u爱", to: "UI")])
        let res = try await p.process(
            TranscriptionResult(text: "u爱", isFinal: false, emotion: nil), isFinal: false
        )
        XCTAssertNil(res)
    }

    // MARK: - ASCII keys match as a standalone token only

    @MainActor func testLatinKeyNormalisesCaseAdjacentToCJK() async {
        let out = await corrected("ui设计很重要。", [CorrectionRule(from: "ui", to: "UI")])
        XCTAssertEqual(out, "UI设计很重要。")
    }

    @MainActor func testLatinKeyDoesNotMatchInsideLargerWord() async throws {
        let p = TextCorrectionProcessor(rules: [CorrectionRule(from: "ui", to: "UI")])
        let res = try await p.process(
            TranscriptionResult(text: "building blocks", isFinal: true, emotion: nil), isFinal: true
        )
        XCTAssertNil(res)
    }

    // MARK: - Metadata preserved

    @MainActor func testEmotionAndSequencePreserved() async throws {
        let p = TextCorrectionProcessor(rules: [CorrectionRule(from: "u爱", to: "UI")])
        let res = try await p.process(
            TranscriptionResult(text: "u爱", isFinal: true, emotion: "happy", sequence: 7), isFinal: true
        )
        XCTAssertEqual(res?.text, "UI")
        XCTAssertEqual(res?.emotion, "happy")
        XCTAssertEqual(res?.sequence, 7)
    }

    // MARK: - Merge & presets

    @MainActor func testMergeUserOverridesPresetAndAppendsNew() {
        let presets = [CorrectionRule(from: "u爱", to: "UI"), CorrectionRule(from: "诶批艾", to: "API")]
        let user = [CorrectionRule(from: "u爱", to: "ui"), CorrectionRule(from: "瑞艾克特", to: "React")]
        let merged = TextCorrections.merge(presets: presets, user: user)
        XCTAssertTrue(merged.contains(CorrectionRule(from: "u爱", to: "ui")))     // user wins
        XCTAssertFalse(merged.contains(CorrectionRule(from: "u爱", to: "UI")))    // preset overridden
        XCTAssertTrue(merged.contains(CorrectionRule(from: "诶批艾", to: "API")))  // preset kept
        XCTAssertTrue(merged.contains(CorrectionRule(from: "瑞艾克特", to: "React"))) // new appended
    }

    @MainActor func testPresetsIncludeReportedCase() {
        XCTAssertFalse(TextCorrections.presets.isEmpty)
        XCTAssertTrue(TextCorrections.presets.contains { $0.from == "u爱" && $0.to == "UI" })
    }
}
