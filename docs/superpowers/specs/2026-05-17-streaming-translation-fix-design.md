# Streaming Translation Fix — Design

## Overview

Translation mode currently displays English (or pretends to: the English partial is rendered on both subtitle lines) but never produces Chinese during an active session. Root cause is architectural: the `isFinal: true` signal that drives translation is never emitted while the pipeline streams.

This spec fixes the bug by propagating `isFinal` end-to-end and moves translation into the pipeline (as the post-processor it was always meant to be), removing the view-level translation task that compensated for the missing signal.

Scope: translation mode only. Dictation behavior must not change. No new UI, no new permissions, no new dependencies.

## Root cause (cited)

1. `TranscriptionPipeline.start()` (`Services/Pipeline/TranscriptionPipeline.swift:67`) hard-codes `sink.deliver(result, isFinal: false)` in the streaming loop. The pipeline ignores `result.isFinal` on the struct it just received from the engine.
2. ASR engines also collude: `ParaformerStreamingEngine.feedChunk` (`Services/ASR/ParaformerStreamingEngine.swift:32`) returns `isFinal: false` even at endpoint. `AppleSpeechASREngine` (`Services/ASR/AppleSpeechASREngine.swift:94–110`) does receive mid-stream `result.isFinal=true` segments from SFSpeech, but stores them in a single `state.finalResult` slot drained only by `finish()`.
3. `SubtitleOverlaySink` (`Services/Sinks/SubtitleOverlaySink.swift:18–25`) writes `englishText` only on `isFinal=true`, `partialText` otherwise.
4. `SubtitleOverlayView` (`UI/SubtitleOverlay/SubtitleOverlayView.swift:39`) drives translation from `.onChange(of: controller.englishText)`.
5. `TranslationController.stopTranslation()` (`App/TranslationController.swift:92`) is the only call site of `pipeline.finalize()`.

Chain: `englishText` never updates during streaming → onChange never fires → `translate(...)` never runs → `chineseText` stays `""` → subtitle bottom line falls back to `displayEnglishText` (the English partial). User sees English on both lines.

A second, independent defect: `TranslateProcessor` (`Services/PostProcessors/TranslateProcessor.swift`) is dead code. `PipelineProvider.applyTranslation` (`App/PipelineProvider.swift:127–138`) wires only `PunctuationProcessor` into the translation pipeline's postProcessors. The class has never been instantiated anywhere in the codebase.

## Architecture & data flow (after fix)

```
SystemAudioSource ─chunks─▶ TranscriptionPipeline (loop)
                                      │
                                      ▼
                          ASREngine.feedChunk
                                      │  result(text, isFinal, originalText=nil)
                                      ▼
                          PunctuationProcessor (when isFinal && text non-empty)
                                      │  result(text=punctuated, isFinal=true, originalText=nil)
                                      ▼
                          TranslateProcessor   (when isFinal && text non-empty)
                                      │  on success:  result(text=Chinese, isFinal=true, originalText=English)
                                      │  on failure:  result(text=English, isFinal=true, originalText=nil)
                                      ▼
                          SubtitleOverlaySink
                                      │  if originalText != nil → englishText = originalText,
                                      │                           chineseText  = text
                                      │  else (partial or translation-failed) →
                                      │                           partialText  = text (no chineseText write)
                                      ▼
                          TranslationController state ─▶ SubtitleOverlayView renders
```

Two invariants this preserves:
- A `TranscriptionResult` whose `originalText == nil` has not been translated. Sinks and tests can rely on this.
- `text` is always what the user sees as the primary output. `originalText`, when present, is the pre-translation source.

## Component changes

### 1. `Models/TranscriptionResult.swift`

Add `originalText: String?` with default `nil`. Memberwise init updated. All existing call sites compile unchanged.

```swift
struct TranscriptionResult: Sendable {
    let text: String
    let isFinal: Bool
    let emotion: String?
    let originalText: String?

    init(text: String, isFinal: Bool, emotion: String?, originalText: String? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.emotion = emotion
        self.originalText = originalText
    }
}
```

### 2. `Services/Pipeline/TranscriptionPipeline.swift`

In the streaming for-await loop, replace the hard-coded `false`:

```swift
var result = try await engine.feedChunk(chunk.samples, sampleRate: 16000)
let final = result.isFinal
for proc in postProcessors {
    if let next = try await proc.process(result, isFinal: final) {
        result = next
    }
}
await sink.deliver(result, isFinal: final)
if result.text.isEmpty {
    continuation.yield(.level(rms: chunk.rmsLevel, spectrum: chunk.spectrum))
} else if final {
    continuation.yield(.final(result))
} else {
    continuation.yield(.partial(result, rms: chunk.rmsLevel, spectrum: chunk.spectrum))
}
```

