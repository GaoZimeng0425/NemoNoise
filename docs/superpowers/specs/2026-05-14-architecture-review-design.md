# Architecture Refactor — Pipeline-First Design

**Date:** 2026-05-14
**Status:** Approved (brainstorming complete; awaiting implementation plan)
**Scope:** System-wide architecture refactor. No feature work in parallel.

---

## 1. Why

NemoNoise's three near-term growth directions all extend the same axis:

1. ASR ecosystem expansion (more engines / providers)
2. Audio source diversity (file, mixed sources, app-specific)
3. AI post-processing + translation deepening (LLM cleanup, vocab replacement, more translation targets)

The current architecture has these directions colliding head-on with the structure:

- `RecordingController` (351 lines) and `TranslationController` (192 lines) each implement their own audio→ASR loop. Engine fallback exists in dictation, not in translation. Adding a new audio source would mean a third copy of the loop.
- `SpeechOrchestrator` is hard-coded to `AudioCapture` (mic only); it cannot serve translation.
- The engine factory logic appears twice (in `SpeechOrchestrator.makeEngine` and again in `TranslationController.startTranslation`).
- Cross-controller mutex is wired via mutual weak references and closure callbacks.
- Error handling uses brittle string matching (`error.localizedDescription.contains("Siri and Dictation are disabled")`).
- `RecordingController` mixes UI presentation (NSAlert), business logic, lifecycle, and accessibility plumbing.

This refactor introduces a **`TranscriptionPipeline`** as a first-class composition: any combination of `(AudioSource, ASREngine, [PostProcessor], Sink)` becomes a runnable pipeline. The two controllers shrink to UI state adapters bound to a pre-configured pipeline.

---

## 2. Architecture

### 2.1 Conceptual model

```
AudioSource → ASREngine → [PostProcessor...] → Sink
```

| Stage | Role | Examples (now / future) |
|-------|------|--------------------------|
| **AudioSource** | Produces `AsyncStream<AudioChunk>` at 16 kHz mono Float | mic, system audio / file, mixed |
| **ASREngine** | Streaming `feedChunk` + `finish` returns `TranscriptionResult` | Apple, Cloud, Sherpa, Paraformer / Whisper, OpenAI, Deepgram |
| **PostProcessor** | Transforms intermediate results | (empty in v1) / LLM rewrite, vocab replace, translate |
| **Sink** | Delivers final results to UI / OS | TextInjectorSink, SubtitleOverlaySink, ClipboardSink |

The shape is **fixed** (not a generic DAG). Reasoning: every current scenario matches it; a fully dynamic stage graph would add runtime-type erasure overhead and debugging complexity without payoff.

### 2.2 Core protocols

```swift
protocol AudioSource: Sendable {
    func start() async throws -> AsyncStream<AudioChunk>
    func stop()
}

protocol ASREngine: Sendable {
    var isStreaming: Bool { get }                  // default true
    func reset()
    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult
    func finish() async throws -> TranscriptionResult
}

protocol PostProcessor: Sendable {
    /// Returns nil to pass through unchanged.
    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult?
}

protocol Sink: Sendable {
    func deliver(_ result: TranscriptionResult, isFinal: Bool) async
}
```

### 2.3 Combinator

```swift
@MainActor
final class TranscriptionPipeline {
    init(
        source: AudioSource,
        engine: ASREngine,
        postProcessors: [PostProcessor] = [],
        sink: Sink,
        fallback: (any ASREngine)? = nil      // optional; used only by dictation
    )

    func start() -> AsyncThrowingStream<PipelineEvent, Error>
    func finalize() async throws -> TranscriptionResult
    func stop()                                // cancels without finalizing
}

enum PipelineEvent: Sendable {
    case partial(TranscriptionResult, rmsLevel: Float)
    case final(TranscriptionResult)
    case engineFallback(from: String)
    case rms(Float)
    case injectionFailed                       // emitted by TextInjectorSink on AX failure; controller may show accessibility alert
}
```

