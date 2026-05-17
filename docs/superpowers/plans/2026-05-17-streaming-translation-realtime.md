# Streaming Translation Realtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make translation-mode subtitles arrive within 2-4s of corresponding English audio under continuous speech by adding a pipeline-level `SentenceSegmenter` and converting translation to fire-and-forget async with seq-tagged back-fill.

**Architecture:** Three new/changed pipeline components: (1) `SentenceSegmenter` PostProcessor force-segments partials by silence, hard limit, sentence terminator, or engine-native isFinal; (2) `AsyncTranslateProcessor` spawns detached Task per final, returns English synchronously, back-fills Chinese asynchronously via new `SubtitleWriter.applyTranslation(seq:chinese:)`; (3) `SentenceSegmenter` hints engines via new `ASREngine.markBoundary()` (default no-op; Paraformer resets stream).

**Tech Stack:** Swift 6 / SwiftUI / Swift Concurrency / XCTest. Pure Foundation for segmenter (no sherpa-onnx coupling).

**Reference spec:** `docs/superpowers/specs/2026-05-17-streaming-translation-realtime-design.md`

**Refinement from spec:** Segmenter resets all per-session timers (not just cursor) when it detects engine text shrinkage. This handles both Apple Speech rewrites AND new-session warm-start. Avoids needing a new `PostProcessor.reset()` protocol method.

---

## File Structure

**Create:**
- `NemoNoise/Services/PostProcessors/SentenceSegmenter.swift` — force-segmentation logic
- `NemoNoise/Services/PostProcessors/AsyncTranslateProcessor.swift` — replaces `TranslateProcessor.swift`
- `NemoNoiseTests/SentenceSegmenterTests.swift` — segmenter rule coverage
- `NemoNoiseTests/AsyncTranslateProcessorTests.swift` — replaces `TranslateProcessorTests.swift`

**Modify:**
- `NemoNoise/Models/TranscriptionResult.swift` — add `sequence: Int?`
- `NemoNoise/Services/ASR/ASREngine.swift` — add `markBoundary()` with default
- `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift` — override `markBoundary()`
- `NemoNoise/Services/Sinks/SubtitleOverlaySink.swift` — seq-gated final render, clear chineseText, set displayedSeq; protocol extension
- `NemoNoise/App/TranslationController.swift` — extended `SubtitleWriter` conformance: `isTranslating`, `displayedSeq`, `applyTranslation`; reset on stop
- `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift` — three-state Chinese-line render
- `NemoNoise/App/PipelineProvider.swift` — install segmenter + async translate processor
- `NemoNoiseTests/SubtitleOverlaySinkTests.swift` — extend `StubSubtitleTarget`; add seq-gated tests

**Delete:**
- `NemoNoise/Services/PostProcessors/TranslateProcessor.swift`
- `NemoNoiseTests/TranslateProcessorTests.swift`

---

## Phase 1 — Foundation: sequence field + markBoundary protocol

### Task 1.1: Add `sequence: Int?` to `TranscriptionResult`

**Files:**
- Modify: `NemoNoise/Models/TranscriptionResult.swift`

- [ ] **Step 1: Update the struct**

Replace the existing struct with:

```swift
struct TranscriptionResult: Sendable {
    let text: String
    let isFinal: Bool
    let emotion: String?
    let originalText: String?
    let sequence: Int?

    init(
        text: String,
        isFinal: Bool,
        emotion: String?,
        originalText: String? = nil,
        sequence: Int? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.emotion = emotion
        self.originalText = originalText
        self.sequence = sequence
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' build -quiet`
Expected: success. All existing call sites continue to compile because `sequence` defaults to `nil`.

### Task 1.2: Add `markBoundary()` to `ASREngine` protocol

**Files:**
- Modify: `NemoNoise/Services/ASR/ASREngine.swift`

- [ ] **Step 1: Add protocol requirement + default implementation**

Replace the file contents with:

```swift
import Foundation

protocol ASREngine: AnyObject, Sendable {
    /// Whether this engine streams results in real time.
    var isStreaming: Bool { get }

    /// Feed one audio chunk during recording. Returns a partial result (may be empty).
    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult

    /// Called when recording stops. Returns the final transcription.
    func finish() async throws -> TranscriptionResult

    /// Reset internal state before a new recording session.
    func reset()

    /// Hint that the pipeline has force-segmented the current utterance.
    /// Engines that maintain accumulated decoder state across chunks should
    /// reset that state without ending the stream. Default: no-op.
    func markBoundary()
}

extension ASREngine {
    var isStreaming: Bool { true }
    func markBoundary() {}
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' build -quiet`
Expected: success.

### Task 1.3: Override `markBoundary()` in `ParaformerStreamingEngine`

**Files:**
- Modify: `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift`

- [ ] **Step 1: Add the override**

After the `reset()` method, insert:

```swift
    func markBoundary() {
        recognizer.resetStream()
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' build -quiet`
Expected: success.

- [ ] **Step 3: Run existing tests**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/ParaformerStreamingEngineTests -quiet`
Expected: PASS. (Existing tests do not exercise markBoundary; they continue to pass.)

### Task 1.4: Commit Phase 1

- [ ] **Step 1: Stage and commit**

```bash
git add NemoNoise/Models/TranscriptionResult.swift \
        NemoNoise/Services/ASR/ASREngine.swift \
        NemoNoise/Services/ASR/ParaformerStreamingEngine.swift

git commit -m "$(cat <<'EOF'
feat(pipeline): add TranscriptionResult.sequence + ASREngine.markBoundary

Foundation for pipeline-level sentence segmentation. The sequence field
identifies which forced segment a result belongs to (nil for results not
produced by the segmenter). markBoundary lets the segmenter hint engines
to drop accumulated context without ending the stream; Paraformer
overrides to call resetStream, all others use the default no-op.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — SentenceSegmenter

