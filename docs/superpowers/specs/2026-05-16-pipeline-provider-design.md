# PipelineProvider — Decoupling Pipeline Assembly from the Popover View

**Date:** 2026-05-16
**Status:** Proposed
**Author:** brainstormed with Claude

## Problem

Clicking the menubar icon takes ~1 second before the popover responds. The cause
is `MenuBarPopoverView` carrying a `.task { … }` modifier
(`NemoNoise/App/NemoNoiseApp.swift:39-80`) that does three pieces of heavy
synchronous work on the MainActor every time the popover view is reconstructed:

1. `Self.makePunctuator(...)` loads a Sherpa ONNX punctuation model.
2. `buildDictation()` → `factory.makeUserPreferred()` loads the user's chosen
   ASR engine (e.g. Paraformer = `encoder.int8.onnx` + `decoder.int8.onnx`).
3. `factory.makeForTranslation()` loads a *second* Paraformer instance for the
   translation pipeline.

Because the task body contains no `await`, the async function runs to
completion on the MainActor — equivalent to synchronous blocking. With
`MenuBarExtra(style: .window)` the content view is rebuilt on every open, so
this work re-runs on every click, also leaking the previously-bound pipeline.

This violates two things the project already has written down:

- `docs/architecture.md` declares **"Controllers are UI state adapters /
  `NemoNoiseApp` does assembly."** The popover view does not belong in the
  assembly path.
- `CLAUDE.md` § Simplicity & Surgical Changes: assembly logic in the view layer
  has accreted because there was no obvious home for it.

## Goals

1. Menubar popover opens instantly — no MainActor stall on engine init.
2. Pipeline assembly lives in one named, testable, single-responsibility
   object, not in a SwiftUI `.task` and a `pipelineRebuildHandler` closure.
3. Settings-driven engine swaps continue to work (already feature-complete);
   the rewire path becomes a typed method call instead of an ad-hoc closure.
4. Failures degrade gracefully and are visible to the user (toast / popover
   state), per CLAUDE.md "Toast over Alert."

## Non-goals

- Changing the `AudioSource → ASREngine → PostProcessor → Sink` composition.
- Changing engine implementations or model formats.
- Lazy-loading engines (the user picked eager background warm-up).

## Approach

Introduce `App/PipelineProvider.swift` — a `@MainActor @Observable` service
that owns engine + pipeline lifecycle for the entire app. It is a peer to
`RecordingController`, `TranslationController`, and `RecordingMutex`.

### Component placement

```
App/
├── NemoNoiseApp.swift           ← only wiring; .task and rebuild closure removed
├── RecordingController.swift     ← signature stable; rebuild closure removed
├── TranslationController.swift   ← signature stable
├── RecordingMutex.swift          ← unchanged
└── PipelineProvider.swift        ← NEW (~100 LOC)
```

`Services/` is untouched, except `ASREngineFactory.swift` which is pulled into
a small but worthwhile refactor (see below).

### Interface

```swift
@MainActor @Observable
final class PipelineProvider {
    enum Readiness: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var dictation:    Readiness = .loading
    private(set) var translation:  Readiness = .loading

    init(factory: any ASREngineFactoring,
         modelManager: ModelManager,
         mutex: RecordingMutex,
         recording: RecordingController,
         translation: TranslationController)

    /// Called once from NemoNoiseApp. Schedules background engine load.
    func bootstrap()

    /// Called by RecordingController.requestPipelineRebuild() when Settings
    /// changes engine choice. Reuses the cached punctuator.
    func rebuildDictation()
}
```

### Lifecycle

#### Bootstrap (App launch, once)

```swift
func bootstrap() {
    Task.detached(priority: .userInitiated) { [self] in
        // Background thread — Sherpa ONNX init is CPU/IO, no MainActor needed.
        let punctuator = makePunctuator()                     // may be nil
        let primary    = try? factory.makePrimary()           // EngineBuild
        let fallback   = factory.makeFallback()
        let translation = try? factory.makeTranslation()      // EngineBuild

        await MainActor.run {
            cachedPunctuator = punctuator
            applyDictation(primary: primary, fallback: fallback, punctuator: punctuator)
            applyTranslation(engine: translation, punctuator: punctuator)
            translationController.startHotkeyMonitoring()
        }
    }
}
```

`apply*` methods assemble `TranscriptionPipeline`, call
`controller.bind(pipeline:mutex:)`, set readiness, and surface
`fallbackReason` toasts.

#### Rebuild (Settings → engine choice change)

```swift
func rebuildDictation() {
    dictation = .loading
    Task.detached(priority: .userInitiated) { [self] in
        let primary  = try? factory.makePrimary()
        let fallback = factory.makeFallback()
        await MainActor.run {
            applyDictation(primary: primary, fallback: fallback,
                           punctuator: cachedPunctuator)   // reuse cache
        }
    }
}
```

The `recordingState == .ready` guard already exists in
`RecordingController.requestPipelineRebuild()` and stays where it is.

#### Hotkey while loading

`RecordingController.startRecording()` currently early-returns silently when
`pipeline == nil`. Add a one-line user-facing fallback:

```swift
guard pipeline != nil else {
    ToastWindowController.show("Engines warming up…", style: .info, duration: 1.5)
    return
}
```

#### Popover readiness UI

`MenuBarPopoverView` adds a small loading row when
`provider.dictation == .loading`:

```swift
if provider.dictation == .loading {
    HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Preparing engines…").font(.caption).foregroundStyle(.secondary)
    }
}
```

If `.failed(msg)`, show the message in a warning chip with the same styling as
the existing `engineFallbackWarning`.

### Failure handling