**`@MainActor` placement rationale:** the pipeline coordinates and dispatches to sinks, both of which need main-thread access for SwiftUI `@Observable` and AppKit UI. The expensive work (`feedChunk`) is `async` and runs off-main; backpressure is natural via `await`.

**Reusability:** a pipeline instance can `start`/`stop` repeatedly. The engine is `reset()` on each start. This avoids rebuilding the audio source / engine / sink graph per recording.

### 2.4 Lifecycle

```
created → idle ─start()→ running ─finalize()→ finalizing → idle
              ↘                          ↗
               └──── stop()/error ──────┘
```

State transitions are guarded inside the pipeline; external code cannot mutate state directly. Mirrors the current `RecordingState` enum, just one level down.

### 2.5 Mutex

`RecordingMutex` replaces the current mutual-weak-reference pattern between the two controllers:

```swift
@MainActor
final class RecordingMutex {
    enum Owner { case dictation, translation }
    private(set) var current: Owner?
    func tryAcquire(_ owner: Owner) -> Bool
    func release(_ owner: Owner)
}
```

Owned by `NemoNoiseApp`, injected into both controllers.

---

## 3. Data Flow

### 3.1 Dictation (mic → engine → inject)

Pipeline assembled once at app startup:

```swift
let dictationPipeline = TranscriptionPipeline(
    source: MicAudioSource(),
    engine: factory.makeUserPreferred(),
    postProcessors: [],
    sink: BroadcastSink([
        TextInjectorSink(injector: textInjector),
        OverlayProgressSink(controller: overlay)
    ]),
    fallback: try? AppleSpeechASREngine()
)
recordingController.bind(pipeline: dictationPipeline)
```

Hotkey-down flow:
1. Controller: mic permission check, `RecordingMutex.tryAcquire(.dictation)`, `textInjector.captureTarget()` (must happen at hotkey DOWN — race-condition fix per existing memory), set `state = .recording`, show overlay.
2. Controller: `for try await event in pipeline.start()` — maps `PipelineEvent` to `@Observable` state.
3. Pipeline internally: `source.start()` → `engine.reset()` → loop over audio chunks → `engine.feedChunk` → post-processors → `sink.deliver` → yield `.partial`. Engine fallback handled here.

Hotkey-up flow:
1. Controller: `state = .processing`, stop timer / ESC monitor.
2. Controller: `let final = try await pipeline.finalize()`.
3. Pipeline `finalize` runs `engine.finish`, then sinks fire. `TextInjectorSink` attempts AX injection; on failure it composes `ClipboardSink` internally (clipboard set + toast) and returns the outcome as an additional `PipelineEvent.injectionFailed` (added to the event enum). Controller catches that event and shows the accessibility alert if `AXIsProcessTrusted()` is false.
4. Controller: append `final` to `confirmedSegments`, set `state = .ready`, schedule overlay hide, `RecordingMutex.release(.dictation)` (always, also on error — see §5.6).

### 3.2 Translation (system audio → engine → translate → subtitle)

```swift
let translationPipeline = TranscriptionPipeline(
    source: SystemAudioSource(),
    engine: factory.makeForTranslation(),
    postProcessors: [TranslateProcessor(service: AppleTranslationService())],
    sink: SubtitleOverlaySink(controller: subtitleOverlay),
    fallback: nil
)
```

Same loop. `TranslateProcessor` returns `nil` for partial results (skip — translation of partials is expensive and unstable) and translates only on `isFinal=true`.

No engine fallback in translation (preserves current behavior — explicit decision, not oversight).

---

## 4. Component Mapping

### 4.1 Renames / moves
| Current | New |
|---------|-----|
| `Services/ASR/ASRService.swift` (protocol) | `Services/ASR/ASREngine.swift` |
| `Services/Audio/AudioCapture.swift` | `Services/Audio/MicAudioSource.swift` |
| `Services/Audio/SystemAudioCapture.swift` | `Services/Audio/SystemAudioSource.swift` |
| `Models/ASRModels.swift` | split into `TranscriptionResult.swift`, `RecordingState.swift`, `ASRError.swift` |
| `ContinuationBox` (duplicated in MicAudioSource + SystemAudioSource) | extracted to shared file |

