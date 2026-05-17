# Streaming Translation Realtime — Design

## Overview

Translation mode is functionally wired end-to-end (per `2026-05-17-streaming-translation-fix-design.md`) but unusable in practice: Chinese subtitles appear too sparsely. Two root causes confirmed by user testing:

1. **Apple Speech engine**: `isFinal=true` fires only when SFSpeech itself decides a segment is complete. With continuous speech (no obvious pauses), this can be 20+ seconds apart. Chinese updates lag the same.
2. **Paraformer engine**: `isEndpoint` requires 2.4s of trailing silence (`rule1_min_trailing_silence`). Screen audio (YouTube, Zoom) rarely contains such silences, so `isFinal=true` never fires. No translation ever runs.

Target latency for Chinese-after-English: **2–4 seconds**. Translation must be a pipeline-level capability decoupled from the ASR engine.

This spec introduces a pipeline-level `SentenceSegmenter` that produces `isFinal=true` results on its own schedule, converts `TranslateProcessor` to a fire-and-forget async pattern that fills Chinese back into the sink, and adds an "translating…" UI state.

Scope: translation mode only. Dictation behavior must not change. No new permissions, no new dependencies.

## Background — what's already in place

Per the prior spec (`2026-05-17-streaming-translation-fix-design.md`, already shipped):
- `TranscriptionResult` has `originalText: String?`.
- `TranscriptionPipeline.start()` propagates `result.isFinal` end-to-end (no longer hard-codes false).
- `ParaformerStreamingEngine.feedChunk` returns `isFinal: true` at endpoint.
- `AppleSpeechASREngine` queues mid-stream finals.
- `TranslateProcessor` is wired into the translation pipeline's post-processors (synchronous).
- `SubtitleOverlaySink` renders bilingual when `originalText != nil`.
- `SubtitleOverlayView` no longer drives translation from `.onChange`.

The architecture is sound. The bottleneck is **how often `isFinal=true` fires**, which is dictated by ASR engines that don't see screen audio's lack of silences. The fix is to add a pipeline-level segmenter that doesn't depend on engine signals.

## Architecture & data flow

```
SystemAudioSource ─chunks─▶ TranscriptionPipeline (loop)
                                     │
                                     ▼
                          ASREngine.feedChunk
                                     │  result(text, isFinal, originalText=nil)
                                     ▼
                          SentenceSegmenter                  ◀── NEW
                                     │  emits result(text=delta, isFinal=true,
                                     │              sequence=K) on any rule match;
                                     │  otherwise transparent partial.
                                     ▼
                          PunctuationProcessor (when isFinal && text non-empty)
                                     │
                                     ▼
                          AsyncTranslateProcessor             ◀── CHANGED
                                     │  on isFinal=true:
                                     │    return result.text immediately (no wait);
                                     │    Task.detached → translate → applyTranslation
                                     ▼
                          SubtitleOverlaySink
                                     │  isFinal+seq → englishText, clear chineseText,
                                     │                writer.displayedSeq = seq
                                     │  isFinal (no seq) → englishText (old path)
                                     │  partial → partialText
                                     ▼
                          TranslationController (SubtitleWriter)
                                     │  applyTranslation(seq, chinese):
                                     │    if seq == displayedSeq → chineseText = chinese
                                     │    else → drop (stale)
                                     ▼
                          SubtitleOverlayView
                                     │  English line: englishText / partialText
                                     │  Chinese line: chineseText, else "翻译中…" if isTranslating
```

**Invariants**
1. `result.sequence` is non-nil iff the result was emitted by `SentenceSegmenter` (i.e., this is a translation-pipeline result). Dictation pipeline never sees a sequence.
2. `displayedSeq` on the sink target tracks the seq of the English currently being shown. The Chinese back-fill is only valid for that seq.
3. `isTranslating == true` iff at least one translation task is in flight. The inflight counter increments on `process(isFinal=true)` and decrements when the detached task completes (regardless of success/failure).
4. **Latency target**: Chinese visible within 2–4s of corresponding English audio under normal network and CPU conditions. Hard upper bound on English-side latency is `maxSegmentDuration` (6s) plus engine partial cadence (~100ms).