`PipelineEvent.final` is currently only yielded from `finalize()`. Yielding it mid-stream is a behavior change controllers must handle — see §3 (RecordingController) and §4 (TranslationController) below.

### 3. `Services/ASR/ParaformerStreamingEngine.swift`

At endpoint, return `isFinal: true`:

```swift
func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
    var text = recognizer.feed(samples: samples, sampleRate: Int32(sampleRate))
    if recognizer.isEndpoint {
        if !text.isEmpty { text += "。" }
        recognizer.resetStream()
        return TranscriptionResult(text: text, isFinal: true, emotion: nil)
    }
    return TranscriptionResult(text: text, isFinal: false, emotion: nil)
}
```

### 4. `Services/ASR/AppleSpeechASREngine.swift`

Replace the single `state.finalResult` slot with a FIFO queue of mid-stream finals. The existing `finishContinuation` semantics for `finish()` are preserved.

State change:
```swift
private struct State {
    var partialText: String = ""
    var pendingFinals: [TranscriptionResult] = []
    var finishContinuation: CheckedContinuation<TranscriptionResult, Error>?
    var pendingError: Error?
    var taskEnded: Bool = false
}
```

Callback for `isFinal=true`:
- If `finishContinuation != nil` (i.e. `finish()` is waiting), resume it with this final.
- Otherwise enqueue into `pendingFinals` and continue receiving subsequent partials.

`feedChunk` change:
- Before feeding the new buffer, pop the head of `pendingFinals` if any; if popped, return it with `isFinal: true`.
- Otherwise append the buffer to the request and return the current `partialText` with `isFinal: false`, as today.

`finish()` change:
- If `pendingFinals` is non-empty, concatenate all queued finals' `text` (preserving order, joined by space) and return as one `TranscriptionResult(isFinal: true)`. This handles the burst case where Apple Speech emitted multiple finals between two `feedChunk` calls.
- Otherwise call `request.endAudio()` and await the next `isFinal=true` via the existing continuation flow.

Concurrency: SFSpeech's task callback fires off-actor. All state mutation goes through the existing `OSAllocatedUnfairLock`-guarded `State`.

Lossiness: under normal cadence (feedChunk ~every 50–100ms, mid-stream finals spaced by sentence-pauses i.e. multiple seconds), the queue holds 0 or 1 entries. The concatenation path in `finish()` is a safety net, not a hot path.

### 5. `Services/PostProcessors/TranslateProcessor.swift`

Preserve original text on success; on failure, leave `originalText` nil so downstream sinks treat the result as un-translated:

```swift
func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
    guard isFinal, !result.text.isEmpty else { return nil }
    do {
        let translated = try await service.translate(result.text)
        return TranscriptionResult(
            text: translated, isFinal: true,
            emotion: result.emotion, originalText: result.text
        )
    } catch {
        LogService.warn("Translation failed, returning source: \(error.localizedDescription)",
                        category: "TranslateProcessor")
        return TranscriptionResult(
            text: result.text, isFinal: true,
            emotion: result.emotion, originalText: nil
        )
    }
}
```

Session race: on app cold start, the pipeline can fire `isFinal=true` before `SubtitleOverlayView.translationTask` injects the session. `AppleTranslationService.translate` throws `.translationUnavailable`, processor catches and returns un-translated text. Sink writes English to `partialText`. Once the session lands, subsequent sentences translate normally.

### 6. `Services/Sinks/SubtitleOverlaySink.swift`

Split rendering by `originalText` presence (not by `isFinal`):

```swift
func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
    guard !result.text.isEmpty else { return }
    await MainActor.run {
        if let original = result.originalText {
            target.englishText = original
            target.chineseText = result.text
            target.partialText = ""
        } else if isFinal {
            target.englishText = result.text
            target.partialText  = ""
        } else {
            target.partialText = result.text
        }
    }
}
```

`SubtitleWriter` protocol gains `var chineseText: String { get set }` as a new requirement. `TranslationController` already declares that property, so the conformance is satisfied with no controller-side change. `OverlayWriter` (the dictation-side protocol) is unrelated and unchanged.

### 7. `App/PipelineProvider.swift`

`applyTranslation` adds `TranslateProcessor` after `PunctuationProcessor`:

```swift
let translateProcessor = TranslateProcessor(service: translationController.translationService)
let postProcessors: [any PostProcessor] = (punctuator.map {
    [PunctuationProcessor(punctuator: $0)] as [any PostProcessor]
} ?? []) + [translateProcessor]
```