### 4.2 New files
| File | Purpose |
|------|---------|
| `Services/Audio/AudioSource.swift` | protocol |
| `Services/ASR/ASREngineFactory.swift` | consolidates engine creation |
| `Services/Pipeline/TranscriptionPipeline.swift` | combinator |
| `Services/Pipeline/PipelineEvent.swift` | event enum |
| `Services/Pipeline/Sink.swift` | protocol |
| `Services/Pipeline/PostProcessor.swift` | protocol (empty slot for v1) |
| `Services/Pipeline/BroadcastSink.swift` | multi-sink fan-out |
| `Services/Sinks/TextInjectorSink.swift` | wraps existing `TextInjector`; on AX failure composes `ClipboardSink` internally and emits `PipelineEvent.injectionFailed` |
| `Services/Sinks/SubtitleOverlaySink.swift` | pushes to `SubtitleOverlayController` |
| `Services/Sinks/ClipboardSink.swift` | reusable clipboard delivery (used standalone or composed by `TextInjectorSink`); currently inlined in `RecordingController.injectText` |
| `Services/Sinks/OverlayProgressSink.swift` | pushes partial text to overlay |
| `Services/PostProcessors/TranslateProcessor.swift` | wraps `AppleTranslationService` |
| `App/RecordingMutex.swift` | replaces inter-controller closure handshake |
| `UI/Permissions/MicPermissionAlert.swift` | extracted from controller |
| `UI/Permissions/AccessibilityAlert.swift` | extracted from controller |
| `UI/Permissions/ScreenRecordingAlert.swift` | extracted from controller |

### 4.3 Deletions
- `Services/ASR/SpeechOrchestrator.swift` — replaced by `TranscriptionPipeline`
- `NemoNoiseTests/SpeechOrchestratorTests.swift` — covered by `TranscriptionPipelineTests`

### 4.4 Shrinkage
- `RecordingController.swift`: 351 → ~150 lines (drops audio loop, engine factory, injection logic, alert UI)
- `TranslationController.swift`: 192 → ~80 lines (drops ASR loop, capture ownership, engine factory, alert UI)

### 4.5 Unchanged
- `TextInjector` (still the low-level capability; `TextInjectorSink` wraps it with strategy)
- All UI files except the three extracted alerts
- All engine implementations (only the protocol name updates: `ASRService` → `ASREngine`)
- `SherpaOnnxWrapper`, `ModelManager`, `LogService`, `KeychainService`, `HotkeyMonitor`, etc.

---

## 5. Error Handling

### 5.1 Typed errors

```swift
enum PipelineError: Error {
    case sourceUnavailable(underlying: Error)      // mic / screen permission / hardware
    case engineFailedFatally(underlying: Error)    // no fallback usable
    case finalizeFailed(underlying: Error)
}
```

The pipeline emits semantic errors. User-facing presentation (NSAlert, Toast, copy strings) lives in controllers.

### 5.2 Fallback behavior (preserved from current)

| Trigger | Behavior |
|---------|----------|
| First `feedChunk` throws (dictation) | Pipeline switches to `fallback` engine, yields `.engineFallback(from:)`, continues |
| Post-fallback throw | Surfaces `.engineFailedFatally` |
| `finalize` throws `CloudASRError.authenticationFailed` | Surfaces; controller shows toast about API key |
| `finalize` throws `CloudASRError.requestTimeout` | Returns empty `TranscriptionResult` |
| Translation engine failure | No fallback; surfaces error |

### 5.3 Error typing scope

Only the throws that are currently `catch`-matched by string get strong types (specifically `AppleSpeechError.siriDisabled`). Throws that nobody catches stay generic — typing them costs and pays nothing.