## Component changes

### 1. `Models/TranscriptionResult.swift`

Add `sequence: Int?` with default `nil`. Memberwise init updated to keep all existing call sites compiling.

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

### 2. `Services/ASR/ASREngine.swift`

Add `markBoundary()` with a default no-op implementation. Used by `SentenceSegmenter` to hint engines to reset accumulated context when the pipeline force-segments. Optional; engines that ignore it still work correctly because the segmenter's cursor mechanism handles the accumulation locally.

```swift
protocol ASREngine: Sendable, AnyObject {
    // ... existing methods
    func markBoundary()
}

extension ASREngine {
    func markBoundary() {}   // default no-op
}
```

### 3. `Services/ASR/ParaformerStreamingEngine.swift`

Override `markBoundary` to reset the recognizer's accumulated context without destroying the stream:

```swift
func markBoundary() {
    recognizer.resetStream()
}
```

This prevents Paraformer's stream from accumulating context across many force-segments (long sessions otherwise see RAM growth and slower decoding).

Apple Speech, Cloud, Qwen3, SenseVoice engines do not override — default no-op. SFSpeech is a black box; we do not restart it on force-segment, because restart introduces a ~200ms gap and possible audio loss.

### 4. `Services/PostProcessors/SentenceSegmenter.swift` — NEW

Maintains per-session state: a monotonic sequence counter, a cursor into the engine's accumulated partial text, and two timestamps (segment start, last partial change).

```swift
@MainActor
final class SentenceSegmenter: PostProcessor {
    private let silenceThreshold: Duration = .milliseconds(800)
    private let maxSegmentDuration: Duration = .seconds(6)
    private let sentenceEnders: Set<Character> = [".", "?", "!", "。", "?", "!"]

    private weak var engine: (any ASREngine)?

    private var currentSeq: Int = 0
    private var consumedTextLength: Int = 0
    private var segmentStartTime: ContinuousClock.Instant = .now
    private var lastPartialChangeTime: ContinuousClock.Instant = .now
    private var lastPartialText: String = ""

    init(engine: any ASREngine) {
        self.engine = engine
    }

    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        if result.text.isEmpty { return nil }

        if isFinal {
            // Engine-native final: trust it, reset cursor & timers, assign seq.
            currentSeq += 1
            let out = TranscriptionResult(
                text: result.text, isFinal: true,
                emotion: result.emotion, originalText: result.originalText,
                sequence: currentSeq
            )
            resetSegmentState()
            return out
        }

        // Partial path: compute delta from cursor.
        let fullCount = result.text.count
        if fullCount < consumedTextLength {
            // Engine rewrote / shrunk accumulated text. Treat as reset.
            consumedTextLength = 0
        }
        let delta = String(result.text.dropFirst(consumedTextLength))

        if delta != lastPartialText {
            lastPartialText = delta
            lastPartialChangeTime = .now
        }

        // Check force-segment rules in priority order.
        let trimmed = delta.trimmingCharacters(in: .whitespaces)
        let endsWithSentenceEnder = trimmed.last.map { sentenceEnders.contains($0) } ?? false
        let now = ContinuousClock.now
        let exceededHardLimit = (now - segmentStartTime) > maxSegmentDuration
        let stalledForSilence = !delta.isEmpty
            && (now - lastPartialChangeTime) > silenceThreshold

        if endsWithSentenceEnder || exceededHardLimit || stalledForSilence {
            currentSeq += 1
            let out = TranscriptionResult(
                text: delta, isFinal: true,
                emotion: result.emotion, originalText: result.originalText,
                sequence: currentSeq
            )
            consumedTextLength = fullCount
            engine?.markBoundary()
            // Keep timers at "now" so the next segment's clock starts fresh.
            segmentStartTime = .now
            lastPartialChangeTime = .now
            lastPartialText = ""
            return out
        }

        // Transparent partial — propagate delta with current seq (not advanced).
        return TranscriptionResult(
            text: delta, isFinal: false,
            emotion: result.emotion, originalText: result.originalText,
            sequence: currentSeq + 1   // upcoming seq, for partial display continuity
        )
    }

    private func resetSegmentState() {
        consumedTextLength = 0
        segmentStartTime = .now
        lastPartialChangeTime = .now
        lastPartialText = ""
    }
}
```