Order matters: punctuate before translating so the source text fed to Apple Translation has sentence terminators.

### 8. `UI/SubtitleOverlay/SubtitleOverlayView.swift`

Keep `.translationTask` (it's the only way to obtain a `TranslationSession`). Remove `.onChange(of: controller.englishText)` block — translation is now driven by the pipeline. Remove unused `translationTask` `@State` and its `onDisappear` cleanup.

`controller.isTranslating` becomes dead state (was set inside the removed onChange). Remove it from `TranslationController`.

### 9. `App/RecordingController.swift`

The pipeline now yields `.final` events mid-stream for dictation too (when Apple Speech segments speech mid-recording). The controller currently has `case .final: break` (line 217) — keep that. Mid-stream finals go to the only dictation sink (`OverlayProgressSink`), which ignores `isFinal=true` (line 21). No behavior change. Add a test to lock this in.

### 10. `App/TranslationController.swift`

`englishText`, `partialText`, `chineseText` already exist. Conform to extended `SubtitleWriter` (already does). Delete `isTranslating` (becomes unused) and the `chineseText` comment referencing post-translation by view layer.

## Error handling

| Scenario | Behavior |
|----------|----------|
| Translation session not yet set | TranslateProcessor returns original (originalText=nil); sink shows English in partial line; next sentence will translate once session lands. No toast, no user-facing error. |
| Translation throws other error (network, language pack missing) | Same as above. Log at warn. |
| ASR fallback fires mid-session | Existing `engineFallback` event path is unchanged. After fallback, the new engine continues emitting partials; `isFinal=true` resumes when the new engine segments speech (Apple Speech mid-stream final). |
| User stops translation mode mid-translation | `stopTranslation()` calls `pipeline.finalize()`. The pipeline drains any pending audio and emits one final `isFinal=true` result. TranslateProcessor is invoked once more; subtitle is briefly updated; overlay then hides. |

## Testing strategy

Unit (IO-free, using `MockASREngine` and `MockAudioSource`):

1. **Pipeline propagation** — engine emits `result.isFinal=true` mid-stream → sink receives `isFinal=true`. Engine emits `result.isFinal=false` → sink receives `isFinal=false`. Lock the contract.
2. **Pipeline `.final` event** — mid-stream final yields a `.final` PipelineEvent, not `.partial`.
3. **TranslateProcessor success path** — translated text replaces `text`, original goes into `originalText`.
4. **TranslateProcessor failure path** — `originalText == nil`, `text == source`.
5. **Sink rendering** — `originalText` present → writes both `englishText` and `chineseText`. `originalText` nil + isFinal → writes `englishText` only. `isFinal` false → writes `partialText` only.
6. **Apple Speech queue** — given 3 mid-stream finals and interleaved partials, FIFO order is preserved; `finish()` drains.
7. **Paraformer endpoint** — at `isEndpoint`, feedChunk returns `isFinal: true`.
8. **Dictation invariant** — when pipeline emits mid-stream `isFinal=true`, `OverlayProgressSink` does not mutate `target.partialText` or `target.confirmedSegments`. Regression test for `RecordingController`.

Manual QA:
- Play English video (YouTube, Zoom) → bilingual subtitles update sentence-by-sentence.
- Cold start: trigger translation mode immediately on app launch → first sentence may show English-only briefly while session loads, then Chinese starts appearing.
- Stop and restart translation → no stale state.

## Migration / commit order

Single PR, two commits for reviewability:

1. **Commit 1 — Pipeline `isFinal` propagation** (Option B core)
   - Changes: `TranscriptionResult`, `TranscriptionPipeline`, `ParaformerStreamingEngine`, `AppleSpeechASREngine`, dictation regression test.
   - At end of this commit: translation still doesn't work end-to-end, but the foundation is correct. Dictation behavior unchanged.

2. **Commit 2 — TranslateProcessor wiring + bilingual sink** (Option C)
   - Changes: `TranslateProcessor`, `SubtitleOverlaySink`, `SubtitleWriter` protocol, `PipelineProvider.applyTranslation`, `SubtitleOverlayView` (remove onChange), `TranslationController` (remove `isTranslating`).
   - At end of this commit: translation works end-to-end.

This ordering means commit 1 is reviewable on its own as a contract change, and commit 2 is reviewable on its own as a wiring change. Each commit leaves the app in a buildable, testable state.

## Out of scope

- Reverse direction (zh→en).
- Microphone input as translation source.
- Multiple language pairs.
- Streaming translation of `partialText` (translating before sentence end).
- Removing dead `TextInjectorSink`/`ClipboardSink`. They appear unused but may be referenced from tests or planned for future use; out of scope for this fix.
