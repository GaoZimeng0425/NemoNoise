import XCTest
@testable import NemoNoise

/// Literal tables for the two decode-hallucination heuristics and the bias
/// composition, per `DecodeGuards`/`DecodeBias` docs: a prompt-driven decoder
/// fed noise can answer with the bias list itself or an echo of the prior.
nonisolated final class DecodeGuardsTests: XCTestCase {
    // MARK: - isLexiconDump

    @MainActor func testDumpDetectedWhenTermsCoverTheOutput() {
        let terms = ["Claude Code", "Codex", "blurt"]
        XCTAssertTrue(DecodeGuards.isLexiconDump("Claude Code、Codex、blurt", terms: terms))
        XCTAssertTrue(DecodeGuards.isLexiconDump("Claude Code, Codex, blurt", terms: terms))
        XCTAssertTrue(DecodeGuards.isLexiconDump("豆包、通义千问、文心一言", terms: ["豆包", "通义千问", "文心一言"]))
    }

    @MainActor func testRealSpeechNamingTermsIsNotADump() {
        let terms = ["Claude Code", "Codex", "blurt"]
        // Connective words keep the coverage under the threshold.
        XCTAssertFalse(DecodeGuards.isLexiconDump("我用 Claude Code 和 Codex 的时候都比 blurt 顺手", terms: terms))
        // Two terms are not enough.
        XCTAssertFalse(DecodeGuards.isLexiconDump("Claude Code 和 Codex 都很好用", terms: terms))
        // Empty text / empty terms never dump.
        XCTAssertFalse(DecodeGuards.isLexiconDump("", terms: terms))
        XCTAssertFalse(DecodeGuards.isLexiconDump("Claude Code、Codex、blurt", terms: []))
    }

    // MARK: - echoesPrior

    @MainActor func testEchoDetectedWhenPriorTailReproducedOnShortAudio() {
        // 10 characters on 96 ms of audio: impossible to have been spoken.
        XCTAssertTrue(DecodeGuards.echoesPrior("我今天用了豆包写代码", prior: "开始录音。我今天用了豆包写代码",
                                               audioSeconds: 0.096))
    }

    @MainActor func testEchoNotDetectedForPlausibleSpeech() {
        // Long enough audio for the text.
        XCTAssertFalse(DecodeGuards.echoesPrior("我今天用了豆包写代码", prior: "开始录音。我今天用了豆包写代码",
                                                audioSeconds: 2.0))
        // Text diverges from the prior tail.
        XCTAssertFalse(DecodeGuards.echoesPrior("明天去爬山", prior: "我今天用了豆包写代码", audioSeconds: 0.096))
        // Short text within plausible speaking rate.
        XCTAssertFalse(DecodeGuards.echoesPrior("好", prior: "……很好", audioSeconds: 0.5))
        // Empty inputs.
        XCTAssertFalse(DecodeGuards.echoesPrior("", prior: "前文", audioSeconds: 1.0))
        XCTAssertFalse(DecodeGuards.echoesPrior("今天很好", prior: "", audioSeconds: 0.096))
    }

    // MARK: - DecodeBias.compose

    @MainActor func testComposeCombinesTermsAndPriorTail() {
        // A short prior fits whole; only long priors are cut to their tail.
        XCTAssertEqual(DecodeBias.compose(terms: ["豆包", "Claude Code"], prior: "尾巴"),
                       "豆包, Claude Code; 尾巴")
        XCTAssertEqual(DecodeBias.compose(terms: ["豆包"], prior: ""), "豆包")
        XCTAssertEqual(DecodeBias.compose(terms: [], prior: "只有前文。"), "只有前文。")
        XCTAssertNil(DecodeBias.compose(terms: [], prior: ""))
        XCTAssertNil(DecodeBias.compose(terms: [""], prior: "  "))
    }

    @MainActor func testComposeCapsThePriorToItsTail() {
        let long = String(repeating: "字", count: DecodeBias.priorLimit + 10)
        XCTAssertEqual(DecodeBias.compose(terms: [], prior: long),
                       String(repeating: "字", count: DecodeBias.priorLimit))
        XCTAssertEqual(DecodeBias.compose(terms: [], prior: "头" + long, priorLimit: 3), "字字字")
    }
}
