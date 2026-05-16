# PipelineProvider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate ~1s menubar popover stall by moving pipeline assembly off the popover view into a new `PipelineProvider` service that loads engines on a background thread.

**Architecture:** A `@MainActor @Observable` service (`App/PipelineProvider.swift`) owns engine + pipeline lifecycle. It uses `Task.detached` to construct ONNX engines off the main thread, then hops back to MainActor to call `controller.bind(pipeline:mutex:)`. The popover view stops doing assembly; it only observes readiness state. The factory is purified to return `EngineBuild` and loses its `@MainActor` annotation so it can be called from background.

**Tech Stack:** Swift 5.9+, SwiftUI, `@Observable`, Swift concurrency (`Task.detached`, `MainActor.run`), XCTest. Build with `xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise`.

**Spec:** `docs/superpowers/specs/2026-05-16-pipeline-provider-design.md`

---

## File map

| File | Operation | Responsibility after change |
|---|---|---|
| `NemoNoise/Services/ASR/ASREngineFactory.swift` | Modify | Pure engine construction. Returns `EngineBuild`. Conforms to new `ASREngineFactoring` protocol. No `@MainActor`. No UI calls. |
| `NemoNoise/App/PipelineProvider.swift` | Create | Bootstraps engines off-main, holds pipelines, exposes readiness, handles rebuild. |
| `NemoNoise/App/NemoNoiseApp.swift` | Modify | Constructs `PipelineProvider`, calls `bootstrap()`, injects into env. No more `.task` body. No more `pipelineRebuildHandler` closure setup. |
| `NemoNoise/App/RecordingController.swift` | Modify | Add "engines warming up" toast in `startRecording()` when `pipeline == nil`. (Field rename optional — see Task 4 note.) |
| `NemoNoise/App/TranslationController.swift` | No edit | `startHotkeyMonitoring()` call moves to `PipelineProvider.bootstrap()` (which calls the existing public method). |
| `NemoNoise/UI/Menubar/MenubarView.swift` | Modify | Read `PipelineProvider` from environment; show "Preparing engines…" row when loading, error chip when failed. |
| `NemoNoiseTests/ASREngineFactoryTests.swift` | Modify | Update assertions to the new `EngineBuild` return type and renamed methods. |
| `NemoNoiseTests/PipelineProviderTests.swift` | Create | State-machine tests using a stub `ASREngineFactoring`. |

---

## Task 1: Factory refactor — `EngineBuild` + `ASREngineFactoring` protocol

**Goal:** Make the factory pure construction (no UI side effects, no MainActor isolation) so `PipelineProvider` can call it from a detached task.

**Files:**
- Modify: `NemoNoise/Services/ASR/ASREngineFactory.swift`
- Modify: `NemoNoiseTests/ASREngineFactoryTests.swift`

---

- [ ] **Step 1.1: Update the failing tests first**

Replace the body of `NemoNoiseTests/ASREngineFactoryTests.swift` with:

```swift
import XCTest
@testable import NemoNoise

final class ASREngineFactoryTests: XCTestCase {

    private func makeFactory() -> ASREngineFactory {
        ASREngineFactory(modelManager: ModelManager())
    }

    // MARK: - Primary engine

    func testMakePrimaryFallsBackToAppleWhenPreferenceMissing() throws {
        UserDefaults.standard.removeObject(forKey: AppDefaults.Keys.engineType)
        let factory = makeFactory()
        let build = try factory.makePrimary()
        XCTAssertNotNil(build.engine)
    }

    func testMakePrimaryHonoursApplePreference() throws {
        UserDefaults.standard.set("apple", forKey: AppDefaults.Keys.engineType)
        let factory = makeFactory()
        let build = try factory.makePrimary()
        XCTAssertTrue(build.engine is AppleSpeechASREngine,
                      "expected Apple, got \(type(of: build.engine))")
        XCTAssertNil(build.fallbackReason, "Apple was the user's choice — no fallback reason expected")
    }

    func testMakePrimarySurfacesFallbackReasonWhenCloudKeyMissing() throws {
        UserDefaults.standard.set("cloud", forKey: AppDefaults.Keys.engineType)
        KeychainService.delete(key: KeychainService.Keys.cloudAPIKey)
        let factory = makeFactory()
        let build = try factory.makePrimary()
        XCTAssertTrue(build.engine is AppleSpeechASREngine,
                      "expected Apple fallback, got \(type(of: build.engine))")
        XCTAssertNotNil(build.fallbackReason, "fallback reason must be surfaced for UI to toast")
    }

    // MARK: - Translation engine

    func testMakeTranslationReturnsValidEngine() throws {
        let factory = makeFactory()
        let build = try factory.makeTranslation()
        XCTAssertTrue(build.engine is AppleSpeechASREngine || build.engine is ParaformerStreamingEngine)
    }

    // MARK: - Fallback engine for dictation

    func testMakeFallbackReturnsAppleSpeechWhenAuthorized() throws {
        let factory = makeFactory()
        // makeFallback returns nil unless Speech is authorized; in CI / fresh
        // checkout it may be nil — assert the contract holds (nil or Apple).
        if let fallback = factory.makeFallback() {
            XCTAssertTrue(fallback is AppleSpeechASREngine)
        }
    }
}
```

- [ ] **Step 1.2: Run tests to verify they fail**

```bash
xcodebuild test \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/ASREngineFactoryTests 2>&1 | tail -40
```

Expected: compile errors / failures referencing missing `makePrimary`, `makeTranslation`, and `EngineBuild`.

- [ ] **Step 1.3: Rewrite `ASREngineFactory.swift`**

Replace the entire file at `NemoNoise/Services/ASR/ASREngineFactory.swift`:

```swift
import Foundation
import Speech

/// Returned by `ASREngineFactoring.make*`. If `fallbackReason` is non-nil, the
/// caller should surface it to the user (toast / popover). The factory itself
/// does not display UI — that mixing was the reason it used to require
/// `@MainActor`.
struct EngineBuild: Sendable {
    let engine: any ASREngine
    let fallbackReason: String?
}

protocol ASREngineFactoring: Sendable {
    func makePrimary() throws -> EngineBuild
    func makeTranslation() throws -> EngineBuild
    func makeFallback() -> (any ASREngine)?
}

/// Single place to construct ASR engines. Reads `UserDefaults` for the user's
/// preferred engine and `Keychain` for API keys, with predictable fallback to
/// Apple Speech when models or keys are missing.
final class ASREngineFactory: ASREngineFactoring {
    private let modelManager: ModelManager

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    /// Build the engine the user has selected in Settings. Falls back to Apple
    /// Speech if the chosen engine's prerequisites (model files, API key) are
    /// not satisfied — `fallbackReason` carries the human-readable cause.
    func makePrimary() throws -> EngineBuild {
        let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType) ?? AppDefaults.Defaults.engineType
        LogService.info("Factory creating engine: \(choice)", category: "ASREngineFactory")

        var fallbackReason: String?

        switch choice {
        case "sensevoice":
            if let dir = modelManager.modelPath(for: .senseVoice) {
                let engine = try SherpaASREngine(modelDir: dir)
                return EngineBuild(engine: engine, fallbackReason: nil)
            }
            LogService.warn("SenseVoice model not found, falling back to Apple", category: "ASREngineFactory")
            fallbackReason = "SenseVoice model not installed — using Apple Speech. Open Settings to download."
        case "paraformer":
            if let dir = modelManager.modelPath(for: .paraformer) {
                let engine = try ParaformerStreamingEngine(modelDir: dir)
                return EngineBuild(engine: engine, fallbackReason: nil)
            }
            LogService.warn("Paraformer model not found, falling back to Apple", category: "ASREngineFactory")
            fallbackReason = "Paraformer model not installed — using Apple Speech. Open Settings to download."
        case "qwen3":
            if let dir = modelManager.modelPath(for: .qwen3) {
                let engine = try Qwen3ASREngine(modelDir: dir)
                return EngineBuild(engine: engine, fallbackReason: nil)
            }
            LogService.warn("Qwen3 model not installed, falling back to Apple", category: "ASREngineFactory")
            fallbackReason = "Qwen3 model not installed — using Apple Speech. Open Settings to download."
        case "cloud":
            if let apiKey = KeychainService.load(key: KeychainService.Keys.cloudAPIKey), !apiKey.isEmpty {
                return EngineBuild(engine: CloudASREngine(apiKey: apiKey), fallbackReason: nil)
            }
            LogService.warn("Cloud API key not set, falling back to Apple", category: "ASREngineFactory")
            fallbackReason = "Cloud API key not set — using Apple Speech. Set the key in Settings."
        case "apple":
            break
        default:
            LogService.warn("Unknown engine choice '\(choice)', falling back to Apple", category: "ASREngineFactory")
        }

        let apple = try AppleSpeechASREngine()
        return EngineBuild(engine: apple, fallbackReason: fallbackReason)
    }

    /// Build the engine used by translation: Paraformer for bilingual, falling
    /// back to Apple Speech locked to en-US.
    func makeTranslation() throws -> EngineBuild {
        if let dir = modelManager.modelPath(for: .paraformer),
           let paraformer = try? ParaformerStreamingEngine(modelDir: dir) {
            LogService.info("Translation engine: Paraformer", category: "ASREngineFactory")
            return EngineBuild(engine: paraformer, fallbackReason: nil)
        }
        LogService.info("Translation engine: Apple Speech en-US", category: "ASREngineFactory")
        let apple = try AppleSpeechASREngine(locale: "en-US")
        return EngineBuild(engine: apple, fallbackReason: nil)
    }

    /// Build the fallback engine used by the dictation pipeline when the
    /// primary engine fails mid-recording. Returns nil unless the user has
    /// already authorized Apple Speech.
    func makeFallback() -> (any ASREngine)? {
        let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType) ?? AppDefaults.Defaults.engineType
        if choice == "apple" { return nil }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return nil }
        return try? AppleSpeechASREngine()
    }
}
```