**Cursor semantics**
- Apple Speech: `result.text` is the accumulated transcription across the current SFSpeech segment. The cursor records how many characters have already been emitted as a forced final; subsequent partials reveal only the new tail.
- Paraformer: after `markBoundary()` calls `resetStream()`, the next partial's `result.text` starts from empty; the cursor (which we also reset to 0) aligns.
- Engine-native `isFinal=true`: engine has already finished its segment; cursor resets to 0; next partial is post-final.
- **Defensive case**: If `result.text.count < consumedTextLength` (Apple Speech can revise accumulated text in place, e.g. "tomato" → "two motto"), we treat it as a reset, set cursor to 0, and emit the full new text as the next delta. This is rare; the user-visible effect is that the previously force-segmented English may be partially re-emitted in the next sentence. Acceptable for this iteration.

**Sequence semantics**
- Final-emission seq is `++currentSeq` (1, 2, 3, ...).
- Partial-emission seq is `currentSeq + 1` — i.e., the seq the partial belongs to once it materializes as a final. This keeps the sink's partial text aligned with the future English line.

### 5. `Services/PostProcessors/AsyncTranslateProcessor.swift` (replaces `TranslateProcessor.swift`)

```swift
@MainActor
final class AsyncTranslateProcessor: PostProcessor {
    private let service: any TranslationService
    private weak var writer: (any SubtitleWriter)?
    private var inflightCount: Int = 0

    init(service: any TranslationService, writer: any SubtitleWriter) {
        self.service = service
        self.writer = writer
    }

    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        guard isFinal, !result.text.isEmpty, let seq = result.sequence else {
            return nil   // partial OR no seq (dictation) → transparent passthrough
        }
        let source = result.text
        beginTranslating()
        Task.detached { [service, weak writer, weak self] in
            let translated: String?
            do {
                translated = try await service.translate(source)
            } catch {
                LogService.warn(
                    "Translation failed: \(error.localizedDescription)",
                    category: "AsyncTranslate"
                )
                translated = nil
            }
            await MainActor.run {
                if let translated, let writer {
                    writer.applyTranslation(seq: seq, chinese: translated)
                }
                self?.endTranslating()
            }
        }
        // Pass the English through immediately so the sink can render it.
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

**On failure**: translation silently fails. Chinese line stays empty. `isTranslating` clears. No toast, no fallback to English-as-Chinese. Logged at warn.

**Concurrency**: each `process` call spawns a detached task. Tasks run in parallel; their completion order is unpredictable. Ordering correctness relies on the sink's seq check (next section).

### 6. `Services/Sinks/SubtitleOverlaySink.swift` and `SubtitleWriter` protocol

Protocol gains two requirements:

```swift
@MainActor
protocol SubtitleWriter: AnyObject {
    var englishText: String { get set }
    var partialText: String { get set }
    var chineseText: String { get set }
    var isTranslating: Bool { get set }              // NEW
    func applyTranslation(seq: Int, chinese: String) // NEW
}
```

Sink `deliver`:

```swift
func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
    guard !result.text.isEmpty else { return }
    await MainActor.run {
        if isFinal, let seq = result.sequence {
            target.englishText = result.text
            target.partialText = ""
            target.chineseText = ""
            if let tc = target as? TranslationController {
                tc.displayedSeq = seq
            }
        } else if isFinal {
            // No seq → dictation path (no segmenter). Keep old behavior.
            target.englishText = result.text
            target.partialText = ""
        } else {
            target.partialText = result.text
        }
    }
}
```

`chineseText = ""` on every new final is required: it clears the previous sentence's translation so the user does not see "new English + old Chinese" during the 1–3s translation gap. The "翻译中…" placeholder fills that gap.

### 7. `App/TranslationController.swift`

Add three properties and one method:

```swift
var isTranslating: Bool = false
var displayedSeq: Int = -1

