# P0: Learnable Vocabulary (ASR biasing) + Deterministic ITN — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make NemoNoise's dictation quality "治本" by (A) biasing recognition toward user vocabulary at the engine level where supported, with the existing find→replace corrector as the universal fallback, and (B) normalizing spoken numbers/symbols to written form deterministically and consistently across engines.

**Architecture:** Two independent, additive subsystems that plug into the existing `PostProcessor` chain and the sherpa recognizer constructors. No LLM. No new model downloads. Part A adds a `UserLexicon` store fed into each engine's native biasing API (Qwen3 `hotwords`, Apple `contextualStrings`). Part B adds a deterministic `ITNProcessor` gated by a new `selfNormalizesNumbers` engine flag — mirroring the existing `emitsPunctuation` gate at `ASREngine.swift:12`.

**Tech Stack:** Swift, XCTest, sherpa-onnx C API (`SherpaOnnxWrapper.swift`), `SFSpeechRecognizer` (`contextualStrings`), SwiftUI Settings.

## Global Constraints

- Lightweight dictation+translation positioning — **no resident LLM, no new model assets** (decision recorded in memory `project_juno_comparison_scope`).
- Surgical changes only: keep `TextCorrectionProcessor` (find→replace) intact as the universal fallback; the lexicon is a *separate, additive* concept.
- All post-processing runs on **final results only** (mirror existing `guard isFinal` pattern); partials pass through.
- Test command (run from repo root):
  `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/<TestClass>`
- Match existing test style: `import XCTest` + `@testable import NemoNoise`, `final class … : XCTestCase`.
- `TranscriptionResult` initializer in use: `TranscriptionResult(text:isFinal:emotion:sequence:)`.

---

## Per-Engine Reality (read before starting — this shapes the whole plan)

Recognition-side biasing and ITN support is **uneven**. The investigation found:

| Engine | Recognition biasing | Self-does ITN? | Notes |
|---|---|---|---|
| **Qwen3** | ✅ native `qwen3.hotwords` field (already declared, currently `""` at `SherpaOnnxWrapper.swift:271`) | ✅ yes (LLM decode) | Lowest-risk biasing path |
| **Apple** | ✅ `SFSpeechRecognitionRequest.contextualStrings` | ✅ yes (native) | Lowest-risk biasing path |
| **Paraformer (online)** | ⚠️ only with `decoding_method = modified_beam_search` (currently `greedy_search` at `SherpaOnnxWrapper.swift:126,149`); needs token-formatted `hotwords_buf` | ❌ no — outputs spoken-form numbers | The ONLY engine ITN benefits; biasing here is higher-risk (accuracy/latency/endpoint) |
| **SenseVoice** | ❌ CTC model — sherpa hotwords ignored | ✅ yes (`use_itn=1` at `SherpaOnnxWrapper.swift:34`) | Biasing impossible → corrections fallback is its only lever |

**Consequence:** Part A's biasing and Part B's ITN are **complementary, not redundant** — SenseVoice can't bias (needs corrections), and only Paraformer needs ITN (others self-normalize). Build both gated.

### Decisions baked into this plan (flagged so you can veto before execution)