### 5.4 Resource cleanup

| Resource | Owner | Cleanup trigger |
|----------|-------|-----------------|
| `AVAudioEngine` tap | `MicAudioSource.stop` | stream termination |
| `SCStream` | `SystemAudioSource.stop` | stream termination |
| Sherpa C pointers | engine `deinit` | engine deallocation |
| Pipeline internal `Task` | pipeline | `stop()` |
| `LogService.endSession()` | **Controller, not pipeline** | user-visible recording boundary differs from pipeline boundary |

### 5.5 Cancellation semantics

- `stopRecording` (user finished talking) → `pipeline.finalize()` — drains tail audio.
- `cancelRecording` (ESC, error) → `pipeline.finalize()` — same path; preserves current ESC behavior of keeping tail audio. (Explicit decision; `stop()` for hard discard exists but isn't currently used.)

### 5.6 Mutex release invariant

Both controllers must release `RecordingMutex` in **every** terminal path: happy-path finish, user cancel, ESC, and every error branch. The simplest implementation is a `defer { mutex.release(.dictation) }` immediately after `tryAcquire` succeeds. Unit test in `RecordingMutexTests` covers acquire-then-throw scenarios.

---

## 6. Testing Strategy

| Layer | Test type | Tooling |
|-------|-----------|---------|
| Protocols (conformance + interface) | unit | XCTest with fakes |
| `TranscriptionPipeline` | unit, IO-free | fake `AudioSource` + fake `ASREngine` |
| `ASREngineFactory` | unit | user-pref → engine type mapping; fallback ordering |
| Sinks | unit | mock collaborators |
| `BroadcastSink` | unit | verify fan-out + isolated failure |
| `TranslateProcessor` | unit | partial passthrough; final translation; failure non-blocking |
| `RecordingMutex` | unit | acquire / release / ownership |
| Controller state mapping | unit | inject fake pipeline; assert `@Observable` state transitions |
| Real engines / real audio sources | manual QA | per-stage QA checklist |

**Required coverage:** Pipeline / Factory / Sink / PostProcessor / Mutex must have unit tests. Controllers should have state-mapping tests. Real engines and real audio are validated through manual QA.

---

## 7. Stage Plan

Each stage ends with: main compiles, app runs, tests pass. No backward-compat shims (no parallel feature shipping during refactor).

### Stage 0 — Renames + Models split
- `ASRService` → `ASREngine`; `AudioCapture` → `MicAudioSource`; `SystemAudioCapture` → `SystemAudioSource`.
- Split `Models/ASRModels.swift`.
- Extract shared `ContinuationBox`.
- **Verify:** existing tests pass; diff is rename/move only.

### Stage 1 — `AudioSource` protocol + `ASREngineFactory`
- Add `AudioSource` protocol; declare conformance on `MicAudioSource` / `SystemAudioSource` (interfaces already match).
- New `ASREngineFactory` absorbing both existing engine-construction sites.
- Update `SpeechOrchestrator` and `TranslationController` to use the factory.
- **New tests:** `ASREngineFactoryTests`.
- **Verify:** no direct `try ParaformerStreamingEngine(...)` etc. anywhere outside factory.

### Stage 2 — Pipeline skeleton (no controllers using it yet)
- Add `TranscriptionPipeline`, `PipelineEvent`, `Sink`, `PostProcessor`, `BroadcastSink`.
- Implement `TextInjectorSink`, `SubtitleOverlaySink`, `ClipboardSink`, `OverlayProgressSink`.
- Empty `PostProcessor` slot; no LLM yet.
- **New tests:** `TranscriptionPipelineTests` (start/finalize, fallback, multi-start, error propagation), `BroadcastSinkTests`, `TextInjectorSinkTests`.
- **Verify:** pipeline ≥ 80% line coverage; no behavior change in app.

### Stage 3 — Migrate `TranslationController` to pipeline (PoC)
- Translation chosen first: no fallback, no injection, no `captureTarget`, no ESC — simplest validator for pipeline design.
- `TranslationController` holds a pre-built `TranscriptionPipeline`.
- `TranslateProcessor` implementation.
- Three permission alerts extracted to `UI/Permissions/`.
- **New tests:** `TranslateProcessorTests`.
- **Manual QA:** full translation flow (system audio → English ASR → Chinese subtitle).
- **Verify:** `TranslationController` ≤ 100 lines; behavior equivalent to pre-refactor.

### Stage 4 — Migrate `RecordingController` + delete `SpeechOrchestrator`
- `RecordingController` holds dictation pipeline (with fallback engine).
- Delete `SpeechOrchestrator.swift` and tests.
- Inject-text logic moves into `TextInjectorSink` (including clipboard fallback + accessibility alert trigger).
- `RecordingMutex` introduced; bilateral weak references between controllers removed.
- Error handling typed: replace `error.localizedDescription.contains(...)` with `PipelineError` catches.
- **New tests:** `RecordingMutexTests`.
- **Manual QA checklist (mandatory, in PR description):**
  - Mic-normal happy path
  - Mic denied
  - Engine fallback (disconnect network, trigger cloud failure)
  - Injection failure (focus on an app without accessibility permission)
  - ESC interrupt
- **Verify:** `RecordingController` ≤ 200 lines; `SpeechOrchestrator.swift` no longer exists; all 5 manual cases pass.

### Stage 5 — Cleanup + docs
- Remove any dead helpers exposed by stage 4.
- Update `CLAUDE.md` / `README.md` architecture description.
- Write `docs/architecture.md` (half page) covering "how to add a new ASR engine / audio source / post-processor".
- **Verify:** new contributor can add a hypothetical engine following docs without touching pipeline code.

---

## 8. Explicit Non-Goals

- No LLM post-processing implementation (slot only).
- No new ASR engines.
- No new audio sources.
- No automatic engine retry logic.
- No engine health checks (pre-flight pings).
- No DI container introduction. Constructor injection only.
- No App Store / sandbox / IAP work (separate effort).
- No commercial-readiness items (telemetry, licensing) — separate spec.
- No UI redesign. Existing menubar / overlay / onboarding untouched except for three extracted alerts.

---

## 9. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Pipeline protocol design wrong on first try → cascading rework | Stage 3 (translation migration) is the cheap proving ground. If pipeline doesn't fit translation cleanly, redesign before stage 4. |
| Engine streaming semantics differ across providers (Apple owns its loop; Sherpa is chunk-fed; Cloud is finalize-only) | The current `ASRService` protocol already accommodates all three — refactor reuses it unchanged. |
| `captureTarget()` timing regression (cursor race) | Explicit invariant in design: must run at hotkey DOWN in controller, *before* `pipeline.start()`. Test it manually in stage 4 QA. |
| Multi-start/stop pipeline reuse introduces stale state | Each `start()` calls `engine.reset()`; pipeline state machine guards against double-start. Unit-tested in `TranscriptionPipelineTests`. |
| Inter-controller mutex regressions (translation starts while dictation is processing) | `RecordingMutexTests` covers acquire/release; integration check in stage 4 manual QA. |
| Removing `SpeechOrchestrator` orphans tests | `SpeechOrchestratorTests` deleted as a single commit alongside the orchestrator file; replacement coverage already in `TranscriptionPipelineTests` (delivered in stage 2). |

---

## 10. Open Questions

None at spec time. All design decisions resolved during brainstorming:

- Pipeline shape: fixed (not generic DAG). ✓
- PostProcessor return convention: `nil` for passthrough. ✓
- Injection ownership: `TextInjectorSink`. ✓
- Translation fallback: not added. ✓
- ESC: continues to call `finalize`, preserves tail. ✓
- Error typing: only where currently caught. ✓
- Multi-start pipeline reuse: yes. ✓
- Stage order: 0 → 1 → 2 → 3 → 4 → 5. ✓