The segmenter is written test-first. Each rule gets its own test before the implementation grows to support it. Tests inject a mutable `now` closure to drive time-based logic deterministically.

### Task 2.1: Stub the segmenter so tests can target it

**Files:**
- Create: `NemoNoise/Services/PostProcessors/SentenceSegmenter.swift`

- [ ] **Step 1: Write the initial stub**

```swift
import Foundation

/// Pipeline-level sentence segmenter. Converts the partial/final stream
/// from an ASR engine into a stream of bounded segments suitable for
/// downstream translation. See
/// `docs/superpowers/specs/2026-05-17-streaming-translation-realtime-design.md`.
///
/// Single-consumer: the pipeline owns the instance and calls `process` serially.
final class SentenceSegmenter: PostProcessor, @unchecked Sendable {
    private let silenceThreshold: TimeInterval = 0.8
    private let maxSegmentDuration: TimeInterval = 6.0
    private let sentenceEnders: Set<Character> = [".", "?", "!", "。", "?", "!"]

    private let engine: any ASREngine
    private let now: @Sendable () -> Date

    private var currentSeq: Int = 0
    private var consumedTextLength: Int = 0
    private var segmentStartTime: Date
    private var lastPartialChangeTime: Date
    private var lastPartialText: String = ""

    init(engine: any ASREngine, now: @escaping @Sendable () -> Date = { Date() }) {
        self.engine = engine
        self.now = now
        let n = now()
        self.segmentStartTime = n
        self.lastPartialChangeTime = n
    }

    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        // Implementation grows test-by-test.
        return nil
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' build -quiet`
Expected: success.

### Task 2.2: Empty result passes through as nil

**Files:**
- Create: `NemoNoiseTests/SentenceSegmenterTests.swift`

- [ ] **Step 1: Write the test scaffolding + first test**

```swift
import XCTest
@testable import NemoNoise

@MainActor
final class StubASREngine: ASREngine, @unchecked Sendable {
    var isStreaming: Bool = true
    var markBoundaryCalls: Int = 0

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        TranscriptionResult(text: "", isFinal: false, emotion: nil)
    }
    func finish() async throws -> TranscriptionResult {
        TranscriptionResult(text: "", isFinal: true, emotion: nil)
    }
    func reset() {}
    func markBoundary() { markBoundaryCalls += 1 }
}

final class SentenceSegmenterTests: XCTestCase {

    private final class FakeClock: @unchecked Sendable {
        var current: Date = Date(timeIntervalSinceReferenceDate: 0)
        var read: @Sendable () -> Date { { [weak self] in self?.current ?? Date() } }
        func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    @MainActor
    private func makeSegmenter(_ clock: FakeClock = FakeClock()) -> (SentenceSegmenter, StubASREngine, FakeClock) {
        let engine = StubASREngine()
        let segmenter = SentenceSegmenter(engine: engine, now: clock.read)
        return (segmenter, engine, clock)
    }

    @MainActor
    func testEmptyResultReturnsNil() async throws {
        let (segmenter, _, _) = makeSegmenter()
        let out = try await segmenter.process(
            TranscriptionResult(text: "", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertNil(out)
    }
}
```

- [ ] **Step 2: Run the test**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/SentenceSegmenterTests/testEmptyResultReturnsNil -quiet`
Expected: PASS (the stub returns nil unconditionally).

### Task 2.3: Engine-native isFinal passes through with new seq

- [ ] **Step 1: Add the test**

Append inside `SentenceSegmenterTests`:

```swift
    @MainActor
    func testEngineNativeFinalPassesThroughWithSeq() async throws {
        let (segmenter, _, _) = makeSegmenter()
        let input = TranscriptionResult(text: "Hello world.", isFinal: true, emotion: nil)
        let out = try await segmenter.process(input, isFinal: true)
        XCTAssertEqual(out?.text, "Hello world.")
        XCTAssertEqual(out?.isFinal, true)
        XCTAssertEqual(out?.sequence, 1)
    }
```

- [ ] **Step 2: Run, expect FAIL**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/SentenceSegmenterTests/testEngineNativeFinalPassesThroughWithSeq -quiet`
Expected: FAIL — segmenter returns nil regardless of input.

- [ ] **Step 3: Implement empty + engine-final handling**

Replace the body of `SentenceSegmenter.process` with:

```swift
    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        if result.text.isEmpty { return nil }

        if isFinal {
            currentSeq += 1
            let out = TranscriptionResult(
                text: result.text,
                isFinal: true,
                emotion: result.emotion,
                originalText: result.originalText,
                sequence: currentSeq
            )
            resetSegmentState()
            return out
        }

        return nil
    }

    private func resetSegmentState() {
        consumedTextLength = 0
        let n = now()
        segmentStartTime = n
        lastPartialChangeTime = n
        lastPartialText = ""
    }
```