- [ ] **Step 1.4: Run factory tests — expect pass**

```bash
xcodebuild test \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/ASREngineFactoryTests 2>&1 | tail -20
```

Expected: all `ASREngineFactoryTests` pass. The full build will still fail (callers of `makeUserPreferred` haven't been updated) — that's expected and gets fixed in Task 3.

- [ ] **Step 1.5: Commit**

```bash
git add NemoNoise/Services/ASR/ASREngineFactory.swift NemoNoiseTests/ASREngineFactoryTests.swift
git commit -m "$(cat <<'EOF'
refactor(asr): purify ASREngineFactory — EngineBuild + Sendable protocol

Returns engine paired with optional fallbackReason instead of toasting
directly. Drops @MainActor so the factory can be called from background
threads during pipeline warm-up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: PipelineProvider — TDD

**Goal:** Implement the new service with a state-machine test driving its design.

**Files:**
- Create: `NemoNoiseTests/PipelineProviderTests.swift`
- Create: `NemoNoise/App/PipelineProvider.swift`

---

- [ ] **Step 2.1: Write the failing tests**

Create `NemoNoiseTests/PipelineProviderTests.swift`:

```swift
import XCTest
@testable import NemoNoise

@MainActor
final class PipelineProviderTests: XCTestCase {

    // MARK: - Stubs

    /// In-memory factory whose behavior is configured per test. `Sendable` so
    /// the detached bootstrap task can capture it.
    final class StubFactory: ASREngineFactoring, @unchecked Sendable {
        var primaryResult: Result<EngineBuild, Error> = .success(.init(engine: StubEngine(), fallbackReason: nil))
        var translationResult: Result<EngineBuild, Error> = .success(.init(engine: StubEngine(), fallbackReason: nil))
        var fallbackResult: (any ASREngine)? = nil

        func makePrimary() throws -> EngineBuild { try primaryResult.get() }
        func makeTranslation() throws -> EngineBuild { try translationResult.get() }
        func makeFallback() -> (any ASREngine)? { fallbackResult }
    }

    final class StubEngine: ASREngine, @unchecked Sendable {
        let isStreaming = true
        func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
            TranscriptionResult(text: "", isFinal: false, emotion: nil)
        }
        func finish() async throws -> TranscriptionResult { TranscriptionResult(text: "", isFinal: true, emotion: nil) }
        func reset() {}
    }

    // MARK: - Helpers

    private func makeProvider(factory: StubFactory = StubFactory())
        -> (PipelineProvider, RecordingController, TranslationController)
    {
        let mm = ModelManager()
        let mutex = RecordingMutex()
        let recording = RecordingController()
        let translation = TranslationController()
        let provider = PipelineProvider(
            factory: factory,
            modelManager: mm,
            mutex: mutex,
            recording: recording,
            translation: translation
        )
        return (provider, recording, translation)
    }

    /// Poll readiness until it leaves `.loading` or timeout.
    private func waitUntilReady(_ provider: PipelineProvider, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while provider.dictation == .loading || provider.translation == .loading {
            if Date() >= deadline { XCTFail("Provider did not leave .loading within \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Tests

    func testInitialStateIsLoading() {
        let (provider, _, _) = makeProvider()
        XCTAssertEqual(provider.dictation, .loading)
        XCTAssertEqual(provider.translation, .loading)
    }

    func testBootstrapTransitionsToReady() async throws {
        let (provider, _, _) = makeProvider()
        provider.bootstrap()
        try await waitUntilReady(provider)
        XCTAssertEqual(provider.dictation, .ready)
        XCTAssertEqual(provider.translation, .ready)
    }

    func testTranslationFailureLeavesDictationReady() async throws {
        let factory = StubFactory()
        struct Boom: Error {}
        factory.translationResult = .failure(Boom())
        let (provider, _, _) = makeProvider(factory: factory)
        provider.bootstrap()
        try await waitUntilReady(provider)
        XCTAssertEqual(provider.dictation, .ready)
        if case .failed = provider.translation { /* ok */ } else {
            XCTFail("translation should be .failed but is \(provider.translation)")
        }
    }

    func testDictationFailureSurfacesAsFailed() async throws {
        let factory = StubFactory()
        struct Boom: Error {}
        factory.primaryResult = .failure(Boom())
        let (provider, _, _) = makeProvider(factory: factory)
        provider.bootstrap()
        try await waitUntilReady(provider)
        if case .failed = provider.dictation { /* ok */ } else {
            XCTFail("dictation should be .failed but is \(provider.dictation)")
        }
    }

    func testRebuildDictationReachesReadyAgain() async throws {
        let (provider, _, _) = makeProvider()
        provider.bootstrap()
        try await waitUntilReady(provider)

        provider.rebuildDictation()
        XCTAssertEqual(provider.dictation, .loading)
        try await waitUntilReady(provider)
        XCTAssertEqual(provider.dictation, .ready)
    }
}
```

- [ ] **Step 2.2: Run tests — expect compile failure**

```bash
xcodebuild test \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/PipelineProviderTests 2>&1 | tail -30
```

Expected: compile errors referencing `PipelineProvider`, `bootstrap`, `rebuildDictation`, `Readiness`.

- [ ] **Step 2.3: Create `PipelineProvider.swift`**

Create `NemoNoise/App/PipelineProvider.swift`:

```swift
import SwiftUI

/// Owns engine + pipeline lifecycle for the entire app. Constructs ONNX
/// engines on a background thread (Task.detached) and hops to MainActor to
/// bind them to controllers. Lives in App/ because it is the *assembly* peer
/// to RecordingController and TranslationController — see
/// docs/superpowers/specs/2026-05-16-pipeline-provider-design.md.
@MainActor @Observable
final class PipelineProvider {

    enum Readiness: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var dictation: Readiness = .loading
    private(set) var translation: Readiness = .loading

    private let factory: any ASREngineFactoring
    private let modelManager: ModelManager
    private let mutex: RecordingMutex
    private weak var recordingController: RecordingController?
    private weak var translationController: TranslationController?

    /// Cached so engine swaps from Settings don't re-pay the punctuator load.
    private var cachedPunctuator: SherpaOfflinePunctuator?

    init(factory: any ASREngineFactoring,
         modelManager: ModelManager,
         mutex: RecordingMutex,
         recording: RecordingController,
         translation: TranslationController) {
        self.factory = factory
        self.modelManager = modelManager
        self.mutex = mutex
        self.recordingController = recording
        self.translationController = translation

        // Controllers stay ignorant of PipelineProvider. The rebuild request
        // arrives via an opaque closure that PipelineProvider installs here.
        recording.pipelineRebuildHandler = { [weak self] in self?.rebuildDictation() }
    }

    /// Called once from `NemoNoiseApp`. Loads engines on a background thread,
    /// then hops to MainActor to bind pipelines.
    func bootstrap() {
        let factory = self.factory
        let modelManager = self.modelManager
        Task.detached(priority: .userInitiated) { [weak self] in
            let punctuator = Self.makePunctuator(modelManager: modelManager)

            let primaryResult = Result<EngineBuild, Error> { try factory.makePrimary() }
            let fallback = factory.makeFallback()
            let translationResult = Result<EngineBuild, Error> { try factory.makeTranslation() }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cachedPunctuator = punctuator
                self.applyDictation(result: primaryResult, fallback: fallback, punctuator: punctuator)
                self.applyTranslation(result: translationResult, punctuator: punctuator)
                self.translationController?.startHotkeyMonitoring()
            }
        }
    }

    /// Rebuild dictation when the user changes engine choice in Settings.
    /// Reuses the cached punctuator and Apple Speech fallback.
    func rebuildDictation() {
        dictation = .loading
        let factory = self.factory
        let punctuator = self.cachedPunctuator
        Task.detached(priority: .userInitiated) { [weak self] in
            let primaryResult = Result<EngineBuild, Error> { try factory.makePrimary() }
            let fallback = factory.makeFallback()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyDictation(result: primaryResult, fallback: fallback, punctuator: punctuator)
            }
        }
    }

    // MARK: - Apply (MainActor)

    private func applyDictation(result: Result<EngineBuild, Error>,
                                fallback: (any ASREngine)?,
                                punctuator: SherpaOfflinePunctuator?) {
        guard let recordingController else { return }
        switch result {
        case .failure(let error):
            dictation = .failed(error.localizedDescription)
            ToastWindowController.show("Dictation engine unavailable: \(error.localizedDescription)",
                                       style: .error, duration: 5)
        case .success(let build):
            let postProcessors: [any PostProcessor] = punctuator.map {
                [PunctuationProcessor(punctuator: $0)]
            } ?? []

            let pipeline = TranscriptionPipeline(
                source: MicAudioSource(),
                engine: build.engine,
                postProcessors: postProcessors,
                sink: OverlayProgressSink(target: recordingController),
                fallback: fallback
            )
            recordingController.bind(pipeline: pipeline, mutex: mutex)
            dictation = .ready
            if let reason = build.fallbackReason {
                ToastWindowController.show(reason, style: .warning, duration: 5)
            }
        }
    }

    private func applyTranslation(result: Result<EngineBuild, Error>,
                                  punctuator: SherpaOfflinePunctuator?) {
        guard let translationController else { return }
        switch result {
        case .failure(let error):
            translation = .failed(error.localizedDescription)
            // Don't toast — translation is opt-in; surface in popover only.
            LogService.warn("Translation engine init failed: \(error.localizedDescription)",
                            category: "PipelineProvider")
        case .success(let build):
            let postProcessors: [any PostProcessor] = punctuator.map {
                [PunctuationProcessor(punctuator: $0)]
            } ?? []
            let pipeline = TranscriptionPipeline(
                source: SystemAudioSource(),
                engine: build.engine,
                postProcessors: postProcessors,
                sink: SubtitleOverlaySink(target: translationController),
                fallback: nil
            )
            translationController.bind(pipeline: pipeline, mutex: mutex)
            translation = .ready
        }
    }

    // MARK: - Punctuator

    private static func makePunctuator(modelManager: ModelManager) -> SherpaOfflinePunctuator? {
        guard let dir = modelManager.modelPath(for: .punctuation) else { return nil }
        let path = dir.appendingPathComponent("model.onnx").path
        guard let punctuator = SherpaOfflinePunctuator(modelPath: path) else {
            LogService.warn("Failed to load punctuation model at \(path)",
                            category: "PipelineProvider")
            return nil
        }
        LogService.info("Punctuation processor enabled", category: "PipelineProvider")
        return punctuator
    }
}
```

- [ ] **Step 2.4: Run PipelineProvider tests — expect pass**

```bash
xcodebuild test \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/PipelineProviderTests 2>&1 | tail -25
```

Expected: all 5 tests pass. The full project build may still fail because `NemoNoiseApp.swift` still references the old `factory.makeUserPreferred()` API and `Self.makePunctuator` — that gets fixed in Task 3.

Also remember to add `PipelineProvider.swift` to the Xcode project target (`NemoNoise`). If the file is created but not added to the target, the build will not see it. In Xcode: drag the file into the `App` group and ensure the `NemoNoise` target checkbox is ticked. Similarly add `PipelineProviderTests.swift` to the `NemoNoiseTests` target.

- [ ] **Step 2.5: Commit**

```bash
git add NemoNoise/App/PipelineProvider.swift NemoNoiseTests/PipelineProviderTests.swift NemoNoise.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(app): add PipelineProvider for off-main engine warm-up

@MainActor @Observable service that owns engine + pipeline lifecycle.
Constructs ONNX engines on Task.detached, then hops to MainActor to bind
pipelines to controllers. Dictation and translation readiness track
independently so one engine failing does not block the other.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire `PipelineProvider` in `NemoNoiseApp` — delete the popover `.task`

**Goal:** Replace the heavy popover-attached assembly with a single `PipelineProvider` constructed at app launch.

**Files:**
- Modify: `NemoNoise/App/NemoNoiseApp.swift`

---

- [ ] **Step 3.1: Rewrite `NemoNoiseApp.swift`**

Replace `NemoNoise/App/NemoNoiseApp.swift` body with:

```swift
import ApplicationServices
import Sparkle
import SwiftUI

@main
struct NemoNoiseApp: App {
    @State private var controller: RecordingController
    @State private var translationController: TranslationController
    @State private var pipelineProvider: PipelineProvider

    private let updaterDelegate = UpdaterFeedProvider()
    private let updaterController: SPUStandardUpdaterController
    private let mutex = RecordingMutex()

    init() {
        let updater = SPUStandardUpdaterController(startingUpdater: true,
                                                   updaterDelegate: updaterDelegate,
                                                   userDriverDelegate: nil)
        self.updaterController = updater
        _ = LogService.shared
        _ = CrashGuard.shared
        SentryService.initialize()

        // Build the assembly graph eagerly. Controllers, mutex, and
        // PipelineProvider are all cheap to construct — only engine init is
        // heavy, and PipelineProvider.bootstrap() pushes that to a background
        // thread.
        let recording = RecordingController()
        let translation = TranslationController()
        let factory = ASREngineFactory(modelManager: recording.modelManager)
        let provider = PipelineProvider(
            factory: factory,
            modelManager: recording.modelManager,
            mutex: mutex,
            recording: recording,
            translation: translation
        )
        _controller = State(initialValue: recording)
        _translationController = State(initialValue: translation)
        _pipelineProvider = State(initialValue: provider)

        // Kick off async engine load. Popover will see .loading briefly on
        // cold start, then .ready.
        provider.bootstrap()
    }

    var body: some Scene {
        MenuBarExtra {
            OnboardingGate {
                MenuBarPopoverView(updater: updaterController.updater)
                    .environment(controller)
                    .environment(translationController)
                    .environment(pipelineProvider)
            }
        } label: {
            MenuBarLabel()
                .environment(controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
                .environment(controller.modelManager)
                .environment(translationController)
        }
    }
}

private struct OnboardingGate<Content: View>: View {
    @AppStorage(AppDefaults.Keys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .onAppear {
                if !hasCompletedOnboarding {
                    OnboardingWindowController.show {
                        hasCompletedOnboarding = true
                    }
                }
            }
    }
}

final class UpdaterFeedProvider: NSObject, SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        "https://gaozimeng0425.github.io/NemoNoise/appcast.xml"
    }
}
```

**Note:** `@State` is declared without a default value so the single instance passed into `PipelineProvider` is the one SwiftUI tracks. Each `@State` property is then explicitly assigned via `_controller = State(initialValue:)` in `init()`.

- [ ] **Step 3.2: Build the whole project — expect success**

```bash
xcodebuild build \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' \
  -configuration Debug 2>&1 | tail -30
```

Expected: build succeeds. If `RecordingController` still has `pipelineRebuildHandler` field, the build passes (Task 2 already uses it from `PipelineProvider.init`).

- [ ] **Step 3.3: Run the full test suite**

```bash
xcodebuild test \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: all tests pass. No regression in existing suites (`TranscriptionPipelineTests`, `RecordingMutexTests`, etc.).

- [ ] **Step 3.4: Commit**

```bash
git add NemoNoise/App/NemoNoiseApp.swift
git commit -m "$(cat <<'EOF'
refactor(app): wire PipelineProvider; remove popover-attached assembly

The popover's .task used to construct engines on MainActor every click,
stalling the popover ~1s. NemoNoiseApp now constructs PipelineProvider
at launch and bootstraps it once; the popover view only reads readiness.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `RecordingController` — warming-up toast on hotkey

**Goal:** Replace silent fail when user presses hotkey before engines are ready with a visible toast.

**Files:**
- Modify: `NemoNoise/App/RecordingController.swift`

---

- [ ] **Step 4.1: Locate `startRecording()`**

Find the `startRecording()` method body in `NemoNoise/App/RecordingController.swift`. It begins with checks for `pipeline` and `mutex`. Right now the guard against `pipeline == nil` returns silently.

- [ ] **Step 4.2: Add warming-up branch**

Replace the leading guard in `startRecording()` with this pattern. If the existing code looks like:

```swift
private func startRecording() {
    guard recordingState == .ready, let pipeline, let mutex else { return }
    ...
}
```

…change it to:

```swift
private func startRecording() {
    guard recordingState == .ready else { return }
    guard let pipeline, let mutex else {
        if pipeline == nil {
            ToastWindowController.show("Engines warming up…", style: .info, duration: 1.5)
        }
        return
    }
    ...
}
```

(If the structure of the actual method differs — e.g. multiple separate guards — apply the same intent: when `pipeline` is `nil`, show the toast before returning.)

- [ ] **Step 4.3: Build + run full test suite**

```bash
xcodebuild test \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -15
```

Expected: all tests pass. No new test added — the toast is a side-effect best verified by manual QA.

- [ ] **Step 4.4: Commit**

```bash
git add NemoNoise/App/RecordingController.swift
git commit -m "$(cat <<'EOF'
feat(recording): toast when hotkey hit before engines warm

Pre-warm window between launch and PipelineProvider.bootstrap completion
used to silently swallow hotkey presses. Now surfaces a toast so the
user knows to retry in a moment.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Note on field rename:** the spec mentions renaming `pipelineRebuildHandler` → `onRebuildRequested`. This is cosmetic. Skip the rename — it adds churn without changing behavior. The closure is now set by `PipelineProvider.init` (one named owner), which is the real decoupling win.

---

## Task 5: `MenubarView` — Preparing / Failed UI

**Goal:** Show readiness state to the user so they understand the brief warming window and any failed translation.

**Files:**
- Modify: `NemoNoise/UI/Menubar/MenubarView.swift`

---

- [ ] **Step 5.1: Add environment dependency**

At the top of `MenuBarPopoverView`, add:

```swift
@Environment(PipelineProvider.self) private var pipelineProvider
```

next to the existing `@Environment(RecordingController.self)` and `@Environment(TranslationController.self)` declarations.

- [ ] **Step 5.2: Insert readiness UI**

Inside `MenuBarPopoverView.body`, find the existing status row (the `Circle` + `statusText` HStack near line 21-28). Immediately below the existing `engineFallbackWarning` block (currently lines 30-34), add:

```swift
if pipelineProvider.dictation == .loading {
    HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Preparing engines…")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
if case .failed(let msg) = pipelineProvider.dictation {
    Text("Dictation: \(msg)")
        .font(.caption2)
        .foregroundStyle(.red)
}
if case .failed(let msg) = pipelineProvider.translation {
    Text("Translation: \(msg)")
        .font(.caption2)
        .foregroundStyle(.red)
}
```

- [ ] **Step 5.3: Build**

```bash
xcodebuild build \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' \
  -configuration Debug 2>&1 | tail -15
```

Expected: success.

- [ ] **Step 5.4: Commit**

```bash
git add NemoNoise/UI/Menubar/MenubarView.swift
git commit -m "$(cat <<'EOF'
feat(menubar): show engine readiness in popover

Brief 'Preparing engines…' row during cold-start warm-up; red status
line for any failed engine. Replaces invisible loading state with
explicit feedback.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Manual QA — verify the performance fix and behavior

**Goal:** Confirm the user-visible problem is gone and no regressions.

**This task is verification, not code. No commit at the end unless something needed fixing.**

---

- [ ] **Step 6.1: Build a release-ish run**

```bash
xcodebuild build \
  -project NemoNoise.xcodeproj \
  -scheme NemoNoise \
  -destination 'platform=macOS' \
  -configuration Debug
```

Launch the resulting app (or run from Xcode).

- [ ] **Step 6.2: Measure popover open latency**

Click the menubar icon. Popover should appear **immediately** (no ~1s stall). On cold launch, you should see "Preparing engines…" for a fraction of a second, then it should disappear and the normal status row should remain.

If the popover still stalls: check Console for `"Model loaded, init duration: …"` — if it appears synchronously with the click, the Task.detached isn't actually off-main; revisit `PipelineProvider.bootstrap`.

- [ ] **Step 6.3: Console log verification**

In Console.app, filter to subsystem `NemoNoise` (or your bundle id). On launch you should see exactly **one** instance each of:

- `Punctuation processor enabled` (from `PipelineProvider`)
- `Factory creating engine: <choice>`
- `Model loaded, init duration: …` (per engine — dictation and translation)
- `Translation engine: …`

Subsequent menubar clicks should produce **no new model-load logs**. If you see repeated loads on each click, `PipelineProvider` is being re-instantiated — investigate `@State` setup in `NemoNoiseApp.init()`.

- [ ] **Step 6.4: Hotkey path**

- Wait until "Preparing engines…" disappears.
- Press the configured dictation hotkey, say a few words, release.
- Expected: transcription works as before, final text goes to clipboard / injection as configured.

- [ ] **Step 6.5: Hotkey-while-warming**

- Quit the app (Cmd+Q via menubar).
- Relaunch.
- **Immediately** (before "Preparing engines…" disappears) press the hotkey.
- Expected: toast appears reading "Engines warming up…". No crash, no silent loss.

- [ ] **Step 6.6: Translation toggle**

- Open menubar popover, click "Start Translation".
- Expected: capture starts, subtitle overlay shows. Click "Stop Translation".
- If translation row showed `.failed` in popover, translation should *not* be startable — confirm the button still does something reasonable (toast or no-op).

- [ ] **Step 6.7: Settings rebuild path**

- Open Settings, change the engine type (e.g. Apple → Paraformer, if downloaded).
- Expected: popover briefly returns to "Preparing engines…" then "Ready"; Console shows a single new `Model loaded, init duration: …` line; no second punctuator load (cached).

- [ ] **Step 6.8: Verify nothing in the task list is left open**

```bash
git log --oneline -8
```

Expected: 5 commits from Tasks 1-5, in order. If any task uncovered an issue that needed an extra fix, it should already be committed.

---

## Plan complete

After Task 6, the menubar popover responds instantly, pipeline assembly lives in one clearly-named object, factory has no UI side effects, and tests cover the state machine.