| Scenario | Behavior |
|---|---|
| User picked Paraformer/SenseVoice but model not downloaded | Factory falls back to Apple Speech; `dictation = .ready`; existing fallback warning rendered |
| Apple Speech init also fails (rare — no permission) | `dictation = .failed("Speech recognition unavailable")`; popover shows error |
| Translation Paraformer fails | `translation = .failed(...)` only; **dictation is not blocked** |
| Punctuator fails | Silent + warn log; not a hard failure (post-processor is optional) |
| Rebuild fails | Keep old pipeline running; toast `"Couldn't switch to <engine>"`; `dictation` returns to `.ready` |

`dictation` and `translation` track readiness independently so one engine's
failure cannot cascade.

### Factory purification (necessary side cleanup)

`ASREngineFactory.makeUserPreferred()` currently calls
`ToastWindowController.show(...)` directly when falling back to Apple Speech.
This mixes construction with UI side effects and forces `@MainActor` on the
factory. Refactor:

```swift
struct EngineBuild {
    let engine: any ASREngine
    let fallbackReason: String?    // human-readable; nil if user's primary built
}

protocol ASREngineFactoring {
    func makePrimary() throws -> EngineBuild       // renamed from makeUserPreferred
    func makeTranslation() throws -> EngineBuild   // renamed from makeForTranslation
    func makeFallback() -> (any ASREngine)?
}

final class ASREngineFactory: ASREngineFactoring { /* @MainActor removed */ }
```

The shorter names track the new return type and the migration is mechanical
(call sites all live in `PipelineProvider` after this refactor).

`PipelineProvider` shows the toast (on MainActor) using
`EngineBuild.fallbackReason`. The factory is now pure construction logic;
`ASREngineFactoring` enables unit testing without real ONNX models.

### Dependency direction

```
NemoNoiseApp ──holds──▶ PipelineProvider ──holds──▶ {factory, controllers}
                              │
                              └──reads──▶ ModelManager, RecordingMutex

RecordingController ──onRebuildRequested closure──▶ PipelineProvider
    (RecordingController never imports PipelineProvider; the closure is set
     by PipelineProvider during init and stored as an opaque () -> Void)
```

Controllers do not know `PipelineProvider` exists. The current
`pipelineRebuildHandler: (@MainActor () -> Void)?` field on
`RecordingController` is replaced by an equivalent
`onRebuildRequested: (@MainActor () -> Void)?` field set inside
`PipelineProvider.init`. Same shape, named owner.

## Change set

| File | Change |
|---|---|
| `App/PipelineProvider.swift` | **New** (~100 LOC) |
| `App/NemoNoiseApp.swift` | Delete the 40+ line `.task`; construct `PipelineProvider(...)` and call `bootstrap()`; delete `pipelineRebuildHandler` wiring |
| `App/RecordingController.swift` | Rename field to `onRebuildRequested`; `startRecording()` shows "Engines warming up…" toast when `pipeline == nil` |
| `App/TranslationController.swift` | No logic change (its `startHotkeyMonitoring()` call moves from popover task into `PipelineProvider.bootstrap()`) |
| `Services/ASR/ASREngineFactory.swift` | Return `EngineBuild`; remove `@MainActor`; extract `ASREngineFactoring` protocol; remove `notifyFallback` UI call |
| `UI/Menubar/MenubarView.swift` | Add `@Environment(PipelineProvider.self)`; render "Preparing engines…" row when `.loading`; render error chip when `.failed` |
| `NemoNoiseTests/PipelineProviderTests.swift` | **New** — state machine tests using mock `ASREngineFactoring` |

## Testing strategy

Per `docs/architecture.md` (real engines stay manual QA):

| Test | Layer | Mechanism |
|---|---|---|
| `dictation: .loading → .ready` after bootstrap | unit | inject mock `ASREngineFactoring` returning mock engines |
| `translation` failure does not affect `dictation` readiness | unit | mock factory throws on `makeTranslation`, succeeds on `makePrimary` |
| Rebuild while `recordingState == .recording` is rejected | already covered | `RecordingController.requestPipelineRebuild` guard test |
| Cached punctuator is reused across rebuild | unit | spy on `makePunctuator` call count |
| Cold-start engine load duration | manual QA | Console: `"Model loaded, init duration: …"` |
| Popover open feels instant | manual QA | menubar click after fresh launch |

## Risks and open questions

- **Sherpa engine init on background thread.** Engine classes are
  `@unchecked Sendable`. ONNX runtime initialization (`SherpaOnnxCreate*`) is
  not documented as MainActor-bound and is currently called from a Swift
  initializer with no MainActor isolation requirement. Risk is low. If issues
  surface, fallback is to keep init on MainActor but yield with
  `await Task.yield()` periodically — though that does not address the root
  performance issue. **Mitigation:** smoke-test on first build before
  declaring done.

- **`controller.bind(pipeline:)` called after view body may have already
  read `controller.pipeline`.** Controllers expose state, not pipeline; views
  read state. `bind` mutating the internal pipeline field does not trigger
  view invalidation, which is fine — readiness state on `PipelineProvider`
  does, and that is what the view observes.

- **Two ParaformerStreamingEngine instances loaded eagerly.** This is current
  behavior, not introduced here. If memory becomes a concern, follow-up work
  could share an engine instance between dictation and translation — out of
  scope for this spec.

## Decision log

- **Approach A (PipelineProvider) chosen over** putting assembly into
  controllers (B) or inline in App.init (C). A keeps controllers as pure UI
  state adapters per existing architecture doctrine; B violates that; C
  preserves the closure inversion problem.
- **Factory purification included** because keeping `@MainActor` on the
  factory blocks clean background construction and the toast call is
  fundamentally misplaced.
- **Translation readiness tracked separately** from dictation so one engine
  failing does not block the other.
- **`cachedPunctuator` reused on rebuild** to save ~200-500ms per engine swap.