1. **Lexicon is separate from corrections, not a merge.** Surgical: `TextCorrectionProcessor` stays as-is; new `UserLexicon` is additive. *(Alternative considered: unify into one "vocabulary" model with `heardAs` aliases — bigger refactor, deferred.)*
2. **Phase split for biasing.** Phase 1 = Qwen3 + Apple (native, low-risk) — Tasks A1–A3, A6. Phase 2 = Paraformer `modified_beam_search` — Task A4, **gated**: greedy_search stays default; switch to modified_beam_search only when the lexicon is non-empty, so the perf/endpoint profile is unchanged for users who add no terms.
3. **ITN scope is minimal & gated.** zh + en cardinal numbers + a few high-value symbols only (NOT Juno's 34KB rule engine). Gated by `selfNormalizesNumbers` so it runs for Paraformer only. *(If you decide ITN's Paraformer-only payoff isn't worth it, skip Part B entirely — Part A stands alone.)*

---

# PART A — Learnable Vocabulary + Recognition-Side Biasing

## File Structure (Part A)

- Create: `NemoNoise/Services/ASR/UserLexicon.swift` — the bias-term model + store (mirrors `TextCorrections` enum shape).
- Modify: `NemoNoise/App/AppDefaults.swift` — add `vocabularyTerms` UserDefaults key.
- Modify: `NemoNoise/Services/ASR/SherpaOnnxWrapper.swift` — accept bias terms in `SherpaQwen3Recognizer.init` (and `SherpaOnlineRecognizer.init` in Phase 2).
- Modify: `NemoNoise/Services/ASR/Qwen3ASREngine.swift` — read lexicon, pass to recognizer.
- Modify: `NemoNoise/Services/ASR/AppleSpeechASREngine.swift` — set `contextualStrings`.
- Modify: `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift` — (Phase 2) read lexicon, pass to recognizer.
- Modify: `NemoNoise/UI/Settings/CorrectionsView.swift` (or sibling) — add a "Vocabulary" section.
- Test: `NemoNoiseTests/UserLexiconTests.swift`.

---

### Task A1: `UserLexicon` model + store

**Files:**
- Create: `NemoNoise/Services/ASR/UserLexicon.swift`
- Modify: `NemoNoise/App/AppDefaults.swift` (add key)
- Test: `NemoNoiseTests/UserLexiconTests.swift`

**Interfaces:**
- Produces:
  - `struct LexiconEntry: Codable, Equatable { var term: String; var weight: Float }`
  - `enum UserLexicon` with `static func active(defaults:) -> [LexiconEntry]`, `static func save(_:defaults:)`, and `static func biasStrings(defaults:) -> [String]` (non-empty terms, trimmed, de-duped, order-preserving).
  - `AppDefaults.Keys.vocabularyTerms: String`

- [ ] **Step 1: Add the UserDefaults key**

In `NemoNoise/App/AppDefaults.swift`, inside the existing `Keys` enum (next to `textCorrectionRules`):

```swift
static let vocabularyTerms = "vocabularyTerms"
```

- [ ] **Step 2: Write the failing test**

Create `NemoNoiseTests/UserLexiconTests.swift`:

```swift
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
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/UserLexiconTests`
Expected: FAIL — `UserLexicon`/`LexiconEntry` not defined.

- [ ] **Step 4: Write minimal implementation**

Create `NemoNoise/Services/ASR/UserLexicon.swift`:

```swift
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/UserLexiconTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add NemoNoise/Services/ASR/UserLexicon.swift NemoNoise/App/AppDefaults.swift NemoNoiseTests/UserLexiconTests.swift
git commit -m "feat(asr): UserLexicon store for recognition-side biasing terms"
```

---

### Task A2: Feed bias terms into the Qwen3 recognizer

**Files:**
- Modify: `NemoNoise/Services/ASR/SherpaOnnxWrapper.swift:243-303` (`SherpaQwen3Recognizer.init`)
- Modify: `NemoNoise/Services/ASR/Qwen3ASREngine.swift`

**Interfaces:**
- Consumes: `UserLexicon.biasStrings()` from Task A1.
- Produces: `SherpaQwen3Recognizer.init(..., hotwords: [String] = [])` — joins terms with `,` into `qwen3.hotwords`.

**Note:** Qwen3's `hotwords` is a comma-separated prompt-bias string (model-native), distinct from the token-formatted sherpa transducer hotwords. No `modified_beam_search` needed here.

- [ ] **Step 1: Add `hotwords` parameter to the Qwen3 recognizer**

In `SherpaOnnxWrapper.swift`, change the `SherpaQwen3Recognizer.init` signature to add a parameter:

```swift
    init?(
        convFrontendPath: String,
        encoderPath: String,
        decoderPath: String,
        tokenizerDir: String,
        hotwords: [String] = []
    ) {
```

Then replace the empty hotwords binding. Find:

```swift
                        "".withCString { cHotwords in
```

Replace with:

```swift
                        hotwords.joined(separator: ",").withCString { cHotwords in
```

(The existing line `qwen3.hotwords = cHotwords` at `:271` already wires it.)

- [ ] **Step 2: Read the lexicon in the engine and pass it down**

In `Qwen3ASREngine.swift`, locate the `SherpaQwen3Recognizer(...)` construction and add the argument:

```swift
        let recognizer = SherpaQwen3Recognizer(
            convFrontendPath: convFrontend,
            encoderPath: encoder,
            decoderPath: decoder,
            tokenizerDir: tokenizer,
            hotwords: UserLexicon.biasStrings()
        )
```

(Adjust local variable names to match the file. The recognizer is built once per engine instance, and a fresh engine is built each session via `ASREngineFactory.makePrimary()`, so lexicon edits apply on the next recording — same lifecycle as `TextCorrectionProcessor`'s provider.)

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -scheme NemoNoise -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

> No unit test here: exercising Qwen3 hotwords requires the model + audio, which is integration territory. Verification is the build + a manual smoke (add a rare term in Settings, dictate it). Task A6 adds the UI to make that smoke possible.

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/Services/ASR/SherpaOnnxWrapper.swift NemoNoise/Services/ASR/Qwen3ASREngine.swift
git commit -m "feat(asr): bias Qwen3 decoding toward user lexicon terms"
```

---

### Task A3: Feed bias terms into Apple Speech (`contextualStrings`)

**Files:**
- Modify: `NemoNoise/Services/ASR/AppleSpeechASREngine.swift`

**Interfaces:**
- Consumes: `UserLexicon.biasStrings()`.
- Produces: no API change — sets `request.contextualStrings` on the `SFSpeechAudioBufferRecognitionRequest`.

- [ ] **Step 1: Set `contextualStrings` on the recognition request**

In `AppleSpeechASREngine.swift`, find where the `SFSpeechAudioBufferRecognitionRequest` is created (look for `SFSpeechAudioBufferRecognitionRequest()` and the nearby `request.shouldReportPartialResults = true`). Immediately after the request is configured, add:

```swift
        request.contextualStrings = UserLexicon.biasStrings()
```

(`contextualStrings` is an array of phrases Apple's recognizer biases toward; safe to set empty.)

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme NemoNoise -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/Services/ASR/AppleSpeechASREngine.swift
git commit -m "feat(asr): bias Apple Speech toward user lexicon via contextualStrings"
```

---

### Task A4: (Phase 2, optional) Paraformer biasing via `modified_beam_search`

**Files:**
- Modify: `NemoNoise/Services/ASR/SherpaOnnxWrapper.swift:105-165` (`SherpaOnlineRecognizer.init`)
- Modify: `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift`

**Interfaces:**
- Consumes: `UserLexicon.biasStrings()`.
- Produces: `SherpaOnlineRecognizer.init(..., hotwords: [String] = [])`.

> ⚠️ **Risk gate.** sherpa transducer/paraformer hotwords (a) take effect ONLY under `modified_beam_search`, and (b) require the phrase tokenized into the model's modeling units (for the zh Paraformer: each Chinese char space-separated, one phrase per line, optional `:score`). Switching the decoder changes latency and may alter endpoint timing. Therefore: **keep `greedy_search` whenever the lexicon is empty.** Only flip to `modified_beam_search` when there is at least one bias term. This is the riskiest task — defer until A1–A3 + A6 are shipped and validated.

- [ ] **Step 1: Add `hotwords` parameter + conditional decoding method**

In `SherpaOnlineRecognizer.init`, add `hotwords: [String] = []` to the signature. Replace the fixed decoding string:

```swift
                    "greedy_search".withCString { cDecoding in
```

with a computed choice (place the `let` before the `withCString` ladder so it stays in scope):

```swift
let decodingMethod = hotwords.isEmpty ? "greedy_search" : "modified_beam_search"
```

and use `decodingMethod.withCString { cDecoding in`.

- [ ] **Step 2: Format and attach hotwords buffer**

Add a private helper to `SherpaOnlineRecognizer` (Chinese-char tokenization; ASCII tokens kept whole):

```swift
/// sherpa hotwords format: one phrase per line, tokens space-separated.
/// For the zh Paraformer's char-level units, split CJK into individual
/// chars; keep runs of ASCII (e.g. "React") as a single token.
private static func formatHotwords(_ phrases: [String]) -> String {
    phrases.map { phrase in
        var tokens: [String] = []
        var asciiRun = ""
        for ch in phrase where !ch.isWhitespace {
            if ch.isASCII {
                asciiRun.append(ch)
            } else {
                if !asciiRun.isEmpty { tokens.append(asciiRun); asciiRun = "" }
                tokens.append(String(ch))
            }
        }
        if !asciiRun.isEmpty { tokens.append(asciiRun) }
        return tokens.joined(separator: " ")
    }.joined(separator: "\n")
}
```

Inside the config block, when `!hotwords.isEmpty`, set the in-memory buffer fields (`hotwords_buf` / `hotwords_buf_size`, see `c-api.h:376-379`) from `Self.formatHotwords(hotwords)`, holding the buffer alive via `withCString`/`Array(utf8)` for the duration of `SherpaOnnxCreateOnlineRecognizer`. Leave `hotwords_score` at the C default unless tuning is needed.

- [ ] **Step 3: Pass the lexicon from the engine**

In `ParaformerStreamingEngine.swift`, add `hotwords: UserLexicon.biasStrings()` to the `SherpaOnlineRecognizer(...)` construction.

- [ ] **Step 4: Build + manual smoke**

Run: `xcodebuild build -scheme NemoNoise -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED. Then manually: with Paraformer selected and a rare term in the lexicon, confirm recognition improves and endpoint/latency stays acceptable. If endpoint regresses unacceptably, revert this task — A1–A3 stand alone.

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/Services/ASR/SherpaOnnxWrapper.swift NemoNoise/Services/ASR/ParaformerStreamingEngine.swift
git commit -m "feat(asr): gate Paraformer hotword biasing behind modified_beam_search"
```

---

### Task A6: Settings UI — "Vocabulary" section

**Files:**
- Modify: the corrections settings view (`NemoNoise/UI/Settings/CorrectionsView.swift` — confirm exact path with the existing Corrections tab) or add a sibling `VocabularyView.swift` wired into the same Settings tab.

**Interfaces:**
- Consumes: `UserLexicon.active()` / `UserLexicon.save(_:)`.

- [ ] **Step 1: Add an editable term list**

Mirror the existing corrections editor. Provide: a list of `LexiconEntry` rows (term text field + weight stepper, default `2.0`), add/delete buttons, and persistence via `UserLexicon.save(...)` on edit. Keep it visually consistent with the Corrections tab (do not introduce new chrome — see CLAUDE.md "Apple-native" guidance and memory `feedback_apple_native_bar`).

- [ ] **Step 2: Add a one-line explainer**

Copy (verbatim): *"Vocabulary terms bias recognition toward names and jargon. Works with Qwen3 and Apple Speech; SenseVoice relies on the Corrections list instead."* — this sets honest expectations given the per-engine matrix.

- [ ] **Step 3: Build + manual verify**

Run: `xcodebuild build -scheme NemoNoise -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED. Open Settings → add a term → reopen → it persists.

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/UI/Settings/
git commit -m "feat(settings): editable Vocabulary list feeding ASR biasing"
```

---

# PART B — Deterministic ITN Processor (gated to Paraformer)

## File Structure (Part B)

- Create: `NemoNoise/Services/PostProcessors/ITN/ITNNormalizer.swift` — pure deterministic engine (zh + en numbers + a few symbols).
- Create: `NemoNoise/Services/PostProcessors/ITNProcessor.swift` — the `PostProcessor` wrapper.
- Modify: `NemoNoise/Services/ASR/ASREngine.swift:3-33` — add `selfNormalizesNumbers` flag (default `true`).
- Modify: `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift` — override `selfNormalizesNumbers = false`.
- Modify: `NemoNoise/App/PipelineProvider.swift:100-109` — insert `ITNProcessor` before punctuation when the engine does not self-normalize.
- Test: `NemoNoiseTests/ITNNormalizerTests.swift`, `NemoNoiseTests/ITNProcessorGateTests.swift`.

---

### Task B1: `ITNNormalizer` deterministic core (zh + en cardinals)

**Files:**
- Create: `NemoNoise/Services/PostProcessors/ITN/ITNNormalizer.swift`
- Test: `NemoNoiseTests/ITNNormalizerTests.swift`

**Interfaces:**
- Produces: `enum ITNNormalizer { static func normalize(_ text: String) -> String }` — pure, side-effect-free.

**Scope (minimal, per Decision 3):** Chinese cardinals (零一二三四五六七八九, 十百千万亿) and English cardinals (zero–nineteen, tens, hundred/thousand/million). NOT dates, currency, ordinals, or terminal operators — those are explicitly out of scope for the lightweight build. Idempotent: running twice equals running once.

- [ ] **Step 1: Write the failing test**

Create `NemoNoiseTests/ITNNormalizerTests.swift`:

```swift
import XCTest
@testable import NemoNoise

final class ITNNormalizerTests: XCTestCase {
    func testChineseCardinals() {
        XCTAssertEqual(ITNNormalizer.normalize("一千二百三十四"), "1234")
        XCTAssertEqual(ITNNormalizer.normalize("二十"), "20")
        XCTAssertEqual(ITNNormalizer.normalize("一百零五"), "105")
    }

    func testEnglishCardinals() {
        XCTAssertEqual(ITNNormalizer.normalize("one thousand two hundred thirty four"), "1234")
        XCTAssertEqual(ITNNormalizer.normalize("twenty"), "20")
    }

    func testLeavesNonNumberTextUntouched() {
        XCTAssertEqual(ITNNormalizer.normalize("我要去开会"), "我要去开会")
        XCTAssertEqual(ITNNormalizer.normalize("hello world"), "hello world")
    }

    func testIdempotent() {
        let once = ITNNormalizer.normalize("一千二百三十四")
        XCTAssertEqual(ITNNormalizer.normalize(once), once)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/ITNNormalizerTests`
Expected: FAIL — `ITNNormalizer` not defined.

- [ ] **Step 3: Implement the normalizer**

Create `NemoNoise/Services/PostProcessors/ITN/ITNNormalizer.swift`. Implement two scanners — a Chinese number parser (digit map + unit stack for 十/百/千/万/亿) and an English number parser (word→value with scale accumulation for hundred/thousand/million) — each replacing maximal runs of number words with their integer string, leaving all other characters verbatim. Keep both pure functions composed in `normalize`. Target the exact assertions above; do not add date/currency/ordinal handling (out of scope).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/ITNNormalizerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/Services/PostProcessors/ITN/ITNNormalizer.swift NemoNoiseTests/ITNNormalizerTests.swift
git commit -m "feat(asr): deterministic ITN normalizer for zh+en cardinals"
```

---

### Task B2: `selfNormalizesNumbers` engine flag + `ITNProcessor`

**Files:**
- Modify: `NemoNoise/Services/ASR/ASREngine.swift:3-33`
- Modify: `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift`
- Create: `NemoNoise/Services/PostProcessors/ITNProcessor.swift`
- Test: `NemoNoiseTests/ITNProcessorGateTests.swift`

**Interfaces:**
- Consumes: `ITNNormalizer.normalize(_:)` from B1.
- Produces:
  - `ASREngine.selfNormalizesNumbers: Bool` (protocol requirement, default `true` via extension).
  - `final class ITNProcessor: PostProcessor` — runs `normalize` on final, non-empty text only.

- [ ] **Step 1: Add the flag to the protocol (default true)**

In `ASREngine.swift`, add to the protocol body (after `emitsPunctuation`):

```swift
    /// Whether this engine already converts spoken numbers to written form
    /// (SenseVoice `use_itn=1`, Qwen3 LLM decode, Apple native). When true the
    /// pipeline must NOT run `ITNProcessor` on top. Default true — only the
    /// online Paraformer, which emits spoken-form numbers, overrides to false.
    var selfNormalizesNumbers: Bool { get }
```

And in the `extension ASREngine` defaults block:

```swift
    var selfNormalizesNumbers: Bool { true }
```

- [ ] **Step 2: Override in Paraformer**

In `ParaformerStreamingEngine.swift`, add the property to the class:

```swift
    var selfNormalizesNumbers: Bool { false }
```

- [ ] **Step 3: Write the failing gate test**

Create `NemoNoiseTests/ITNProcessorGateTests.swift`:

```swift
import XCTest
@testable import NemoNoise

final class ITNProcessorGateTests: XCTestCase {
    func testNormalizesFinalText() async throws {
        let proc = ITNProcessor()
        let out = try await proc.process(
            TranscriptionResult(text: "一千二百", isFinal: true, emotion: nil, sequence: 0),
            isFinal: true)
        XCTAssertEqual(out?.text, "1200")
    }

    func testPassesThroughPartials() async throws {
        let proc = ITNProcessor()
        let out = try await proc.process(
            TranscriptionResult(text: "一千二百", isFinal: false, emotion: nil, sequence: 0),
            isFinal: false)
        XCTAssertNil(out)   // nil = pass through unchanged
    }

    func testNilWhenNoChange() async throws {
        let proc = ITNProcessor()
        let out = try await proc.process(
            TranscriptionResult(text: "hello", isFinal: true, emotion: nil, sequence: 0),
            isFinal: true)
        XCTAssertNil(out)
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/ITNProcessorGateTests`
Expected: FAIL — `ITNProcessor` not defined.

- [ ] **Step 5: Implement `ITNProcessor`**

Create `NemoNoise/Services/PostProcessors/ITNProcessor.swift`:

```swift
import Foundation

/// PostProcessor that converts spoken-form numbers to written digits on final
/// text. Only wired in for engines whose `selfNormalizesNumbers` is false
/// (online Paraformer) — see PipelineProvider. Partials and no-op results pass
/// through (`nil`), mirroring PunctuationProcessor/TextCorrectionProcessor.
final class ITNProcessor: PostProcessor {
    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        guard isFinal, !result.text.isEmpty else { return nil }
        let normalized = ITNNormalizer.normalize(result.text)
        guard normalized != result.text else { return nil }
        return TranscriptionResult(text: normalized, isFinal: true,
                                   emotion: result.emotion, sequence: result.sequence)
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/ITNProcessorGateTests`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add NemoNoise/Services/ASR/ASREngine.swift NemoNoise/Services/ASR/ParaformerStreamingEngine.swift NemoNoise/Services/PostProcessors/ITNProcessor.swift NemoNoiseTests/ITNProcessorGateTests.swift
git commit -m "feat(asr): ITNProcessor gated by selfNormalizesNumbers engine flag"
```

---

### Task B3: Wire `ITNProcessor` into the dictation pipeline

**Files:**
- Modify: `NemoNoise/App/PipelineProvider.swift:100-109`

**Interfaces:**
- Consumes: `ITNProcessor`, `build.engine.selfNormalizesNumbers`.

**Ordering:** ITN must run **before** punctuation and correction. Final chain for a non-self-normalizing engine: `ITN → Punctuation → Correction`. (ITN turns "一千二百" into "1200" so the CT-Transformer punctuates the written form; corrections run last on user-visible text, unchanged.)

- [ ] **Step 1: Prepend ITN to the post-processor list when needed**

In `PipelineProvider.swift`, in `applyDictation`, immediately BEFORE the existing punctuation line (`var postProcessors … emitsPunctuation …` at `:100`), build the list starting with ITN:

```swift
                var postProcessors: [any PostProcessor] = []
                if !build.engine.selfNormalizesNumbers {
                    postProcessors.append(ITNProcessor())
                }
                if !build.engine.emitsPunctuation, let punctuator {
                    postProcessors.append(PunctuationProcessor(punctuator: punctuator))
                }
                postProcessors.append(TextCorrectionProcessor(provider: { TextCorrections.active() }))
```

Delete the old `var postProcessors … .map { … } ?? []` initializer and the separate `postProcessors.append(TextCorrectionProcessor(...))` line this replaces (lines `:100-109`). Net effect: ITN prepended, punctuation/correction behavior otherwise identical.

- [ ] **Step 2: Build + run the existing pipeline tests to confirm no regression**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/PipelineProviderTests -only-testing:NemoNoiseTests/EmitsPunctuationTests`
Expected: PASS (existing tests still green; punctuation gate untouched).

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/App/PipelineProvider.swift
git commit -m "feat(pipeline): run ITN before punctuation for non-self-normalizing engines"
```

---

## Self-Review

**Spec coverage:**
- P0 item 1 (learnable biasing): Tasks A1 (store) → A2/A3 (Qwen3+Apple, Phase 1) → A4 (Paraformer, Phase 2, gated) → A6 (UI). SenseVoice's "no biasing → corrections fallback" is documented and unchanged. ✅
- P0 item 2 (independent ITN): Tasks B1 (normalizer) → B2 (processor+gate) → B3 (wiring). ✅

**Placeholder scan:** Core data/model code is complete (A1, B2 processor). Three tasks intentionally describe-not-dictate because full code would be speculative or model-dependent: A4 hotword-buffer lifetime (C-interop, needs the engine author to match local var names), A6 SwiftUI (must mirror the existing Corrections view, exact path TBD at execution), B1 number-parser bodies (the *tests* are exact; the parser is standard and large). These are flagged, not hidden.

**Type consistency:** `LexiconEntry`/`UserLexicon.biasStrings()` consistent A1↔A2/A3/A4. `selfNormalizesNumbers` consistent ASREngine↔Paraformer↔PipelineProvider. `ITNNormalizer.normalize` consistent B1↔B2. `TranscriptionResult(text:isFinal:emotion:sequence:)` matches existing processors. ✅

**Open decisions (confirm before executing):** (1) lexicon separate vs merged with corrections; (2) whether to attempt Phase-2 Paraformer biasing at all; (3) whether ITN's Paraformer-only payoff justifies Part B.