func applyTranslation(seq: Int, chinese: String) {
    guard seq == displayedSeq else { return }
    chineseText = chinese
}
```

Conform to extended `SubtitleWriter`.

### 8. `UI/SubtitleOverlay/SubtitleOverlayView.swift`

Chinese row renders one of three states:

```swift
Group {
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
        Text("")  // empty placeholder
    }
}
.frame(maxWidth: .infinity, minHeight: <line-height>, alignment: .leading)
```

`minHeight` is the rendered height of a single Chinese-line `Text` at the current font, computed once from the font metrics (the implementation plan resolves the concrete value by measuring the existing Chinese-line layout). Fixing it prevents the subtitle box from jittering as Chinese arrives or disappears.

### 9. `App/PipelineProvider.swift`

`applyTranslation` constructs the three-stage post-processor chain:

```swift
case .success(let build):
    if let translationController {
        var postProcessors: [any PostProcessor] = []
        postProcessors.append(SentenceSegmenter(engine: build.engine))
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

Dictation pipeline is unchanged (no segmenter, no translate).

## Error handling

| Scenario | Behavior |
|----------|----------|
| Apple Translation session not yet set | `AsyncTranslateProcessor`'s Task catches `.translationUnavailable`, leaves Chinese empty, `isTranslating` clears, English shown. Next sentence translates once session lands. |
| Translation throws other error (network, language pack missing) | Same as above. Log at warn. |
| Translation returns slowly, next sentence already segmented | `applyTranslation` seq check drops the late result. User sees only the current sentence's translation, no flicker of stale Chinese. |
| Multiple in-flight translations | Inflight counter tracks; `isTranslating=true` until counter hits 0. UI shows spinner whenever any translation is pending. |
| Engine fails mid-session | Existing fallback path; segmenter does not need to reset across fallback (cursor/timers naturally re-align on next final). |
| User stops translation mid-segment | `stopTranslation()` calls `pipeline.finalize()`; pipeline drains tail through engine.finish(), result flows through segmenter (assigned seq) and AsyncTranslateProcessor (translation fires). On hide overlay, in-flight translations complete but their `applyTranslation` finds `displayedSeq` reset or the controller deallocated; they are dropped. No crash. |
| Engine emits empty partial | Segmenter returns nil; pipeline yields `.level` event; sink not touched. |

## Testing strategy

**Unit tests** (IO-free, MockASREngine, MockTranslationService that returns Future-controlled results):

1. **SentenceSegmenterTests**
   - Engine-native isFinal=true → passthrough + seq=1, cursor=0, timers reset.
   - Accumulated partials with no rule hit → all partials passthrough, no final emitted.
   - 0.8s+ stalled partial → force-segment, seq=1, delta correct.
   - 6s+ elapsed since segment start → force-segment.
   - Partial ending with `.`/`?`/`!`/`。`/`?`/`!` → force-segment.
   - Apple Speech accumulation: "Hello", "Hello how", "Hello how are you" + 6s → force-segment with delta="Hello how are you"; next partial "Hello how are you doing today" → delta=" doing today".
   - Paraformer post-isFinal: engine final "你好。", then partial "下" → cursor reset, delta="下".
   - Rewrite case: full text shrinks (e.g., "tomato"→"two motto") → cursor reset, delta=full new text.
   - Empty partial → nil return.
   - `markBoundary()` invoked exactly once per force-segment.

2. **AsyncTranslateProcessorTests**
   - Success: detached Task completes, `writer.applyTranslation(seq:chinese:)` called with correct args.
   - Failure: `applyTranslation` not called; inflight counter still decrements; `isTranslating=false` at end.
   - Three concurrent translations with B slow:
     - All three increment counter then decrement → final counter=0, `isTranslating=false`.
     - A and C deliver to `applyTranslation`; B's slow delivery also calls `applyTranslation(seqB, ...)` but seqB ≠ displayedSeq (now seqC) → drops in sink.

3. **SubtitleOverlaySinkTests**
   - Final with seq: writes englishText, partialText="", chineseText="", displayedSeq=seq.
   - Final without seq (dictation): writes englishText, partialText="" — chineseText untouched.
   - Partial: writes partialText only.

4. **TranslationController.applyTranslation tests**
   - seq == displayedSeq → chineseText updated.
   - seq < displayedSeq → ignored.
   - seq > displayedSeq → ignored (defensive; theoretical race).

5. **Pipeline integration**
   - Simulate 7s of continuous partials with no engine-native final → assert sink received at least one English write (hard-limit rule fired).
   - Dictation pipeline regression: no segmenter installed; isFinal=true from mock engine flows to sink with no seq.

**Manual QA**
- Play 5+ minute English YouTube video; verify English line updates every 4–6s in worst case, faster on pauses; Chinese arrives 1–2s after English; "翻译中…" visible in the gap.
- Switch engine (Settings) between Apple Speech and Paraformer; restart translation mode; both work.
- Engine fallback during translation (mock CloudASREngine that fails after N chunks): verify pipeline.engineFallback fires, segmenter continues with new engine.
- Disable Apple Translation language pack mid-session: subsequent sentences show English only, no toast, no crash.

## Migration / commit order

Single PR, three commits for reviewability:

1. **Commit 1 — `sequence` field + `markBoundary()` protocol method**
   - `Models/TranscriptionResult.swift`: add `sequence: Int?`.
   - `Services/ASR/ASREngine.swift`: add `markBoundary()` with default no-op.
   - `Services/ASR/ParaformerStreamingEngine.swift`: override `markBoundary()` → `recognizer.resetStream()`.
   - Compile-only commit: no behavior change. All call sites continue to work.

2. **Commit 2 — `SentenceSegmenter` + unit tests**
   - New file `Services/PostProcessors/SentenceSegmenter.swift`.
   - New file `NemoNoiseTests/SentenceSegmenterTests.swift`.
   - Not yet wired into any pipeline. Behavior unchanged.

3. **Commit 3 — `AsyncTranslateProcessor` + sink/controller/UI wiring**
   - Rename `TranslateProcessor.swift` → `AsyncTranslateProcessor.swift`; replace contents.
   - `Services/Sinks/SubtitleOverlaySink.swift`: gate on `result.sequence`, clear chineseText, set displayedSeq.
   - `SubtitleWriter` protocol: add `isTranslating`, `applyTranslation(seq:chinese:)`.
   - `App/TranslationController.swift`: add `isTranslating`, `displayedSeq`, `applyTranslation`.
   - `UI/SubtitleOverlay/SubtitleOverlayView.swift`: Chinese-line three-state render.
   - `App/PipelineProvider.swift`: insert `SentenceSegmenter` before punctuator, replace TranslateProcessor with AsyncTranslateProcessor.
   - Tests for AsyncTranslateProcessor, sink, controller, pipeline integration.
   - End of commit: end-to-end behavior matches design.

Each commit leaves the app buildable and tests green.

## Out of scope

- Reverse direction (zh→en).
- Microphone input as translation source.
- Multiple language pairs / language detection.
- Streaming translation of partial text (translating mid-sentence).
- Removing the `originalText` field. Unused after this change but kept for backwards compatibility with the existing sink branch and any future bilingual sink that wants to use it.
- Apple Speech task restart on force-segment (intentionally avoided due to 200ms gap and possible audio loss).
- User-tunable `silenceThreshold` / `maxSegmentDuration` (constants for now; can be exposed in Settings later if needed).
- Toast on translation failure (silent log only; failure is recoverable and high-frequency at session start).