- [ ] **Step 4: Run, expect PASS**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/SentenceSegmenterTests/testEngineNativeFinalPassesThroughWithSeq -quiet`
Expected: PASS.

### Task 2.4: Partial passes through with upcoming seq

- [ ] **Step 1: Add the test**

```swift
    @MainActor
    func testPartialPropagatesUpcomingSeq() async throws {
        let (segmenter, _, _) = makeSegmenter()
        let out = try await segmenter.process(
            TranscriptionResult(text: "hel", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(out?.text, "hel")
        XCTAssertEqual(out?.isFinal, false)
        XCTAssertEqual(out?.sequence, 1, "partial belongs to the next-to-be-emitted seq")
    }
```

- [ ] **Step 2: Run, expect FAIL**

Run: `xcodebuild test ... -only-testing:NemoNoiseTests/SentenceSegmenterTests/testPartialPropagatesUpcomingSeq -quiet`
Expected: FAIL — current implementation still returns nil for partials.

- [ ] **Step 3: Add partial-passthrough**

Replace the trailing `return nil` in `process` with:

```swift
        // Partial path.
        let fullCount = result.text.count
        let delta = String(result.text.dropFirst(consumedTextLength))

        if delta != lastPartialText {
            lastPartialText = delta
            lastPartialChangeTime = now()
        }
        _ = fullCount  // will be used by force-segment rules in later tasks

        // Transparent partial — upcoming seq is currentSeq + 1.
        return TranscriptionResult(
            text: delta,
            isFinal: false,
            emotion: result.emotion,
            originalText: result.originalText,
            sequence: currentSeq + 1
        )
```

- [ ] **Step 4: Run, expect PASS**

Run: `xcodebuild test ... -only-testing:NemoNoiseTests/SentenceSegmenterTests/testPartialPropagatesUpcomingSeq -quiet`
Expected: PASS.

### Task 2.5: Sentence-ender triggers force-segment

- [ ] **Step 1: Add the test**

```swift
    @MainActor
    func testSentenceEnderForcesSegment() async throws {
        let (segmenter, engine, _) = makeSegmenter()
        // Accumulate partial without ending punctuation.
        _ = try await segmenter.process(
            TranscriptionResult(text: "Hello world", isFinal: false, emotion: nil),
            isFinal: false
        )
        // Next partial adds a period at the end.
        let out = try await segmenter.process(
            TranscriptionResult(text: "Hello world.", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(out?.text, "Hello world.")
        XCTAssertEqual(out?.isFinal, true)
        XCTAssertEqual(out?.sequence, 1)
        XCTAssertEqual(engine.markBoundaryCalls, 1)
    }
```

- [ ] **Step 2: Run, expect FAIL**

Expected: FAIL — partial is propagated as-is, no force-segment.

- [ ] **Step 3: Implement force-segment rules**

Replace the `process` body with the full implementation:

```swift
    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        if result.text.isEmpty { return nil }

        if isFinal {
            currentSeq += 1
            let out = TranscriptionResult(
                text: result.text,
                isFinal: true,
                emotion: result.emotion,
                originalText: result.originalText,
                sequence: currentSeq
            )
            resetSegmentState()
            return out
        }

        // Partial path — compute delta from cursor.
        let fullCount = result.text.count
        if fullCount < consumedTextLength {
            // Engine rewrote / shrunk OR new session warm-start. Reset all per-segment state.
            resetSegmentState()
        }
        let delta = String(result.text.dropFirst(consumedTextLength))

        if delta != lastPartialText {
            lastPartialText = delta
            lastPartialChangeTime = now()
        }

        let trimmed = delta.trimmingCharacters(in: .whitespaces)
        let endsWithSentenceEnder = trimmed.last.map { sentenceEnders.contains($0) } ?? false
        let n = now()
        let exceededHardLimit = n.timeIntervalSince(segmentStartTime) > maxSegmentDuration
        let stalledForSilence = !delta.isEmpty
            && n.timeIntervalSince(lastPartialChangeTime) > silenceThreshold

        if endsWithSentenceEnder || exceededHardLimit || stalledForSilence {
            currentSeq += 1
            let out = TranscriptionResult(
                text: delta,
                isFinal: true,
                emotion: result.emotion,
                originalText: result.originalText,
                sequence: currentSeq
            )
            consumedTextLength = fullCount
            engine.markBoundary()
            segmentStartTime = n
            lastPartialChangeTime = n
            lastPartialText = ""
            return out
        }

        return TranscriptionResult(
            text: delta,
            isFinal: false,
            emotion: result.emotion,
            originalText: result.originalText,
            sequence: currentSeq + 1
        )
    }
```

- [ ] **Step 4: Run, expect PASS**

Run: `xcodebuild test ... -only-testing:NemoNoiseTests/SentenceSegmenterTests/testSentenceEnderForcesSegment -quiet`
Expected: PASS.

- [ ] **Step 5: Run the full segmenter suite**

Run: `xcodebuild test ... -only-testing:NemoNoiseTests/SentenceSegmenterTests -quiet`
Expected: All 4 prior tests still PASS.

### Task 2.6: Hard limit (6s) triggers force-segment

- [ ] **Step 1: Add the test**

```swift
    @MainActor
    func testHardLimitForcesSegment() async throws {
        let clock = FakeClock()
        let (segmenter, engine, _) = makeSegmenter(clock)

        _ = try await segmenter.process(
            TranscriptionResult(text: "this is one", isFinal: false, emotion: nil),
            isFinal: false
        )
        // Advance past the 6s hard limit and feed another partial that still has no terminator.
        clock.advance(6.5)
        let out = try await segmenter.process(
            TranscriptionResult(text: "this is one long sentence with no end", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(out?.isFinal, true, "should force-segment when elapsed > 6s")
        XCTAssertEqual(out?.text, "this is one long sentence with no end")
        XCTAssertEqual(out?.sequence, 1)
        XCTAssertEqual(engine.markBoundaryCalls, 1)
    }
```

- [ ] **Step 2: Run, expect PASS**

Run: `xcodebuild test ... -only-testing:NemoNoiseTests/SentenceSegmenterTests/testHardLimitForcesSegment -quiet`
Expected: PASS (rule already implemented in Task 2.5).

### Task 2.7: Silence (0.8s) triggers force-segment

- [ ] **Step 1: Add the test**

```swift
    @MainActor
    func testSilenceForcesSegment() async throws {
        let clock = FakeClock()
        let (segmenter, engine, _) = makeSegmenter(clock)

        _ = try await segmenter.process(
            TranscriptionResult(text: "speaker said something", isFinal: false, emotion: nil),
            isFinal: false
        )
        // Same partial text again, 1s later → considered stalled.
        clock.advance(1.0)
        let out = try await segmenter.process(
            TranscriptionResult(text: "speaker said something", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(out?.isFinal, true)
        XCTAssertEqual(out?.text, "speaker said something")
        XCTAssertEqual(out?.sequence, 1)
        XCTAssertEqual(engine.markBoundaryCalls, 1)
    }
```

- [ ] **Step 2: Run, expect PASS**

Expected: PASS.

### Task 2.8: Apple Speech accumulation — delta excludes consumed prefix

- [ ] **Step 1: Add the test**

```swift
    @MainActor
    func testCursorExcludesConsumedPrefixOnNextPartial() async throws {
        let clock = FakeClock()
        let (segmenter, _, _) = makeSegmenter(clock)

        // First partial accumulates.
        _ = try await segmenter.process(
            TranscriptionResult(text: "Hello how are you", isFinal: false, emotion: nil),
            isFinal: false
        )
        // Force-segment via hard limit.
        clock.advance(6.5)
        let first = try await segmenter.process(
            TranscriptionResult(text: "Hello how are you", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(first?.isFinal, true)
        XCTAssertEqual(first?.text, "Hello how are you", "first force-segment emits full delta")

        // Engine keeps accumulating — next partial extends the accumulated text.
        let next = try await segmenter.process(
            TranscriptionResult(text: "Hello how are you doing today", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(next?.text, " doing today", "delta excludes the consumed prefix")
        XCTAssertEqual(next?.isFinal, false)
        XCTAssertEqual(next?.sequence, 2, "partial belongs to upcoming seq=2")
    }
```

- [ ] **Step 2: Run, expect PASS**

Expected: PASS — cursor logic already implemented.

### Task 2.9: Paraformer-style — engine-native final resets cursor

- [ ] **Step 1: Add the test**

```swift
    @MainActor
    func testEngineFinalResetsCursor() async throws {
        let (segmenter, _, _) = makeSegmenter()

        _ = try await segmenter.process(
            TranscriptionResult(text: "你好世界。", isFinal: true, emotion: nil),
            isFinal: true
        )
        // After Paraformer's resetStream, next partial starts fresh.
        let out = try await segmenter.process(
            TranscriptionResult(text: "下一句开始", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(out?.text, "下一句开始", "cursor was reset by engine-native final")
        XCTAssertEqual(out?.sequence, 2)
    }
```

- [ ] **Step 2: Run, expect PASS**

Expected: PASS.

### Task 2.10: Text shrinkage resets cursor (rewrite / warm-start)

- [ ] **Step 1: Add the test**

```swift
    @MainActor
    func testShrinkageResetsCursor() async throws {
        let clock = FakeClock()
        let (segmenter, _, _) = makeSegmenter(clock)

        // Build up cursor via force-segment.
        _ = try await segmenter.process(
            TranscriptionResult(text: "Hello world", isFinal: false, emotion: nil),
            isFinal: false
        )
        clock.advance(6.5)
        _ = try await segmenter.process(
            TranscriptionResult(text: "Hello world", isFinal: false, emotion: nil),
            isFinal: false
        )

        // Engine rewrites accumulated text to something shorter.
        let out = try await segmenter.process(
            TranscriptionResult(text: "Hi", isFinal: false, emotion: nil),
            isFinal: false
        )
        XCTAssertEqual(out?.text, "Hi", "shrinkage resets cursor; delta = full new text")
        XCTAssertEqual(out?.isFinal, false)
        XCTAssertEqual(out?.sequence, 2)
    }
```

- [ ] **Step 2: Run, expect PASS**

Expected: PASS.

### Task 2.11: Run full segmenter suite

- [ ] **Step 1: Run all segmenter tests**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/SentenceSegmenterTests -quiet`
Expected: 9 tests, all PASS.

### Task 2.12: Commit Phase 2

- [ ] **Step 1: Stage and commit**

```bash
git add NemoNoise/Services/PostProcessors/SentenceSegmenter.swift \
        NemoNoiseTests/SentenceSegmenterTests.swift

git commit -m "$(cat <<'EOF'
feat(pipeline): add SentenceSegmenter post-processor

Pipeline-level force-segmentation for engines that rarely emit isFinal
under continuous audio (Apple Speech's mid-stream finals, Paraformer's
2.4s silence-trailing endpoint). Four trigger rules: engine-native
final, sentence-terminator punctuation, 0.8s partial-stall, 6s hard
limit. Cursor mechanism excludes already-emitted text from subsequent
partials without needing the engine to know it was force-segmented.
Not yet wired into the translation pipeline.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — AsyncTranslateProcessor + sink/controller/UI wiring

### Task 3.1: Extend `SubtitleWriter` protocol

**Files:**
- Modify: `NemoNoise/Services/Sinks/SubtitleOverlaySink.swift`

- [ ] **Step 1: Extend the protocol**

Replace the protocol declaration at the top of the file with:

```swift
@MainActor
protocol SubtitleWriter: AnyObject {
    var englishText: String { get set }
    var partialText: String { get set }
    var chineseText: String { get set }
    var isTranslating: Bool { get set }
    var displayedSeq: Int { get set }
    func applyTranslation(seq: Int, chinese: String)
}
```

- [ ] **Step 2: Build (expect errors)**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' build -quiet`
Expected: FAILS — `TranslationController` and `StubSubtitleTarget` no longer conform. Fixed in the next two tasks.

### Task 3.2: Make `TranslationController` conform to extended protocol

**Files:**
- Modify: `NemoNoise/App/TranslationController.swift`

- [ ] **Step 1: Add the new properties and method**

After the existing `var chineseText: String = ""` line (around line 9), add:

```swift
    var isTranslating: Bool = false
    var displayedSeq: Int = -1
```

After the `applyEnvelope` method (end of file, before the closing brace of the class), add:

```swift
    func applyTranslation(seq: Int, chinese: String) {
        guard seq == displayedSeq else { return }
        chineseText = chinese
    }
```

- [ ] **Step 2: Reset state on stop**

In `stopTranslation()`, after the existing `translationState = .idle` line, add:

```swift
        chineseText = ""
        isTranslating = false
        displayedSeq = -1
```

Also in `startTranslation()`, after the existing `chineseText = ""` line, add:

```swift
        isTranslating = false
        displayedSeq = -1
```

- [ ] **Step 3: Build (still expect StubSubtitleTarget error)**

Expected: error narrows to `NemoNoiseTests/SubtitleOverlaySinkTests.swift` only.

### Task 3.3: Update `StubSubtitleTarget` and add seq-gated sink tests

**Files:**
- Modify: `NemoNoiseTests/SubtitleOverlaySinkTests.swift`

- [ ] **Step 1: Update the stub**

Replace `StubSubtitleTarget` at the top of the file with:

```swift
@MainActor
final class StubSubtitleTarget: SubtitleWriter {
    var englishText: String = ""
    var partialText: String = ""
    var chineseText: String = ""
    var isTranslating: Bool = false
    var displayedSeq: Int = -1

    private(set) var applyTranslationCalls: [(seq: Int, chinese: String)] = []
    func applyTranslation(seq: Int, chinese: String) {
        applyTranslationCalls.append((seq, chinese))
        guard seq == displayedSeq else { return }
        chineseText = chinese
    }
}
```

- [ ] **Step 2: Build**

Expected: SUCCESS.

- [ ] **Step 3: Run existing sink tests**

Run: `xcodebuild test ... -only-testing:NemoNoiseTests/SubtitleOverlaySinkTests -quiet`
Expected: 5 existing tests still PASS (the sink itself has not been changed yet).

### Task 3.4: Sink writes seq + clears chineseText on seq-tagged final

**Files:**
- Modify: `NemoNoise/Services/Sinks/SubtitleOverlaySink.swift`

- [ ] **Step 1: Add a failing test**

Append to `SubtitleOverlaySinkTests`:

```swift
    func testSeqTaggedFinalSetsEnglishAndDisplayedSeqAndClearsChinese() async {
        let target = StubSubtitleTarget()
        target.chineseText = "stale-chinese"   // simulates prior sentence's translation
        let sink = SubtitleOverlaySink(target: target)
        let result = TranscriptionResult(
            text: "Hello world.", isFinal: true, emotion: nil,
            originalText: nil, sequence: 7
        )
        await sink.deliver(result, isFinal: true)
        XCTAssertEqual(target.englishText, "Hello world.")
        XCTAssertEqual(target.partialText, "")
        XCTAssertEqual(target.chineseText, "", "chinese cleared so old translation does not linger")
        XCTAssertEqual(target.displayedSeq, 7)
    }

    func testSeqlessFinalKeepsLegacyBehavior() async {
        let target = StubSubtitleTarget()
        target.chineseText = "kept"
        let sink = SubtitleOverlaySink(target: target)
        let result = TranscriptionResult(
            text: "dictation final", isFinal: true, emotion: nil,
            originalText: nil, sequence: nil
        )
        await sink.deliver(result, isFinal: true)
        XCTAssertEqual(target.englishText, "dictation final")
        XCTAssertEqual(target.partialText, "")
        XCTAssertEqual(target.chineseText, "kept", "seq-less finals leave chinese untouched")
        XCTAssertEqual(target.displayedSeq, -1, "seq-less finals do not advance displayedSeq")
    }
```

- [ ] **Step 2: Run, expect FAIL**

Run: `xcodebuild test ... -only-testing:NemoNoiseTests/SubtitleOverlaySinkTests/testSeqTaggedFinalSetsEnglishAndDisplayedSeqAndClearsChinese -quiet`
Expected: FAIL — sink does not yet honor `sequence`.

- [ ] **Step 3: Update sink deliver**

Replace `SubtitleOverlaySink.deliver` with:

```swift
    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard !result.text.isEmpty else { return }
        await MainActor.run {
            if isFinal, let seq = result.sequence {
                target.englishText = result.text
                target.partialText = ""
                target.chineseText = ""
                target.displayedSeq = seq
            } else if isFinal {
                target.englishText = result.text
                target.partialText = ""
                // Bilingual legacy path: still honor originalText if set.
                if let original = result.originalText {
                    target.englishText = original
                    target.chineseText = result.text
                }
            } else {
                target.partialText = result.text
            }
        }
    }
```

> Why keep the `originalText` branch: prior `2026-05-17-streaming-translation-fix-design.md` codepath. Removing it would break any other sink-consumer using that contract. The translation pipeline post this PR will not produce seq-less finals with originalText, so the branch becomes dead-for-this-pipeline but kept for protocol completeness.

- [ ] **Step 4: Run, expect both new tests PASS**

Run: `xcodebuild test ... -only-testing:NemoNoiseTests/SubtitleOverlaySinkTests -quiet`
Expected: all 7 tests PASS.

### Task 3.5: TranslationController.applyTranslation tests

**Files:**
- Create: `NemoNoiseTests/TranslationControllerApplyTranslationTests.swift`

- [ ] **Step 1: Write the tests**

```swift
import XCTest
@testable import NemoNoise

@MainActor
final class TranslationControllerApplyTranslationTests: XCTestCase {

    func testApplyTranslationWithMatchingSeqWritesChinese() {
        let c = TranslationController()
        c.displayedSeq = 5
        c.applyTranslation(seq: 5, chinese: "你好")
        XCTAssertEqual(c.chineseText, "你好")
    }

    func testApplyTranslationWithStaleSeqIsDropped() {
        let c = TranslationController()
        c.displayedSeq = 6
        c.chineseText = ""
        c.applyTranslation(seq: 5, chinese: "stale")
        XCTAssertEqual(c.chineseText, "", "stale seq translations must be dropped")
    }

    func testApplyTranslationWithFutureSeqIsDropped() {
        let c = TranslationController()
        c.displayedSeq = 5
        c.chineseText = ""
        c.applyTranslation(seq: 6, chinese: "future")
        XCTAssertEqual(c.chineseText, "")
    }
}
```

- [ ] **Step 2: Run, expect PASS**

Run: `xcodebuild test ... -only-testing:NemoNoiseTests/TranslationControllerApplyTranslationTests -quiet`
Expected: 3 tests PASS.

### Task 3.6: Replace `TranslateProcessor` with `AsyncTranslateProcessor`

**Files:**
- Create: `NemoNoise/Services/PostProcessors/AsyncTranslateProcessor.swift`
- Delete: `NemoNoise/Services/PostProcessors/TranslateProcessor.swift`

- [ ] **Step 1: Write the new processor**

`AsyncTranslateProcessor.swift`:

```swift
import Foundation

/// Fire-and-forget translation. Returns the source English synchronously
/// so the sink can render it immediately; spawns a detached Task that
/// translates and back-fills Chinese via `writer.applyTranslation`.
/// See `docs/superpowers/specs/2026-05-17-streaming-translation-realtime-design.md`.
@MainActor
final class AsyncTranslateProcessor: PostProcessor {
    private let service: any TranslationService
    private weak var writer: (any SubtitleWriter)?
    private var inflightCount: Int = 0

    init(service: any TranslationService, writer: any SubtitleWriter) {
        self.service = service
        self.writer = writer
    }

    // The PostProcessor protocol's `process` is non-isolated. Because the
    // class is `@MainActor`, awaiting `processOnMain` from this nonisolated
    // entry point hops to MainActor automatically — no MainActor.run needed.
    nonisolated func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        return await processOnMain(result, isFinal: isFinal)
    }

    private func processOnMain(_ result: TranscriptionResult, isFinal: Bool) async -> TranscriptionResult? {
        guard isFinal, !result.text.isEmpty, let seq = result.sequence else {
            return nil   // partial or seq-less (dictation) → passthrough
        }
        let source = result.text
        beginTranslating()
        Task.detached { [service, weak writer, weak self] in
            var translated: String? = nil
            do {
                translated = try await service.translate(source)
            } catch {
                LogService.warn(
                    "Translation failed: \(error.localizedDescription)",
                    category: "AsyncTranslate"
                )
            }
            await MainActor.run {
                if let t = translated, let w = writer {
                    w.applyTranslation(seq: seq, chinese: t)
                }
                self?.endTranslating()
            }
        }
        return TranscriptionResult(
            text: source, isFinal: true,
            emotion: result.emotion, originalText: nil, sequence: seq
        )
    }

    private func beginTranslating() {
        inflightCount += 1
        writer?.isTranslating = inflightCount > 0
    }

    private func endTranslating() {
        inflightCount = max(0, inflightCount - 1)
        writer?.isTranslating = inflightCount > 0
    }
}
```

- [ ] **Step 2: Delete the old processor**

Run: `rm NemoNoise/Services/PostProcessors/TranslateProcessor.swift`

- [ ] **Step 3: Build**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' build -quiet`
Expected: errors only from `PipelineProvider.applyTranslation` (referencing `TranslateProcessor`) and `TranslateProcessorTests` (still referencing the deleted class). Fixed in Task 3.8 and 3.7.

### Task 3.7: Delete old processor tests, add new ones

**Files:**
- Delete: `NemoNoiseTests/TranslateProcessorTests.swift`
- Create: `NemoNoiseTests/AsyncTranslateProcessorTests.swift`

- [ ] **Step 1: Delete the old test file**

Run: `rm NemoNoiseTests/TranslateProcessorTests.swift`

- [ ] **Step 2: Write new tests**

`AsyncTranslateProcessorTests.swift`:

```swift
import XCTest
@testable import NemoNoise

@MainActor
final class StubSubtitleWriter: SubtitleWriter {
    var englishText: String = ""
    var partialText: String = ""
    var chineseText: String = ""
    var isTranslating: Bool = false
    var displayedSeq: Int = -1

    private(set) var applyCalls: [(seq: Int, chinese: String)] = []
    func applyTranslation(seq: Int, chinese: String) {
        applyCalls.append((seq, chinese))
        if seq == displayedSeq { chineseText = chinese }
    }
}

final class ControlledTranslationService: TranslationService, @unchecked Sendable {
    enum Response { case success(String); case failure(Error) }
    var nextResponse: Response = .success("translated")
    var observedCalls: [String] = []

    func translate(_ text: String) async throws -> String {
        observedCalls.append(text)
        switch nextResponse {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}

@MainActor
final class AsyncTranslateProcessorTests: XCTestCase {

    func testPartialIsPassthrough() async throws {
        let service = ControlledTranslationService()
        let writer = StubSubtitleWriter()
        let p = AsyncTranslateProcessor(service: service, writer: writer)
        let out = try await p.process(
            TranscriptionResult(text: "hi", isFinal: false, emotion: nil, originalText: nil, sequence: 1),
            isFinal: false
        )
        XCTAssertNil(out)
        XCTAssertTrue(service.observedCalls.isEmpty)
        XCTAssertFalse(writer.isTranslating)
    }

    func testFinalWithoutSeqIsPassthrough() async throws {
        let service = ControlledTranslationService()
        let writer = StubSubtitleWriter()
        let p = AsyncTranslateProcessor(service: service, writer: writer)
        let out = try await p.process(
            TranscriptionResult(text: "dictation", isFinal: true, emotion: nil, originalText: nil, sequence: nil),
            isFinal: true
        )
        XCTAssertNil(out, "seq-less finals pass through (not the translation pipeline)")
        XCTAssertTrue(service.observedCalls.isEmpty)
    }

    func testFinalReturnsEnglishImmediatelyAndSetsIsTranslating() async throws {
        let service = ControlledTranslationService()
        service.nextResponse = .success("你好")
        let writer = StubSubtitleWriter()
        writer.displayedSeq = 1
        let p = AsyncTranslateProcessor(service: service, writer: writer)

        let out = try await p.process(
            TranscriptionResult(text: "Hello", isFinal: true, emotion: nil, originalText: nil, sequence: 1),
            isFinal: true
        )
        XCTAssertEqual(out?.text, "Hello", "english returned synchronously")
        XCTAssertEqual(out?.isFinal, true)
        XCTAssertEqual(out?.sequence, 1)
        XCTAssertTrue(writer.isTranslating, "spawning a translation flips isTranslating true")

        // Yield so the detached Task can complete + hop back to MainActor.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(writer.chineseText, "你好")
        XCTAssertFalse(writer.isTranslating, "inflight clears after success")
        XCTAssertEqual(writer.applyCalls.map(\.seq), [1])
    }

    func testFailureClearsIsTranslatingAndDoesNotWriteChinese() async throws {
        let service = ControlledTranslationService()
        service.nextResponse = .failure(NSError(domain: "t", code: 0))
        let writer = StubSubtitleWriter()
        writer.displayedSeq = 1
        let p = AsyncTranslateProcessor(service: service, writer: writer)

        _ = try await p.process(
            TranscriptionResult(text: "Hello", isFinal: true, emotion: nil, originalText: nil, sequence: 1),
            isFinal: true
        )

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(writer.chineseText, "", "no write on failure")
        XCTAssertFalse(writer.isTranslating, "counter clears on failure")
        XCTAssertTrue(writer.applyCalls.isEmpty)
    }

    func testStaleSeqIsDroppedBySink() async throws {
        // The sink/writer enforces seq matching; this test confirms applyTranslation
        // is still *called* with the original seq, leaving the sink/writer to drop.
        let service = ControlledTranslationService()
        service.nextResponse = .success("你好 A")
        let writer = StubSubtitleWriter()
        let p = AsyncTranslateProcessor(service: service, writer: writer)

        writer.displayedSeq = 1
        _ = try await p.process(
            TranscriptionResult(text: "Hello A", isFinal: true, emotion: nil, originalText: nil, sequence: 1),
            isFinal: true
        )
        // Sink moves on to seq=2 before A's translation completes.
        writer.displayedSeq = 2

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(writer.applyCalls.map(\.seq), [1], "called with seq=1")
        XCTAssertEqual(writer.chineseText, "", "writer dropped because seq != displayedSeq")
    }
}
```

- [ ] **Step 3: Run**

Run: `xcodebuild test ... -only-testing:NemoNoiseTests/AsyncTranslateProcessorTests -quiet`
Expected: PASS.

> **Why `Task.sleep` is OK here**: the test waits 100ms for a detached MainActor.run to complete. The translation service is in-memory; total round-trip is single-digit ms. If flaky, raise to 250ms.

### Task 3.8: Wire segmenter + async processor into `PipelineProvider`

**Files:**
- Modify: `NemoNoise/App/PipelineProvider.swift:119-147`

- [ ] **Step 1: Replace `applyTranslation` body**

In the `success` branch of `applyTranslation`, replace the post-processors construction with:

```swift
        case .success(let build):
            if let translationController {
                var postProcessors: [any PostProcessor] = []
                postProcessors.append(
                    SentenceSegmenter(engine: build.engine)
                )
                if let punctuator {
                    postProcessors.append(PunctuationProcessor(punctuator: punctuator))
                }
                postProcessors.append(
                    AsyncTranslateProcessor(
                        service: translationController.translationService,
                        writer: translationController
                    )
                )
                let pipeline = TranscriptionPipeline(
                    source: SystemAudioSource(),
                    engine: build.engine,
                    postProcessors: postProcessors,
                    sink: SubtitleOverlaySink(target: translationController),
                    fallback: nil
                )
                translationController.bind(pipeline: pipeline, mutex: mutex)
            }
            translation = .ready
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' build -quiet`
Expected: SUCCESS.

### Task 3.9: SubtitleOverlayView — three-state Chinese line

**Files:**
- Modify: `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift:59-75`

- [ ] **Step 1: Replace `textGroup`**

```swift
    private var textGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayEnglishText)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            chineseLine
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        }
    }

    @ViewBuilder
    private var chineseLine: some View {
        if !controller.chineseText.isEmpty {
            Text(controller.chineseText)
        } else if controller.isTranslating {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                Text("翻译中…")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(" ")  // empty placeholder, preserves baseline
        }
    }
```

> `minHeight: 22` matches the rendered height of a 16-pt rounded font line. If the visual audit during manual QA finds it off, adjust to the actual measured value.

- [ ] **Step 2: Build**

Expected: SUCCESS.

### Task 3.10: Pipeline integration test — 7s of partials force-segments

**Files:**
- Modify: `NemoNoiseTests/TranscriptionPipelineTests.swift`

- [ ] **Step 1: Add integration test**

Append to `TranscriptionPipelineTests` (the existing extension block is fine):

```swift
    final class TickingClock: @unchecked Sendable {
        var current: Date = Date(timeIntervalSinceReferenceDate: 0)
        var read: @Sendable () -> Date { { [weak self] in self?.current ?? Date() } }
        func tick(_ s: TimeInterval) { current = current.addingTimeInterval(s) }
    }

    @MainActor
    func testTranslationPipelineForceSegmentsAfterHardLimit() async throws {
        let engine = MockASREngine()
        // Seven accumulating partials, none isFinal.
        engine.feedChunkScript = [
            TranscriptionResult(text: "the speaker",                                       isFinal: false, emotion: nil),
            TranscriptionResult(text: "the speaker is",                                    isFinal: false, emotion: nil),
            TranscriptionResult(text: "the speaker is saying",                             isFinal: false, emotion: nil),
            TranscriptionResult(text: "the speaker is saying many",                        isFinal: false, emotion: nil),
            TranscriptionResult(text: "the speaker is saying many things",                 isFinal: false, emotion: nil),
            TranscriptionResult(text: "the speaker is saying many things now",             isFinal: false, emotion: nil),
            TranscriptionResult(text: "the speaker is saying many things now and continuing", isFinal: false, emotion: nil),
        ]
        let clock = TickingClock()
        let segmenter = SentenceSegmenter(engine: engine, now: clock.read)

        let source = MockAudioSource()
        let writer = StubSubtitleWriter()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine,
            postProcessors: [segmenter],
            sink: SubtitleOverlaySink(target: writer),
            fallback: nil
        )

        let events = pipeline.start()
        let consumer = Task { for try await _ in events { /* drain */ } }

        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<7 {
            clock.tick(1.1)
            source.emit(samples: [0.1])
            try await Task.sleep(for: .milliseconds(20))
        }
        source.finishStream()
        _ = try? await pipeline.finalize()
        _ = await consumer.value

        XCTAssertFalse(writer.englishText.isEmpty,
                       "after 7 partials over >6s, hard-limit must have force-segmented at least once")
        XCTAssertGreaterThan(writer.displayedSeq, 0,
                             "displayedSeq must have advanced past initial -1")
    }
```

> Reuses the existing `MockASREngine.feedChunkScript`, `MockAudioSource.emit/finishStream`, and `RecordingSink`/`StubSubtitleWriter` patterns. `StubSubtitleWriter` is the one defined in `AsyncTranslateProcessorTests.swift` (Task 3.7); import or duplicate as needed for cross-file visibility.

- [ ] **Step 2: Run**

Run: `xcodebuild test ... -only-testing:NemoNoiseTests/TranscriptionPipelineTests/testTranslationPipelineForceSegmentsAfterHardLimit -quiet`
Expected: PASS.

### Task 3.11: Run the full test suite

- [ ] **Step 1: Run all tests**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -quiet`
Expected: All tests PASS, no regressions in dictation tests, hotkey tests, model tests, etc.

### Task 3.12: Manual QA pass

- [ ] **Step 1: Build and run the app**

Run: open the project in Xcode and Cmd-R, or `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -configuration Debug build`.

- [ ] **Step 2: Smoke-test translation mode**

- Settings → engine: leave at default (or Apple Speech).
- Trigger translation hotkey.
- Play 30-60 seconds of a continuous English YouTube clip (no obvious pauses).
- Verify: English line updates every 4-6s in worst case; Chinese arrives 1-2s after English; "翻译中…" placeholder visible during the gap; no UI jitter.

- [ ] **Step 3: Switch engine to Paraformer**

- Settings → engine: Paraformer (download if needed).
- Restart translation mode.
- Same English clip.
- Verify: English line updates similarly; Chinese arrives; Paraformer's resetStream is exercised (no visible bug — confirms `markBoundary` works).

- [ ] **Step 4: Stop/start mid-translation**

- During translation, stop and restart immediately.
- Verify: no stale Chinese carries over; new session starts clean.

- [ ] **Step 5: Translation failure path**

- Disable network if Apple Translation falls back online (it shouldn't on macOS 17+ on-device); OR simulate by temporarily breaking the language pair in code.
- Verify: English shows, "翻译中…" appears, then placeholder disappears, Chinese empty. No toast, no crash.

If any of the above fails, file follow-up tasks; do not commit Phase 3 until smoke-tests pass.

### Task 3.13: Commit Phase 3

- [ ] **Step 1: Stage and commit**

```bash
git add NemoNoise/Services/PostProcessors/AsyncTranslateProcessor.swift \
        NemoNoise/Services/Sinks/SubtitleOverlaySink.swift \
        NemoNoise/App/TranslationController.swift \
        NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift \
        NemoNoise/App/PipelineProvider.swift \
        NemoNoiseTests/SubtitleOverlaySinkTests.swift \
        NemoNoiseTests/AsyncTranslateProcessorTests.swift \
        NemoNoiseTests/TranslationControllerApplyTranslationTests.swift \
        NemoNoiseTests/TranscriptionPipelineTests.swift

git rm NemoNoise/Services/PostProcessors/TranslateProcessor.swift \
       NemoNoiseTests/TranslateProcessorTests.swift

git commit -m "$(cat <<'EOF'
feat(translation): async fire-and-forget translation with seq backfill

Replaces synchronous TranslateProcessor with AsyncTranslateProcessor:
English is returned immediately for the sink to render; Chinese is
back-filled via SubtitleWriter.applyTranslation(seq:chinese:) once the
detached translation Task completes. Late translations whose seq no
longer matches displayedSeq are dropped, preventing stale Chinese
from appearing under newer English. UI shows "翻译中…" placeholder
during the gap. Pipeline wires SentenceSegmenter ahead of punctuator
and AsyncTranslateProcessor.

End-to-end: 2-4s typical latency for Chinese after English under
continuous speech.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Done

All three commits produce buildable, testable states. End-to-end behavior matches the spec.
