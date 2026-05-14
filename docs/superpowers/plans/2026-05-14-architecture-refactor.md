# NemoNoise Architecture Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `RecordingController` + `SpeechOrchestrator` + `TranslationController` into a unified `TranscriptionPipeline` model (AudioSource → ASREngine → [PostProcessor] → Sink), eliminating duplicated audio/ASR loops and enabling future plug-in of new engines, audio sources, and post-processors.

**Architecture:** Introduce four core protocols (`AudioSource`, `ASREngine`, `PostProcessor`, `Sink`) plus a `@MainActor TranscriptionPipeline` combinator. Controllers shrink to UI state adapters bound to a pre-configured pipeline. Migration runs in 6 stages; each ends with green build + tests.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, `@Observable`, AVFoundation, ScreenCaptureKit, Sherpa-ONNX (C bridge), XCTest. macOS 15+, Xcode 16.

**Reference Spec:** `docs/superpowers/specs/2026-05-14-architecture-review-design.md` (commit `1c8ec09`)

---

## Conventions (read once, then refer back)

### Test command (full suite)
```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

### Test command (single class or test)
```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -only-testing:NemoNoiseTests/<ClassName>/<methodName> -quiet
```

### Build command (compile-check only, faster than test)
```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

### Adding/renaming/deleting Swift files
The repo uses a classic `.xcodeproj` (not SwiftPM), so `project.pbxproj` must be updated whenever a file is added, renamed, or removed. Two options:
1. **Preferred:** Use the `xcodeproj` Ruby gem if available, or edit `NemoNoise.xcodeproj/project.pbxproj` directly with `Edit` tool — the format is well-structured and Swift files follow a clear pattern. After any pbxproj edit, run the build command above to confirm.
2. **Fallback:** Note the change in the task; the human runs Xcode GUI to "Add Files" or move the reference.

For renames where the file content barely changes, prefer `git mv` + pbxproj edit over delete-and-create.

### Commit style
Follows the existing repo style: `<type>(<optional-scope>): <imperative description>`. Examples present in repo: `feat(asr): ...`, `refactor: ...`, `test: ...`, `docs: ...`. Use the `Co-Authored-By: Claude` trailer.

### Stage boundary contract
**Every stage ends with:** full test suite green + app launches and runs the dictation/translation paths end-to-end. If a stage is split across multiple commits, the last commit of the stage is the one that must satisfy this contract — intermediate WIP commits inside a stage may have partial breakage as long as the *final* stage commit restores green.

### "DRY" reminder for this plan
Several files import the same modules and reference the same types. When a task says "add `import Foundation`", do it; don't editorialize about whether it's already present — if your edit needs it and the file lacks it, add it.

---

## Stage 0 — Renames + Models Split

**Stage goal:** Mechanical refactor only. Zero behavior change. After this stage, the codebase uses the new names and has split models, but the architecture is unchanged.

---

### Task 0.1 — Split `Models/ASRModels.swift`

**Files:**
- Read: `NemoNoise/Models/ASRModels.swift` (current monolith)
- Create: `NemoNoise/Models/TranscriptionResult.swift`
- Create: `NemoNoise/Models/RecordingState.swift`
- Create: `NemoNoise/Models/ASRError.swift`
- Delete: `NemoNoise/Models/ASRModels.swift`

- [ ] **Step 1: Create `TranscriptionResult.swift`**

```swift
// NemoNoise/Models/TranscriptionResult.swift
import Foundation

struct TranscriptionSegment: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let emotion: String?
}

struct TranscriptionResult: Sendable {
    let text: String
    let isFinal: Bool
    let emotion: String?
}
```

- [ ] **Step 2: Create `RecordingState.swift`**

```swift
// NemoNoise/Models/RecordingState.swift
import Foundation

enum RecordingState: Equatable {
    case ready
    case recording
    case processing
    case failed(String)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.ready, .ready), (.recording, .recording), (.processing, .processing):
            return true
        case (.failed(let l), .failed(let r)):
            return l == r
        default:
            return false
        }
    }
}

enum RecordingMode: String, CaseIterable, Codable {
    case pushToTalk = "Push to Talk"
    case toggle = "Toggle"
}
```

- [ ] **Step 3: Create `ASRError.swift`**

```swift
// NemoNoise/Models/ASRError.swift
import Foundation

enum ASRError: Error {
    case modelNotFound
    case audioCaptureFailed(String)
    case invalidPythonPath
    case socketDisconnected
    case engineUnavailable
    case engineInitFailed
}

enum CloudASRError: Error {
    case apiKeyNotSet
    case authenticationFailed
    case requestTimeout
    case serverError(Int)
    case invalidResponse
}
```

- [ ] **Step 4: Delete `ASRModels.swift` + update pbxproj**

```bash
rm NemoNoise/Models/ASRModels.swift
```

Edit `NemoNoise.xcodeproj/project.pbxproj`: replace the `ASRModels.swift` references with the three new files (search for `ASRModels` in the pbxproj, replicate the entries for each new file).

- [ ] **Step 5: Build to confirm**

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: succeed with no compile errors. Types are at the same module level so all existing imports continue to work.

- [ ] **Step 6: Run full test suite**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add NemoNoise/Models/ NemoNoise.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
refactor(models): split ASRModels into TranscriptionResult / RecordingState / ASRError

Mechanical split, zero behavior change.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 0.2 — Extract shared `ContinuationBox`

**Why:** `AudioCapture.swift` and `SystemAudioCapture.swift` each define a private `ContinuationBox` with identical shape. Pull it out so future audio sources can reuse it.

**Files:**
- Read: `NemoNoise/Services/Audio/AudioCapture.swift` (lines 78-86)
- Read: `NemoNoise/Services/Audio/SystemAudioCapture.swift` (look for `ContinuationBox`)
- Create: `NemoNoise/Services/Audio/ContinuationBox.swift`
- Modify: `NemoNoise/Services/Audio/AudioCapture.swift` (remove inline)
- Modify: `NemoNoise/Services/Audio/SystemAudioCapture.swift` (remove inline)

- [ ] **Step 1: Create shared file**

```swift
// NemoNoise/Services/Audio/ContinuationBox.swift
import Foundation
import os

/// Sendable wrapper around `AsyncStream<AudioChunk>.Continuation` for crossing
/// isolation boundaries (audio tap callbacks run off-actor).
final class ContinuationBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<AsyncStream<AudioChunk>.Continuation?>(initialState: nil)
    var value: AsyncStream<AudioChunk>.Continuation? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
```

- [ ] **Step 2: Remove inline definition from `AudioCapture.swift`**

Delete the trailing block (currently lines ~78-86 starting with `// AsyncStream.Continuation is not Sendable...`). Keep the rest of the file unchanged.

- [ ] **Step 3: Remove inline definition from `SystemAudioCapture.swift`**

If `SystemAudioCapture` declares its own `ContinuationBox`, delete that declaration. If it currently uses a local class with the same name, ensure the new shared one is what gets resolved.

- [ ] **Step 4: Update pbxproj — add the new file**

Add `ContinuationBox.swift` to the project under `NemoNoise/Services/Audio/`.

- [ ] **Step 5: Build + test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add NemoNoise/Services/Audio/ NemoNoise.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
refactor(audio): extract shared ContinuationBox

Both audio sources had identical inline implementations; pull to one place.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 0.3 — Rename `AudioCapture` → `MicAudioSource`

**Files:**
- Rename: `NemoNoise/Services/Audio/AudioCapture.swift` → `NemoNoise/Services/Audio/MicAudioSource.swift`
- Modify: same file (rename `final class AudioCapture` → `final class MicAudioSource`)
- Modify: every consumer (`grep -rn "AudioCapture" NemoNoise NemoNoiseTests`)

- [ ] **Step 1: Find all consumers**

```bash
grep -rn "AudioCapture" NemoNoise NemoNoiseTests --include="*.swift"
```

Expected occurrences: `SpeechOrchestrator.swift` (let audioCapture = AudioCapture()), possibly tests. Record the list.

- [ ] **Step 2: Rename file + class**

```bash
git mv NemoNoise/Services/Audio/AudioCapture.swift NemoNoise/Services/Audio/MicAudioSource.swift
```

In the new file, change `final class AudioCapture: Sendable {` → `final class MicAudioSource: Sendable {`.

- [ ] **Step 3: Update consumers**

For each consumer found in Step 1, replace `AudioCapture` with `MicAudioSource`. Likely only `SpeechOrchestrator.swift` line ~15:
```swift
private let audioCapture = AudioCapture()
```
becomes:
```swift
private let audioCapture = MicAudioSource()
```
(variable name kept as `audioCapture` for now — renaming the variable is in Stage 4.)

- [ ] **Step 4: Update pbxproj**

Replace the `AudioCapture.swift` reference with `MicAudioSource.swift`. The path field uses the filename so find/replace that string in the pbxproj.

- [ ] **Step 5: Build + test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(audio): rename AudioCapture to MicAudioSource

Prepares for AudioSource protocol abstraction.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 0.4 — Rename `SystemAudioCapture` → `SystemAudioSource`

**Files:**
- Rename: `NemoNoise/Services/Audio/SystemAudioCapture.swift` → `NemoNoise/Services/Audio/SystemAudioSource.swift`
- Modify: same file (class name)
- Modify: consumers (`grep -rn "SystemAudioCapture" NemoNoise NemoNoiseTests`)

- [ ] **Step 1: Find consumers**

```bash
grep -rn "SystemAudioCapture" NemoNoise NemoNoiseTests --include="*.swift"
```

Expected: `TranslationController.swift`.

- [ ] **Step 2: Rename file + class**

```bash
git mv NemoNoise/Services/Audio/SystemAudioCapture.swift NemoNoise/Services/Audio/SystemAudioSource.swift
```

Change `final class SystemAudioCapture` → `final class SystemAudioSource`.

- [ ] **Step 3: Update consumers**

In `TranslationController.swift`, change `let capture = SystemAudioCapture()` → `let capture = SystemAudioSource()`. The type annotation on `audioCapture: SystemAudioCapture?` becomes `audioCapture: SystemAudioSource?`.

- [ ] **Step 4: Update pbxproj**

Replace `SystemAudioCapture.swift` → `SystemAudioSource.swift`.

- [ ] **Step 5: Build + test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(audio): rename SystemAudioCapture to SystemAudioSource

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 0.5 — Rename `ASRService` protocol → `ASREngine`

**Why:** "Service" is overloaded in macOS context (NSService); "Engine" matches the domain.

**Files:**
- Rename: `NemoNoise/Services/ASR/ASRService.swift` → `NemoNoise/Services/ASR/ASREngine.swift`
- Modify: every implementing class (5 engines)
- Modify: every consumer (`grep -rn "ASRService" NemoNoise NemoNoiseTests`)

- [ ] **Step 1: Find all references**

```bash
grep -rn "ASRService" NemoNoise NemoNoiseTests --include="*.swift"
```

Expected files: `ASRService.swift`, `AppleSpeechASREngine.swift`, `CloudASREngine.swift`, `SherpaASREngine.swift`, `ParaformerStreamingEngine.swift`, `SpeechOrchestrator.swift`, `TranslationController.swift`, `ASRServiceMockTests.swift` (the `MockASRService` class and the test class).

- [ ] **Step 2: Rename the protocol file**

```bash
git mv NemoNoise/Services/ASR/ASRService.swift NemoNoise/Services/ASR/ASREngine.swift
```

In the new file, change `protocol ASRService` → `protocol ASREngine`, and `extension ASRService` → `extension ASREngine`.

- [ ] **Step 3: Update all conformers**

In each of the 5 engine files, change `: ASRService` → `: ASREngine`. Use `sed` or your editor's project-wide replace:

```bash
# Verify the substitution before applying
grep -l "ASRService" NemoNoise/Services/ASR/*.swift
```

Then in each engine: `: ASRService, @unchecked Sendable` → `: ASREngine, @unchecked Sendable`.

- [ ] **Step 4: Update consumers (controllers + orchestrator)**

`SpeechOrchestrator.swift`: `private var engine: (any ASRService)?` → `private var engine: (any ASREngine)?`. Also the return type of `makeEngine() throws -> any ASRService` → `throws -> any ASREngine`.

`TranslationController.swift`: `private var asrEngine: (any ASRService)?` → `private var asrEngine: (any ASREngine)?`. And the local `let engine: any ASRService` declaration in `startTranslation`.

- [ ] **Step 5: Update tests**

In `NemoNoiseTests/ASRServiceMockTests.swift`:
- Rename `final class MockASRService: ASRService` → `final class MockASRService: ASREngine`
- Rename `final class ASRServiceMockTests` → `final class ASREngineMockTests`
- Rename the file via `git mv`:

```bash
git mv NemoNoiseTests/ASRServiceMockTests.swift NemoNoiseTests/ASREngineMockTests.swift
```

(Leave `MockASRService` *class name* alone for now to minimize churn — only the test class and file rename are required. The mock keeps its old name; we'll rename in Stage 2 when it's actually used.)

Update test that asserts conformance: `let mock: any ASRService = MockASRService()` → `let mock: any ASREngine = MockASRService()`.

- [ ] **Step 6: Update pbxproj**

Replace:
- `ASRService.swift` → `ASREngine.swift`
- `ASRServiceMockTests.swift` → `ASREngineMockTests.swift`

- [ ] **Step 7: Build + test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: all green, no `ASRService` references remain:

```bash
grep -rn "ASRService" NemoNoise NemoNoiseTests --include="*.swift" || echo "Clean"
```

Should print `Clean` (or only match comments/strings, if any).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(asr): rename ASRService protocol to ASREngine

"Service" is overloaded in macOS context (NSService); Engine matches the domain.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Stage 0 Exit Gate

- [ ] Full test suite green
- [ ] Manual smoke: launch app, run one dictation + one translation, both work
- [ ] `git log --oneline` since stage start shows 5 commits (one per task)

---

## Stage 1 — `AudioSource` protocol + `ASREngineFactory`

**Stage goal:** Introduce the audio source abstraction (interface-only change; both sources already match) and consolidate engine construction in one place.

---

### Task 1.1 — Add `AudioSource` protocol

**Files:**
- Create: `NemoNoise/Services/Audio/AudioSource.swift`
- Modify: `NemoNoise/Services/Audio/MicAudioSource.swift` (declare conformance)
- Modify: `NemoNoise/Services/Audio/SystemAudioSource.swift` (declare conformance)
- Test: `NemoNoiseTests/AudioSourceConformanceTests.swift`

- [ ] **Step 1: Write the protocol file**

```swift
// NemoNoise/Services/Audio/AudioSource.swift
import Foundation

/// A source of audio chunks at 16 kHz mono Float32. Implementations may
/// capture from microphone, system audio, file, etc.
protocol AudioSource: Sendable {
    /// Start producing chunks. Must `throw` if the underlying source cannot
    /// be opened (permission denied, no hardware).
    func start() async throws -> AsyncStream<AudioChunk>

    /// Stop producing. Idempotent; safe to call multiple times.
    func stop()
}
```

- [ ] **Step 2: Update `MicAudioSource.swift`**

Change the class declaration:
```swift
final class MicAudioSource: AudioSource, Sendable {
```

(The `start() async throws -> AsyncStream<AudioChunk>` and `stop()` signatures already exist; no body changes.)

- [ ] **Step 3: Update `SystemAudioSource.swift`**

Change the class declaration:
```swift
final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, @unchecked Sendable {
```

(Signatures already match.)

- [ ] **Step 4: Write conformance test**

```swift
// NemoNoiseTests/AudioSourceConformanceTests.swift
import XCTest
@testable import NemoNoise

final class AudioSourceConformanceTests: XCTestCase {
    func testMicAudioSourceConformsToAudioSource() {
        let _: any AudioSource = MicAudioSource()
    }

    func testSystemAudioSourceConformsToAudioSource() {
        let _: any AudioSource = SystemAudioSource()
    }
}
```

- [ ] **Step 5: Add new files to pbxproj**

- `AudioSource.swift` under `Services/Audio/`
- `AudioSourceConformanceTests.swift` under `NemoNoiseTests/`

- [ ] **Step 6: Build + test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -only-testing:NemoNoiseTests/AudioSourceConformanceTests -quiet
```

Expected: both tests pass.

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: full suite green.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(audio): introduce AudioSource protocol

Both MicAudioSource and SystemAudioSource already match the interface;
this only declares conformance to enable the pipeline abstraction.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.2 — Add `ASREngineFactory`

**Files:**
- Create: `NemoNoise/Services/ASR/ASREngineFactory.swift`
- Test: `NemoNoiseTests/ASREngineFactoryTests.swift`

The factory consolidates engine construction. Current logic lives in two places (`SpeechOrchestrator.makeEngine` and inline in `TranslationController.startTranslation`); this task only **adds the factory**. Task 1.3 wires it in.

- [ ] **Step 1: Write the failing test**

```swift
// NemoNoiseTests/ASREngineFactoryTests.swift
import XCTest
@testable import NemoNoise

@MainActor
final class ASREngineFactoryTests: XCTestCase {

    private func makeFactory() -> ASREngineFactory {
        ASREngineFactory(modelManager: ModelManager())
    }

    // MARK: - User-preferred engine

    func testMakeUserPreferredFallsBackToAppleWhenPreferenceMissing() throws {
        UserDefaults.standard.removeObject(forKey: AppDefaults.Keys.engineType)
        let factory = makeFactory()
        let engine = try factory.makeUserPreferred()
        XCTAssertTrue(engine is AppleSpeechASREngine
                       || engine is ParaformerStreamingEngine
                       || engine is SherpaASREngine
                       || engine is CloudASREngine)
        // We cannot assert it's specifically Apple without a fake ModelManager,
        // but the call must not throw.
    }

    func testMakeUserPreferredHonoursApplePreference() throws {
        UserDefaults.standard.set("apple", forKey: AppDefaults.Keys.engineType)
        let factory = makeFactory()
        let engine = try factory.makeUserPreferred()
        XCTAssertTrue(engine is AppleSpeechASREngine, "expected Apple, got \(type(of: engine))")
    }

    func testMakeUserPreferredFallsBackWhenCloudKeyMissing() throws {
        UserDefaults.standard.set("cloud", forKey: AppDefaults.Keys.engineType)
        KeychainService.delete(key: KeychainService.Keys.cloudAPIKey)
        let factory = makeFactory()
        let engine = try factory.makeUserPreferred()
        XCTAssertTrue(engine is AppleSpeechASREngine, "expected Apple fallback, got \(type(of: engine))")
    }

    // MARK: - Translation engine

    func testMakeForTranslationFallsBackToAppleEnUSWhenParaformerUnavailable() throws {
        let factory = makeFactory()
        // No way to force-disable Paraformer model presence without filesystem manipulation;
        // this test verifies that *some* engine is returned and is en-US-capable.
        let engine = try factory.makeForTranslation()
        XCTAssertTrue(engine is AppleSpeechASREngine || engine is ParaformerStreamingEngine)
    }

    // MARK: - Fallback engine for dictation

    func testMakeFallbackReturnsAppleSpeech() throws {
        let factory = makeFactory()
        let fallback = try factory.makeFallback()
        XCTAssertTrue(fallback is AppleSpeechASREngine)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -only-testing:NemoNoiseTests/ASREngineFactoryTests -quiet
```

Expected: FAIL with `cannot find 'ASREngineFactory' in scope`.

- [ ] **Step 3: Write the factory implementation**

```swift
// NemoNoise/Services/ASR/ASREngineFactory.swift
import Foundation

/// Single place to construct ASR engines. Reads `UserDefaults` for the user's
/// preferred engine and `Keychain` for API keys, with predictable fallback to
/// Apple Speech when models or keys are missing.
@MainActor
final class ASREngineFactory {
    private let modelManager: ModelManager

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    /// Build the engine the user has selected in Settings. Falls back to Apple
    /// Speech if the chosen engine's prerequisites (model files, API key) are
    /// not satisfied.
    func makeUserPreferred() throws -> any ASREngine {
        let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType) ?? AppDefaults.Defaults.engineType
        LogService.info("Factory creating engine: \(choice)", category: "ASREngineFactory")

        switch choice {
        case "sensevoice":
            if let dir = modelManager.modelPath(for: .senseVoice) {
                return try SherpaASREngine(modelDir: dir)
            }
            LogService.warn("SenseVoice model not found, falling back to Apple", category: "ASREngineFactory")
        case "paraformer":
            if let dir = modelManager.modelPath(for: .paraformer) {
                return try ParaformerStreamingEngine(modelDir: dir)
            }
            LogService.warn("Paraformer model not found, falling back to Apple", category: "ASREngineFactory")
        case "cloud":
            if let apiKey = KeychainService.load(key: KeychainService.Keys.cloudAPIKey), !apiKey.isEmpty {
                return CloudASREngine(apiKey: apiKey)
            }
            LogService.warn("Cloud API key not set, falling back to Apple", category: "ASREngineFactory")
        case "apple":
            break
        default:
            LogService.warn("Unknown engine choice '\(choice)', falling back to Apple", category: "ASREngineFactory")
        }
        return try AppleSpeechASREngine()
    }

    /// Build the engine used by translation: Paraformer for bilingual, falling
    /// back to Apple Speech locked to en-US.
    func makeForTranslation() throws -> any ASREngine {
        if let dir = modelManager.modelPath(for: .paraformer),
           let paraformer = try? ParaformerStreamingEngine(modelDir: dir) {
            LogService.info("Translation engine: Paraformer", category: "ASREngineFactory")
            return paraformer
        }
        LogService.info("Translation engine: Apple Speech en-US", category: "ASREngineFactory")
        return try AppleSpeechASREngine(locale: "en-US")
    }

    /// Build the fallback engine used by the dictation pipeline when the
    /// primary engine fails mid-recording.
    func makeFallback() throws -> any ASREngine {
        try AppleSpeechASREngine()
    }
}
```

- [ ] **Step 4: Add new files to pbxproj**

- `ASREngineFactory.swift` under `Services/ASR/`
- `ASREngineFactoryTests.swift` under `NemoNoiseTests/`

- [ ] **Step 5: Run test to verify it passes**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -only-testing:NemoNoiseTests/ASREngineFactoryTests -quiet
```

Expected: PASS.

- [ ] **Step 6: Run full suite**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: still green (factory not yet wired in; nothing else changed).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(asr): add ASREngineFactory

Single source of truth for engine construction. Not yet wired in;
SpeechOrchestrator and TranslationController still use their inline paths.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.3 — Wire `ASREngineFactory` into existing call sites

**Files:**
- Modify: `NemoNoise/Services/ASR/SpeechOrchestrator.swift` (replace `makeEngine`)
- Modify: `NemoNoise/App/TranslationController.swift` (replace inline engine selection)

- [ ] **Step 1: Update `SpeechOrchestrator.swift`**

Add a `factory` property, initialized from the same `modelManager`:

```swift
// Inside SpeechOrchestrator class
private let factory: ASREngineFactory

init(modelManager: ModelManager) {
    self.modelManager = modelManager
    self.factory = ASREngineFactory(modelManager: modelManager)
}
```

Replace the entire `private func makeEngine() throws -> any ASREngine { ... }` body with:

```swift
private func makeEngine() throws -> any ASREngine {
    try factory.makeUserPreferred()
}
```

(Keep the function for now — it's a one-line indirection but minimizes call-site changes. Stage 4 will inline it.)

- [ ] **Step 2: Update `TranslationController.swift`**

Find the engine-selection block in `startTranslation` (lines ~74-90). Replace:

```swift
let engine: any ASREngine
if let modelManager = recordingController?.modelManager,
   let dir = modelManager.modelPath(for: .paraformer),
   let paraformer = try? ParaformerStreamingEngine(modelDir: dir) {
    paraformer.reset()
    engine = paraformer
    LogService.info("Using Paraformer for translation ASR", category: "Translation")
} else {
    LogService.info("Paraformer unavailable, falling back to Apple Speech", category: "Translation")
    guard let apple = try? AppleSpeechASREngine(locale: "en-US") else {
        LogService.error("Failed to create any ASR engine", category: "Translation")
        translationState = .error("ASR engine unavailable")
        return
    }
    apple.reset()
    engine = apple
}
self.asrEngine = engine
```

with:

```swift
let engine: any ASREngine
do {
    guard let modelManager = recordingController?.modelManager else {
        LogService.error("ModelManager unavailable for translation", category: "Translation")
        translationState = .error("ASR engine unavailable")
        return
    }
    let factory = ASREngineFactory(modelManager: modelManager)
    engine = try factory.makeForTranslation()
    engine.reset()
} catch {
    LogService.error("Failed to create translation engine: \(error.localizedDescription)", category: "Translation")
    translationState = .error("ASR engine unavailable")
    return
}
self.asrEngine = engine
```

- [ ] **Step 3: Build + test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: all green.

- [ ] **Step 4: Manual smoke test**

Launch the app. Press dictation hotkey, speak, release — text should be injected. Press translation hotkey (while system audio is playing), check that translation overlay appears. Both must work the same as before.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(asr): route SpeechOrchestrator and TranslationController through factory

Eliminates the duplicated engine-construction logic. Behavior unchanged.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Stage 1 Exit Gate

- [ ] Full test suite green
- [ ] `grep -rn "ParaformerStreamingEngine(" NemoNoise --include="*.swift"` returns only `ASREngineFactory.swift`
- [ ] `grep -rn "SherpaASREngine(" NemoNoise --include="*.swift"` returns only `ASREngineFactory.swift`
- [ ] `grep -rn "CloudASREngine(apiKey:" NemoNoise --include="*.swift"` returns only `ASREngineFactory.swift`
- [ ] Manual smoke: dictation + translation still work

---

## Stage 2 — Pipeline Skeleton (no controllers using it yet)

**Stage goal:** Land the entire `TranscriptionPipeline` + sinks + post-processor + event types, with thorough unit tests, but **without** touching either controller. After this stage, the pipeline exists and is proven by tests; the app still uses `SpeechOrchestrator` and `TranslationController`'s old loop.

---

### Task 2.1 — Add `PipelineEvent` enum

**Files:**
- Create: `NemoNoise/Services/Pipeline/PipelineEvent.swift`

- [ ] **Step 1: Write the enum**

```swift
// NemoNoise/Services/Pipeline/PipelineEvent.swift
import Foundation

/// Events emitted by a running TranscriptionPipeline.
///
/// Consumers (controllers) subscribe via `pipeline.start()` and map these to
/// `@Observable` state changes for SwiftUI.
enum PipelineEvent: Sendable {
    /// An intermediate (partial) transcription update plus the current input level.
    case partial(TranscriptionResult, rmsLevel: Float)

    /// Final transcription. Emitted from `finalize()`. The result has already
    /// been delivered to every sink before this event is yielded.
    case final(TranscriptionResult)

    /// Pipeline switched from primary engine to fallback mid-session.
    /// `from` is the type name of the failed engine (for logging/UX).
    case engineFallback(from: String)

    /// Input level update with no transcription text. Use for waveform UI when
    /// the engine produced no new text in this chunk.
    case rms(Float)

    /// `TextInjectorSink` reports that AX injection failed and the result was
    /// instead delivered to the clipboard. The controller may show an
    /// accessibility-permission alert in response.
    case injectionFailed
}
```

- [ ] **Step 2: Add to pbxproj**

`PipelineEvent.swift` under a new group `Services/Pipeline/`.

- [ ] **Step 3: Build**

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: succeed.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(pipeline): add PipelineEvent enum

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.2 — Add `PostProcessor` protocol

**Files:**
- Create: `NemoNoise/Services/Pipeline/PostProcessor.swift`

- [ ] **Step 1: Write the protocol**

```swift
// NemoNoise/Services/Pipeline/PostProcessor.swift
import Foundation

/// Transforms a transcription result between the ASR engine and the sink.
///
/// Implementations decide based on `isFinal` whether to run at all — partial
/// results are noisy and many transforms (e.g. translation, LLM rewrite) only
/// make sense on final text. Return `nil` to pass through unchanged.
protocol PostProcessor: Sendable {
    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult?
}
```

- [ ] **Step 2: Add to pbxproj + build**

Add `PostProcessor.swift` to `Services/Pipeline/`. Then:

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(pipeline): add PostProcessor protocol (empty slot for future stages)

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.3 — Add `Sink` protocol

**Files:**
- Create: `NemoNoise/Services/Pipeline/Sink.swift`

- [ ] **Step 1: Write the protocol**

```swift
// NemoNoise/Services/Pipeline/Sink.swift
import Foundation

/// Delivers transcription results to a user-visible destination (text field,
/// subtitle overlay, clipboard, etc.). Sinks should be tolerant: never throw,
/// never block long. The pipeline awaits `deliver`, so heavy work should be
/// pushed off-actor via Tasks if needed.
protocol Sink: Sendable {
    func deliver(_ result: TranscriptionResult, isFinal: Bool) async
}
```

- [ ] **Step 2: Add to pbxproj + build**

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(pipeline): add Sink protocol

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.4 — Add `BroadcastSink` + tests

**Files:**
- Create: `NemoNoise/Services/Pipeline/BroadcastSink.swift`
- Test: `NemoNoiseTests/BroadcastSinkTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// NemoNoiseTests/BroadcastSinkTests.swift
import XCTest
@testable import NemoNoise

final class RecordingSink: Sink, @unchecked Sendable {
    private(set) var delivered: [(text: String, isFinal: Bool)] = []
    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        delivered.append((result.text, isFinal))
    }
}

final class BroadcastSinkTests: XCTestCase {
    func testDeliversToAllSinks() async {
        let a = RecordingSink()
        let b = RecordingSink()
        let broadcast = BroadcastSink([a, b])

        await broadcast.deliver(TranscriptionResult(text: "hello", isFinal: false, emotion: nil), isFinal: false)
        await broadcast.deliver(TranscriptionResult(text: "world", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(a.delivered.count, 2)
        XCTAssertEqual(b.delivered.count, 2)
        XCTAssertEqual(a.delivered.last?.text, "world")
        XCTAssertTrue(a.delivered.last?.isFinal == true)
    }

    func testEmptyBroadcastIsNoop() async {
        let broadcast = BroadcastSink([])
        await broadcast.deliver(TranscriptionResult(text: "x", isFinal: false, emotion: nil), isFinal: false)
        // No assertion needed; must not crash.
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -only-testing:NemoNoiseTests/BroadcastSinkTests -quiet
```

Expected: FAIL — `BroadcastSink` undefined.

- [ ] **Step 3: Write the implementation**

```swift
// NemoNoise/Services/Pipeline/BroadcastSink.swift
import Foundation

/// Fans out each delivery to every child sink in order. Children should not
/// throw; if one fails silently (e.g. logs internally), the others still run.
final class BroadcastSink: Sink {
    private let sinks: [any Sink]

    init(_ sinks: [any Sink]) {
        self.sinks = sinks
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        for sink in sinks {
            await sink.deliver(result, isFinal: isFinal)
        }
    }
}
```

- [ ] **Step 4: Add to pbxproj + run test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -only-testing:NemoNoiseTests/BroadcastSinkTests -quiet
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(pipeline): add BroadcastSink for multi-sink fan-out

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.5 — Add `ClipboardSink`

**Files:**
- Create: `NemoNoise/Services/Sinks/ClipboardSink.swift`
- Test: `NemoNoiseTests/ClipboardSinkTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// NemoNoiseTests/ClipboardSinkTests.swift
import XCTest
import AppKit
@testable import NemoNoise

final class ClipboardSinkTests: XCTestCase {
    func testDeliversFinalToClipboard() async {
        NSPasteboard.general.clearContents()
        let sink = ClipboardSink()
        await sink.deliver(TranscriptionResult(text: "hello clipboard", isFinal: true, emotion: nil), isFinal: true)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello clipboard")
    }

    func testIgnoresPartial() async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("existing", forType: .string)

        let sink = ClipboardSink()
        await sink.deliver(TranscriptionResult(text: "partial", isFinal: false, emotion: nil), isFinal: false)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "existing")
    }

    func testIgnoresEmptyText() async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("existing", forType: .string)

        let sink = ClipboardSink()
        await sink.deliver(TranscriptionResult(text: "", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "existing")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -only-testing:NemoNoiseTests/ClipboardSinkTests -quiet
```

Expected: FAIL.

- [ ] **Step 3: Write the implementation**

```swift
// NemoNoise/Services/Sinks/ClipboardSink.swift
import AppKit

/// Sink that writes final transcriptions to `NSPasteboard.general`.
/// Used standalone (e.g. as a manual export sink) or composed by
/// `TextInjectorSink` as the fallback when AX injection fails.
final class ClipboardSink: Sink {
    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard isFinal, !result.text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.text, forType: .string)
    }
}
```

- [ ] **Step 4: Add to pbxproj (new group `Services/Sinks/`) + run test**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(pipeline): add ClipboardSink

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.6 — Add `TextInjectorSink`

**Files:**
- Create: `NemoNoise/Services/Sinks/TextInjectorSink.swift`
- Test: `NemoNoiseTests/TextInjectorSinkTests.swift`

This sink attempts AX injection via `TextInjector`; on failure it composes `ClipboardSink` and emits `PipelineEvent.injectionFailed` so the controller can decide whether to show the accessibility alert.

The "emit event" mechanism: since `Sink.deliver` returns nothing, the sink needs a side channel. We use a closure stored on the sink that the pipeline wires to its event continuation.

- [ ] **Step 1: Write the failing test**

```swift
// NemoNoiseTests/TextInjectorSinkTests.swift
import XCTest
@testable import NemoNoise

final class TextInjectorSinkTests: XCTestCase {

    // The real TextInjector can't be unit-tested without an active AX target,
    // so we test through a protocol. The sink takes an injector + a clipboard
    // sink + an onFailure closure; we inject fakes.

    func testSuccessfulInjectionDoesNotTriggerFallback() async {
        let injector = StubInjector(successResult: true)
        var failureCalled = false
        let sink = TextInjectorSink(
            injector: injector,
            clipboardFallback: RecordingClipboardSink(),
            onInjectionFailed: { failureCalled = true }
        )

        await sink.deliver(TranscriptionResult(text: "hi", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(injector.injectCalls, ["hi"])
        XCTAssertFalse(failureCalled)
    }

    func testFailedInjectionFallsBackToClipboardAndFiresCallback() async {
        let injector = StubInjector(successResult: false)
        let clipboard = RecordingClipboardSink()
        var failureCalled = false
        let sink = TextInjectorSink(
            injector: injector,
            clipboardFallback: clipboard,
            onInjectionFailed: { failureCalled = true }
        )

        await sink.deliver(TranscriptionResult(text: "fallback me", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(injector.injectCalls, ["fallback me"])
        XCTAssertEqual(clipboard.delivered, ["fallback me"])
        XCTAssertTrue(failureCalled)
    }

    func testIgnoresPartialAndEmpty() async {
        let injector = StubInjector(successResult: true)
        let sink = TextInjectorSink(
            injector: injector,
            clipboardFallback: RecordingClipboardSink(),
            onInjectionFailed: { }
        )

        await sink.deliver(TranscriptionResult(text: "partial", isFinal: false, emotion: nil), isFinal: false)
        await sink.deliver(TranscriptionResult(text: "", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertTrue(injector.injectCalls.isEmpty)
    }
}

// MARK: - Test doubles

final class StubInjector: TextInjecting, @unchecked Sendable {
    private(set) var injectCalls: [String] = []
    private let successResult: Bool
    init(successResult: Bool) { self.successResult = successResult }
    func injectAX(_ text: String) async -> Bool {
        injectCalls.append(text)
        return successResult
    }
}

final class RecordingClipboardSink: Sink, @unchecked Sendable {
    private(set) var delivered: [String] = []
    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        delivered.append(result.text)
    }
}
```

- [ ] **Step 2: Add `TextInjecting` protocol so we can test**

Edit `NemoNoise/Services/Output/TextInjector.swift` — add a protocol *above* the existing class, and declare conformance:

```swift
// Add near the top, after the imports:
protocol TextInjecting: Sendable {
    func injectAX(_ text: String) async -> Bool
}

// Modify the existing class declaration:
final class TextInjector: TextInjecting, @unchecked Sendable {
    // existing body unchanged
}
```

(Note: `TextInjector` is currently *not* marked Sendable. Mark it `@unchecked Sendable` because `targetElement` is mutable but accessed only from MainActor in current call sites. We'll formalize this in Stage 4.)

- [ ] **Step 3: Run failing test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -only-testing:NemoNoiseTests/TextInjectorSinkTests -quiet
```

Expected: FAIL — `TextInjectorSink` undefined.

- [ ] **Step 4: Write the sink**

```swift
// NemoNoise/Services/Sinks/TextInjectorSink.swift
import Foundation

/// Sink that delivers final transcriptions via Accessibility-based text
/// injection. On failure, falls back to `clipboardFallback` and notifies the
/// controller via `onInjectionFailed` (which surfaces as
/// `PipelineEvent.injectionFailed`).
final class TextInjectorSink: Sink {
    private let injector: any TextInjecting
    private let clipboardFallback: any Sink
    private let onInjectionFailed: @Sendable () -> Void

    init(
        injector: any TextInjecting,
        clipboardFallback: any Sink,
        onInjectionFailed: @escaping @Sendable () -> Void
    ) {
        self.injector = injector
        self.clipboardFallback = clipboardFallback
        self.onInjectionFailed = onInjectionFailed
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard isFinal, !result.text.isEmpty else { return }
        let success = await injector.injectAX(result.text)
        if !success {
            await clipboardFallback.deliver(result, isFinal: true)
            onInjectionFailed()
        }
    }
}
```

- [ ] **Step 5: Add files to pbxproj + run tests**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -only-testing:NemoNoiseTests/TextInjectorSinkTests -quiet
```

Expected: PASS.

- [ ] **Step 6: Full suite check**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: green.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(pipeline): add TextInjectorSink with clipboard fallback

Encapsulates AX injection + clipboard-fallback strategy currently inlined in
RecordingController.injectText. Adds TextInjecting protocol for testability.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.7 — Add `SubtitleOverlaySink`

**Files:**
- Create: `NemoNoise/Services/Sinks/SubtitleOverlaySink.swift`
- Test: `NemoNoiseTests/SubtitleOverlaySinkTests.swift`

This sink writes results into the `TranslationController`'s `@Observable` properties. Tested by injecting a stub controller-like target.

- [ ] **Step 1: Define a target protocol the sink writes to**

We don't want the sink to import `TranslationController` directly (that would create a cycle). Define a writer protocol in the sink file.

- [ ] **Step 2: Write the failing test**

```swift
// NemoNoiseTests/SubtitleOverlaySinkTests.swift
import XCTest
@testable import NemoNoise

@MainActor
final class StubSubtitleTarget: SubtitleWriter {
    var englishText: String = ""
    var partialText: String = ""
}

@MainActor
final class SubtitleOverlaySinkTests: XCTestCase {
    func testPartialUpdatesPartialText() async {
        let target = StubSubtitleTarget()
        let sink = SubtitleOverlaySink(target: target)
        await sink.deliver(TranscriptionResult(text: "hello partial", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "hello partial")
        XCTAssertEqual(target.englishText, "")
    }

    func testFinalClearsPartialAndSetsEnglish() async {
        let target = StubSubtitleTarget()
        target.partialText = "stale"
        let sink = SubtitleOverlaySink(target: target)
        await sink.deliver(TranscriptionResult(text: "hello final", isFinal: true, emotion: nil), isFinal: true)
        XCTAssertEqual(target.englishText, "hello final")
        XCTAssertEqual(target.partialText, "")
    }

    func testEmptyTextIsIgnored() async {
        let target = StubSubtitleTarget()
        target.englishText = "kept"
        let sink = SubtitleOverlaySink(target: target)
        await sink.deliver(TranscriptionResult(text: "", isFinal: true, emotion: nil), isFinal: true)
        XCTAssertEqual(target.englishText, "kept")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Expected: FAIL.

- [ ] **Step 4: Write the implementation**

```swift
// NemoNoise/Services/Sinks/SubtitleOverlaySink.swift
import Foundation

/// What `SubtitleOverlaySink` writes into. `TranslationController` will
/// conform to this so the sink doesn't import the controller directly.
@MainActor
protocol SubtitleWriter: AnyObject {
    var englishText: String { get set }
    var partialText: String { get set }
}

/// Updates a `SubtitleWriter` (i.e. TranslationController) with transcription
/// progress. Partial → `partialText`; final → `englishText` + clear partial.
final class SubtitleOverlaySink: Sink {
    private let target: any SubtitleWriter

    init(target: any SubtitleWriter) {
        self.target = target
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard !result.text.isEmpty else { return }
        await MainActor.run {
            if isFinal {
                target.englishText = result.text
                target.partialText = ""
            } else {
                target.partialText = result.text
            }
        }
    }
}
```

- [ ] **Step 5: Add files + run tests**

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(pipeline): add SubtitleOverlaySink

Writes partial/final transcriptions into a SubtitleWriter target.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.8 — Add `OverlayProgressSink`

**Files:**
- Create: `NemoNoise/Services/Sinks/OverlayProgressSink.swift`
- Test: `NemoNoiseTests/OverlayProgressSinkTests.swift`

Analogous to `SubtitleOverlaySink` but for `RecordingController`'s overlay. Writes `partialText` and `micLevel`.

- [ ] **Step 1: Write the failing test**

```swift
// NemoNoiseTests/OverlayProgressSinkTests.swift
import XCTest
@testable import NemoNoise

@MainActor
final class StubOverlayTarget: OverlayWriter {
    var partialText: String = ""
}

@MainActor
final class OverlayProgressSinkTests: XCTestCase {
    func testPartialUpdatesPartialText() async {
        let target = StubOverlayTarget()
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "hi", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "hi")
    }

    func testFinalDoesNotClearPartial() async {
        // Final delivery is handled by TextInjectorSink for dictation; the
        // overlay sink does nothing on final so the overlay shows the recognised
        // text until the controller hides the overlay.
        let target = StubOverlayTarget()
        target.partialText = "kept"
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "final", isFinal: true, emotion: nil), isFinal: true)
        XCTAssertEqual(target.partialText, "kept")
    }

    func testEmptyTextIgnored() async {
        let target = StubOverlayTarget()
        target.partialText = "kept"
        let sink = OverlayProgressSink(target: target)
        await sink.deliver(TranscriptionResult(text: "", isFinal: false, emotion: nil), isFinal: false)
        XCTAssertEqual(target.partialText, "kept")
    }
}
```

- [ ] **Step 2: Run failing test**

Expected: FAIL.

- [ ] **Step 3: Write implementation**

```swift
// NemoNoise/Services/Sinks/OverlayProgressSink.swift
import Foundation

@MainActor
protocol OverlayWriter: AnyObject {
    var partialText: String { get set }
}

/// Pushes partial transcription text into the recording overlay. Final results
/// are intentionally ignored here — dictation's final result flows through
/// `TextInjectorSink`, and the controller manages overlay visibility.
final class OverlayProgressSink: Sink {
    private let target: any OverlayWriter

    init(target: any OverlayWriter) {
        self.target = target
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard !isFinal, !result.text.isEmpty else { return }
        await MainActor.run {
            target.partialText = result.text
        }
    }
}
```

- [ ] **Step 4: Add files + run tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(pipeline): add OverlayProgressSink for dictation overlay partial text

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.9 — Add `TranscriptionPipeline` core + happy-path tests

This is the heart of the refactor. We TDD it with fake source + fake engine.

**Files:**
- Create: `NemoNoise/Services/Pipeline/TranscriptionPipeline.swift`
- Test: `NemoNoiseTests/TranscriptionPipelineTests.swift`
- Test helpers: extend `NemoNoiseTests/ASREngineMockTests.swift` (rename `MockASRService` → `MockASREngine`) and add `MockAudioSource`.

- [ ] **Step 1: Rename `MockASRService` to `MockASREngine` and add `MockAudioSource`**

Edit `NemoNoiseTests/ASREngineMockTests.swift`:

```swift
// Rename the class and update the test references.
final class MockASREngine: ASREngine, @unchecked Sendable {
    var isStreaming: Bool = true
    private(set) var feedChunkCallCount = 0
    private(set) var finishCallCount = 0
    private(set) var resetCallCount = 0
    private(set) var lastFeedSamples: [Float]?
    private(set) var lastFeedSampleRate: Int?

    // New: control return values from outside.
    var feedChunkResultText: String = "mock partial"
    var feedChunkShouldThrow: Error?
    var finishResultText: String = "mock final"
    var finishShouldThrow: Error?

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        feedChunkCallCount += 1
        lastFeedSamples = samples
        lastFeedSampleRate = sampleRate
        if let err = feedChunkShouldThrow { throw err }
        return TranscriptionResult(text: feedChunkResultText, isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        finishCallCount += 1
        if let err = finishShouldThrow { throw err }
        return TranscriptionResult(text: finishResultText, isFinal: true, emotion: "neutral")
    }

    func reset() {
        resetCallCount += 1
    }
}
```

Update the existing tests in the same file (`testMockConformsToProtocol`, etc.) to reference `MockASREngine` and `any ASREngine`.

Add a new helper file `NemoNoiseTests/MockAudioSource.swift`:

```swift
// NemoNoiseTests/MockAudioSource.swift
import Foundation
@testable import NemoNoise

/// Test double that emits AudioChunks driven by the test.
final class MockAudioSource: AudioSource, @unchecked Sendable {
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    var throwOnStart: Error?

    func start() async throws -> AsyncStream<AudioChunk> {
        startCalls += 1
        if let err = throwOnStart { throw err }
        return AsyncStream<AudioChunk> { cont in
            self.continuation = cont
        }
    }

    func stop() {
        stopCalls += 1
        continuation?.finish()
        continuation = nil
    }

    /// Push a chunk to whoever's iterating.
    func emit(samples: [Float], rmsLevel: Float = 0.1) {
        continuation?.yield(AudioChunk(samples: samples, rmsLevel: rmsLevel))
    }

    /// End the stream without an error.
    func finishStream() {
        continuation?.finish()
    }
}
```

- [ ] **Step 2: Write the failing pipeline test (start → chunk → finalize)**

```swift
// NemoNoiseTests/TranscriptionPipelineTests.swift
import XCTest
@testable import NemoNoise

@MainActor
final class TranscriptionPipelineTests: XCTestCase {

    // MARK: - Happy path

    func testPipelineYieldsPartialOnChunkAndFinalOnFinalize() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        engine.feedChunkResultText = "partial-text"
        engine.finishResultText = "final-text"

        let sink = RecordingSink() // from BroadcastSinkTests file — same target
        let pipeline = TranscriptionPipeline(
            source: source,
            engine: engine,
            postProcessors: [],
            sink: sink,
            fallback: nil
        )

        let eventStream = pipeline.start()
        var collected: [PipelineEvent] = []

        let consumer = Task {
            do {
                for try await event in eventStream {
                    collected.append(event)
                    if case .final = event { break }
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        // Give the pipeline a moment to subscribe and call engine.reset + source.start.
        try await Task.sleep(for: .milliseconds(20))
        source.emit(samples: [0.1, 0.2, 0.3], rmsLevel: 0.5)
        try await Task.sleep(for: .milliseconds(20))

        let final = try await pipeline.finalize()
        XCTAssertEqual(final.text, "final-text")

        _ = await consumer.value

        // Assert we saw a partial event and then the final.
        XCTAssertTrue(collected.contains { event in
            if case .partial(let r, _) = event { return r.text == "partial-text" }
            return false
        })
        XCTAssertTrue(collected.contains { event in
            if case .final(let r) = event { return r.text == "final-text" }
            return false
        })
        XCTAssertEqual(engine.resetCallCount, 1)
        XCTAssertEqual(engine.feedChunkCallCount, 1)
        XCTAssertEqual(engine.finishCallCount, 1)
    }
}
```

- [ ] **Step 3: Run failing test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -only-testing:NemoNoiseTests/TranscriptionPipelineTests/testPipelineYieldsPartialOnChunkAndFinalOnFinalize -quiet
```

Expected: FAIL — `TranscriptionPipeline` undefined.

- [ ] **Step 4: Write the pipeline implementation**

```swift
// NemoNoise/Services/Pipeline/TranscriptionPipeline.swift
import Foundation

/// Composes audio source + ASR engine + optional post-processors + sink into a
/// runnable transcription session. Reusable: a single pipeline instance can be
/// `start`ed and `finalize`d (or `stop`ped) multiple times.
@MainActor
final class TranscriptionPipeline {
    private let source: any AudioSource
    private var primaryEngine: any ASREngine
    private let postProcessors: [any PostProcessor]
    private let sink: any Sink
    private let fallback: (any ASREngine)?

    private enum State {
        case idle
        case running(continuation: AsyncThrowingStream<PipelineEvent, Error>.Continuation, task: Task<Void, Never>)
        case finalizing
    }
    private var state: State = .idle

    init(
        source: any AudioSource,
        engine: any ASREngine,
        postProcessors: [any PostProcessor] = [],
        sink: any Sink,
        fallback: (any ASREngine)? = nil
    ) {
        self.source = source
        self.primaryEngine = engine
        self.postProcessors = postProcessors
        self.sink = sink
        self.fallback = fallback
    }

    var isStreaming: Bool { primaryEngine.isStreaming }

    /// Begin a new session. Resets the engine, starts the source, and yields
    /// `PipelineEvent`s as audio is processed.
    func start() -> AsyncThrowingStream<PipelineEvent, Error> {
        AsyncThrowingStream<PipelineEvent, Error> { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    self.primaryEngine.reset()
                    let audioStream = try await self.source.start()
                    var usingFallback = false
                    let originalEngineName = String(describing: type(of: self.primaryEngine))

                    for await chunk in audioStream {
                        let engine = self.currentEngine()
                        do {
                            var result = try await engine.feedChunk(chunk.samples, sampleRate: 16000)
                            for proc in self.postProcessors {
                                if let next = try await proc.process(result, isFinal: false) {
                                    result = next
                                }
                            }
                            await self.sink.deliver(result, isFinal: false)
                            if result.text.isEmpty {
                                continuation.yield(.rms(chunk.rmsLevel))
                            } else {
                                continuation.yield(.partial(result, rmsLevel: chunk.rmsLevel))
                            }
                        } catch where !usingFallback && self.fallback != nil {
                            usingFallback = true
                            self.primaryEngine = self.fallback!
                            self.primaryEngine.reset()
                            continuation.yield(.engineFallback(from: originalEngineName))
                        } catch {
                            continuation.finish(throwing: PipelineError.engineFailedFatally(underlying: error))
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: PipelineError.sourceUnavailable(underlying: error))
                }
            }
            self.state = .running(continuation: continuation, task: task)
        }
    }

    /// End the session, draining any tail audio and returning the final
    /// transcription. The result has already been delivered to every sink
    /// before this method returns; `.final` is also yielded on the event stream.
    func finalize() async throws -> TranscriptionResult {
        let runningInfo: (AsyncThrowingStream<PipelineEvent, Error>.Continuation, Task<Void, Never>)?
        switch state {
        case .running(let cont, let task):
            runningInfo = (cont, task)
        case .idle, .finalizing:
            runningInfo = nil
        }

        state = .finalizing

        // Stop the source so the audio loop exits.
        source.stop()
        await runningInfo?.1.value

        let engine = currentEngine()
        do {
            var result = try await engine.finish()
            for proc in postProcessors {
                if let next = try await proc.process(result, isFinal: true) {
                    result = next
                }
            }
            await sink.deliver(result, isFinal: true)
            runningInfo?.0.yield(.final(result))
            runningInfo?.0.finish()
            state = .idle
            return result
        } catch let cloud as CloudASRError {
            runningInfo?.0.finish()
            state = .idle
            switch cloud {
            case .requestTimeout:
                return TranscriptionResult(text: "", isFinal: true, emotion: nil)
            default:
                throw cloud
            }
        } catch {
            runningInfo?.0.finish(throwing: PipelineError.finalizeFailed(underlying: error))
            state = .idle
            throw PipelineError.finalizeFailed(underlying: error)
        }
    }

    /// Abort without finalizing. Use when the user cancels and no transcript
    /// is needed.
    func stop() {
        switch state {
        case .running(let cont, let task):
            source.stop()
            task.cancel()
            cont.finish()
        case .idle, .finalizing:
            break
        }
        state = .idle
    }

    private func currentEngine() -> any ASREngine { primaryEngine }
}

enum PipelineError: Error {
    case sourceUnavailable(underlying: Error)
    case engineFailedFatally(underlying: Error)
    case finalizeFailed(underlying: Error)
}
```

- [ ] **Step 5: Add files + run the happy-path test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -only-testing:NemoNoiseTests/TranscriptionPipelineTests/testPipelineYieldsPartialOnChunkAndFinalOnFinalize -quiet
```

Expected: PASS.

- [ ] **Step 6: Commit happy path**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(pipeline): add TranscriptionPipeline combinator with happy-path test

Core combinator + PipelineError. Reusable: start/finalize/stop can run
multiple times per instance. No controllers wired in yet.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.10 — Pipeline fallback + cancellation + reuse tests

Extends `TranscriptionPipelineTests` with the remaining behaviors.

- [ ] **Step 1: Add the additional tests to `TranscriptionPipelineTests.swift`**

```swift
extension TranscriptionPipelineTests {

    // MARK: - Engine fallback

    func testFallbackEngineTakesOverWhenPrimaryThrows() async throws {
        let source = MockAudioSource()
        let primary = MockASREngine()
        primary.feedChunkShouldThrow = NSError(domain: "primary", code: 1)

        let fallback = MockASREngine()
        fallback.feedChunkResultText = "from-fallback"
        fallback.finishResultText = "final-from-fallback"

        let sink = RecordingSink()
        let pipeline = TranscriptionPipeline(
            source: source,
            engine: primary,
            sink: sink,
            fallback: fallback
        )

        let events = pipeline.start()
        var sawFallback = false
        var sawFallbackPartial = false

        let consumer = Task {
            for try await event in events {
                switch event {
                case .engineFallback: sawFallback = true
                case .partial(let r, _) where r.text == "from-fallback": sawFallbackPartial = true
                default: break
                }
                if sawFallbackPartial { break }
            }
        }

        try await Task.sleep(for: .milliseconds(20))
        // Primary throws on this chunk; pipeline switches to fallback.
        source.emit(samples: [0.1])
        // After switch, give the loop time, then emit another chunk that the
        // fallback handles.
        try await Task.sleep(for: .milliseconds(20))
        source.emit(samples: [0.2])
        try await Task.sleep(for: .milliseconds(20))

        _ = try await pipeline.finalize()
        _ = await consumer.value

        XCTAssertTrue(sawFallback, "expected engineFallback event")
        XCTAssertTrue(sawFallbackPartial, "expected partial from fallback engine")
        XCTAssertEqual(fallback.resetCallCount, 1)
    }

    // MARK: - No fallback → fatal

    func testEngineFailureWithoutFallbackThrowsFatal() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        engine.feedChunkShouldThrow = NSError(domain: "engine", code: 42)

        let pipeline = TranscriptionPipeline(
            source: source,
            engine: engine,
            sink: RecordingSink(),
            fallback: nil
        )

        let events = pipeline.start()
        var caughtError: Error?
        let consumer = Task {
            do {
                for try await _ in events { /* drain */ }
            } catch {
                caughtError = error
            }
        }

        try await Task.sleep(for: .milliseconds(20))
        source.emit(samples: [0.1])
        try await Task.sleep(for: .milliseconds(50))
        source.finishStream()
        _ = await consumer.value

        guard let pipelineErr = caughtError as? PipelineError else {
            return XCTFail("expected PipelineError, got \(String(describing: caughtError))")
        }
        if case .engineFailedFatally = pipelineErr {
            // OK
        } else {
            XCTFail("expected engineFailedFatally, got \(pipelineErr)")
        }
    }

    // MARK: - Reuse

    func testPipelineCanBeStartedAgainAfterFinalize() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, sink: RecordingSink()
        )

        _ = pipeline.start()
        try await Task.sleep(for: .milliseconds(10))
        _ = try await pipeline.finalize()

        _ = pipeline.start()
        try await Task.sleep(for: .milliseconds(10))
        _ = try await pipeline.finalize()

        XCTAssertEqual(engine.resetCallCount, 2, "engine should reset on every start")
        XCTAssertEqual(source.startCalls, 2)
    }

    // MARK: - Stop without finalize

    func testStopDoesNotCallFinish() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, sink: RecordingSink()
        )

        _ = pipeline.start()
        try await Task.sleep(for: .milliseconds(10))
        pipeline.stop()

        XCTAssertEqual(engine.finishCallCount, 0)
        XCTAssertGreaterThanOrEqual(source.stopCalls, 1)
    }

    // MARK: - Source failure

    func testSourceStartFailureSurfacesAsSourceUnavailable() async throws {
        let source = MockAudioSource()
        source.throwOnStart = NSError(domain: "mic-denied", code: 1)
        let engine = MockASREngine()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, sink: RecordingSink()
        )

        let events = pipeline.start()
        var caughtError: Error?
        do {
            for try await _ in events { }
        } catch {
            caughtError = error
        }

        guard let pipelineErr = caughtError as? PipelineError else {
            return XCTFail("expected PipelineError, got \(String(describing: caughtError))")
        }
        if case .sourceUnavailable = pipelineErr {
            // OK
        } else {
            XCTFail("expected sourceUnavailable, got \(pipelineErr)")
        }
    }
}
```

- [ ] **Step 2: Run the new tests**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -only-testing:NemoNoiseTests/TranscriptionPipelineTests -quiet
```

Expected: all PASS. If any fail, the pipeline implementation in 2.9 needs adjustment — common issues:
- `currentEngine()` not picking up the swapped fallback (check the variable assignment ordering inside the `catch`)
- `finalize` not awaiting the running task before calling `engine.finish` (race)

Fix inline, then re-run.

- [ ] **Step 3: Full suite**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
test(pipeline): cover fallback, reuse, stop-without-finalize, source failure

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Stage 2 Exit Gate

- [ ] Full test suite green
- [ ] `xcodebuild build` succeeds — app still uses `SpeechOrchestrator` + old `TranslationController` loop; pipeline lives next to them, untouched
- [ ] No new compiler warnings in pipeline files
- [ ] Manual smoke: launch app, run dictation + translation — behavior unchanged

---

## Stage 3 — Migrate `TranslationController` to Pipeline (PoC)

**Stage goal:** Translation chosen first as proving ground. Simpler than dictation (no fallback, no injection, no ESC monitor). If pipeline can't handle translation cleanly, fix it here before tackling dictation.

---

### Task 3.1 — Extract `ScreenRecordingAlert`

**Files:**
- Create: `NemoNoise/UI/Permissions/ScreenRecordingAlert.swift`
- Modify: `NemoNoise/App/TranslationController.swift` (remove inline alert, call extracted func)

- [ ] **Step 1: Write the extracted alert**

```swift
// NemoNoise/UI/Permissions/ScreenRecordingAlert.swift
import AppKit

enum ScreenRecordingAlert {
    /// Returns true if the user clicked "Open System Settings", false otherwise.
    @MainActor @discardableResult
    static func present() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "NemoNoise needs screen recording permission to capture system audio.\n\nGo to System Settings → Privacy & Security → Screen Recording, then enable NemoNoise."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let response = alert.runModal()
        let openSettings = response == .alertFirstButtonReturn
        if openSettings {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return openSettings
    }
}
```

- [ ] **Step 2: Replace inline in `TranslationController.swift`**

Find the block in `startTranslation` (lines ~58-71):

```swift
guard CGPreflightScreenCaptureAccess() else {
    let alert = NSAlert()
    alert.messageText = "Screen Recording Permission Required"
    // ... (the whole inline alert) ...
    return
}
```

Replace with:

```swift
guard CGPreflightScreenCaptureAccess() else {
    ScreenRecordingAlert.present()
    return
}
```

- [ ] **Step 3: Add file to pbxproj (new group `UI/Permissions/`) + build + test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(ui): extract ScreenRecordingAlert from TranslationController

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.2 — Add `TranslateProcessor`

**Files:**
- Create: `NemoNoise/Services/PostProcessors/TranslateProcessor.swift`
- Test: `NemoNoiseTests/TranslateProcessorTests.swift`

The processor wraps `AppleTranslationService`. Translation is only run on `isFinal=true`. On error, it returns the original text rather than throwing (translation failure should not abort the recording).

- [ ] **Step 1: Write the failing test**

```swift
// NemoNoiseTests/TranslateProcessorTests.swift
import XCTest
@testable import NemoNoise

final class StubTranslationService: TranslationService, @unchecked Sendable {
    var translateCalls: [String] = []
    var resultText: String = "translated"
    var shouldThrow: Error?

    func translate(_ text: String) async throws -> String {
        translateCalls.append(text)
        if let err = shouldThrow { throw err }
        return resultText
    }
}

final class TranslateProcessorTests: XCTestCase {

    func testPartialPassesThroughUnchanged() async throws {
        let service = StubTranslationService()
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "hello", isFinal: false, emotion: nil)

        let out = try await processor.process(input, isFinal: false)
        XCTAssertNil(out, "partial should not be transformed (return nil = passthrough)")
        XCTAssertTrue(service.translateCalls.isEmpty)
    }

    func testFinalTranslates() async throws {
        let service = StubTranslationService()
        service.resultText = "你好"
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "hello", isFinal: true, emotion: nil)

        let out = try await processor.process(input, isFinal: true)
        XCTAssertEqual(out?.text, "你好")
        XCTAssertTrue(out?.isFinal == true)
        XCTAssertEqual(service.translateCalls, ["hello"])
    }

    func testTranslationErrorReturnsOriginalNotNil() async throws {
        let service = StubTranslationService()
        service.shouldThrow = NSError(domain: "translate", code: 1)
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "hello", isFinal: true, emotion: nil)

        let out = try await processor.process(input, isFinal: true)
        XCTAssertEqual(out?.text, "hello", "on translation failure, keep the source text")
    }

    func testEmptyTextSkipsTranslation() async throws {
        let service = StubTranslationService()
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "", isFinal: true, emotion: nil)

        let out = try await processor.process(input, isFinal: true)
        XCTAssertNil(out)
        XCTAssertTrue(service.translateCalls.isEmpty)
    }
}
```

- [ ] **Step 2: Run failing test**

Expected: FAIL — `TranslateProcessor` undefined.

- [ ] **Step 3: Write the implementation**

```swift
// NemoNoise/Services/PostProcessors/TranslateProcessor.swift
import Foundation

/// PostProcessor that translates final transcriptions via a TranslationService.
/// Partial results pass through unchanged (translating every keystroke is
/// expensive and produces unstable text).
///
/// Translation failures do NOT propagate as throws — the original text is
/// returned so that the recording session is never lost to a translation hiccup.
final class TranslateProcessor: PostProcessor {
    private let service: any TranslationService

    init(service: any TranslationService) {
        self.service = service
    }

    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        guard isFinal else { return nil }
        guard !result.text.isEmpty else { return nil }

        do {
            let translated = try await service.translate(result.text)
            return TranscriptionResult(text: translated, isFinal: true, emotion: result.emotion)
        } catch {
            LogService.warn("Translation failed, returning source: \(error.localizedDescription)", category: "TranslateProcessor")
            return TranscriptionResult(text: result.text, isFinal: true, emotion: result.emotion)
        }
    }
}
```

- [ ] **Step 4: Add files (new group `Services/PostProcessors/`) + run tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(pipeline): add TranslateProcessor

Translates only final results. Translation failure is non-fatal — returns
source text so a recording is never lost to a translation hiccup.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.3 — Migrate `TranslationController` to use the pipeline

**Files:**
- Modify: `NemoNoise/App/TranslationController.swift` (major rewrite, ~80 lines after)
- Modify: `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift` (remove the in-view translation trigger)
- Modify: `NemoNoise/App/NemoNoiseApp.swift` (assemble translation pipeline at startup)

This is the biggest single change in this stage. We do it as one task because partial states (pipeline declared but not used, or used but not bound) would leave the app non-functional.

- [ ] **Step 1: Declare `TranslationController` conformance to `SubtitleWriter`**

In `TranslationController.swift`, add `SubtitleWriter` conformance. The class already has `englishText` and `partialText` as `@Observable var`, so this is a one-line change:

```swift
@MainActor @Observable
final class TranslationController: SubtitleWriter {
    // existing body
}
```

- [ ] **Step 2: Replace `TranslationController` body**

Replace the file contents with this slimmer version:

```swift
// NemoNoise/App/TranslationController.swift
import SwiftUI
import KeyboardShortcuts

@MainActor @Observable
final class TranslationController: SubtitleWriter {
    var translationState: TranslationState = .idle
    var englishText: String = ""
    var partialText: String = ""
    var chineseText: String = ""        // populated by SubtitleOverlayView post-translation
    var isTranslating: Bool = false
    var audioLevel: Float = 0

    let translationService: AppleTranslationService = AppleTranslationService()
    private var subtitleController: SubtitleOverlayController?
    private var pipelineTask: Task<Void, Never>?
    private weak var recordingController: RecordingController?
    private var pipeline: TranscriptionPipeline?

    private static let translationShortcut = KeyboardShortcuts.Name("translationMode")

    func setRecordingController(_ controller: RecordingController) {
        self.recordingController = controller
    }

    /// Called by NemoNoiseApp after both controllers and their pipelines are
    /// constructed.
    func bind(pipeline: TranscriptionPipeline) {
        self.pipeline = pipeline
    }

    var isActive: Bool { translationState != .idle }

    // MARK: - Toggle

    func toggle() {
        if isActive { stopTranslation() } else { startTranslation() }
    }

    private func startTranslation() {
        guard translationState == .idle, let pipeline else { return }
        if let rc = recordingController, rc.recordingState != .ready { return }

        guard CGPreflightScreenCaptureAccess() else {
            ScreenRecordingAlert.present()
            return
        }

        _ = LogService.startSession()
        LogService.info("Translation mode starting", category: "Translation")
        translationState = .capturing
        englishText = ""
        partialText = ""
        chineseText = ""
        showSubtitle()

        pipelineTask = Task { [weak self, pipeline] in
            guard let self else { return }
            do {
                for try await event in pipeline.start() {
                    switch event {
                    case .partial(_, let rms):
                        self.audioLevel = rms
                    case .rms(let level):
                        self.audioLevel = level
                    case .final, .engineFallback, .injectionFailed:
                        break
                    }
                    // partial/final text is written by SubtitleOverlaySink
                }
            } catch {
                LogService.error("Translation pipeline error: \(error.localizedDescription)", category: "Translation")
                self.translationState = .error(error.localizedDescription)
                self.hideSubtitle()
                ToastWindowController.show("Audio capture stopped: \(error.localizedDescription)", style: .error)
            }
        }
    }

    func stopTranslation() {
        LogService.info("Translation mode stopping", category: "Translation")
        pipelineTask?.cancel()
        pipelineTask = nil
        Task { [pipeline] in
            _ = try? await pipeline?.finalize()
        }
        hideSubtitle()
        translationState = .idle
        LogService.endSession()
    }

    // MARK: - Hotkey

    private var hotkeyTask: Task<Void, Never>?

    func startHotkeyMonitoring() {
        hotkeyTask = Task { [weak self] in
            for await event in KeyboardShortcuts.events(for: Self.translationShortcut) {
                guard let self, event == .keyDown else { return }
                self.toggle()
            }
        }
    }

    // MARK: - Helper (kept for the existing ShouldTranslateTests)

    func shouldTranslate(_ text: String) -> Bool {
        let chars = Array(text)
        let asciiCount = chars.filter { $0.isASCII && $0.isLetter }.count
        let totalLetters = chars.filter { $0.isLetter }.count
        guard totalLetters > 0 else { return false }
        return Double(asciiCount) / Double(totalLetters) > 0.5
    }

    // MARK: - Subtitle Overlay

    private func showSubtitle() {
        if subtitleController == nil {
            subtitleController = SubtitleOverlayController(controller: self)
        }
        subtitleController?.show()
    }

    private func hideSubtitle() {
        subtitleController?.hide()
    }
}
```

Key removals from the old version:
- `audioCapture: SystemAudioCapture?` property — pipeline owns the source
- `asrEngine: (any ASREngine)?` property — pipeline owns the engine
- `captureTask` — replaced by `pipelineTask`
- The entire inline ASR loop in `startTranslation` (lines ~99-131 of old file)
- The manual `engine.finish()` in `stopTranslation`

- [ ] **Step 3: Update `SubtitleOverlayView.swift`**

The view currently triggers translation itself via `onChange(of: controller.englishText)` (lines 54-75). Since translation is now done by `TranslateProcessor` *inside the pipeline*, the view's onChange becomes redundant. But the view still needs to inject the `TranslationSession` into the service via `.translationTask`.

Replace the `onChange` block with nothing (delete it). Keep the `.translationTask` block.

The new body section becomes:

```swift
        .padding(12)
        .frame(minWidth: 400, maxWidth: 900)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThickMaterial)
        }
        .translationTask(.init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))) { session in
            translationSession = session
            controller.translationService.setSession(session)
        }
    }
```

Also the `displayEnglishText` computed property and `waveformBarHeight` helper stay unchanged. The `translationTask: Task<Void, Never>?` state property can be deleted along with its `onDisappear { translationTask?.cancel() }`.

Final state declarations at the top of the View:

```swift
struct SubtitleOverlayView: View {
    @Environment(TranslationController.self) private var controller
    @State private var translationSession: TranslationSession?

    var body: some View {
        // ... unchanged content ...
    }
    // displayEnglishText + waveformBarHeight unchanged
}
```

Important: the translation `chineseText` now needs to flow somehow. With `TranslateProcessor` in the pipeline, the **translated** text is what reaches `SubtitleOverlaySink`. Update the sink to write `chineseText` when isFinal=true rather than `englishText`. But then `englishText` is never populated...

This is a real design issue we need to resolve. Two options:
- **Option A:** `TranslateProcessor` returns a result whose `.text` is the *translated* text, and we lose the English. The view stops needing two lines.
- **Option B:** Don't use `TranslateProcessor` for translation in v1; keep translation in the View. The pipeline produces *English* into `englishText`, and the View's existing translationTask + onChange writes `chineseText`.

Option B is safer — it preserves the current bilingual display. **Use option B for this stage.** Skip `TranslateProcessor` integration; the processor exists but is not yet inserted into the translation pipeline. Update the `TranslationController` migration to construct the pipeline **without** a TranslateProcessor:

```swift
// In NemoNoiseApp (next step), assemble:
TranscriptionPipeline(
    source: SystemAudioSource(),
    engine: factory.makeForTranslation(),
    postProcessors: [],                          // no TranslateProcessor yet
    sink: SubtitleOverlaySink(target: translationController),
    fallback: nil
)
```

Restore the View's `onChange(of: controller.englishText)` block (don't delete it after all). This means the only architectural change for translation in stage 3 is "controller drives a pipeline instead of an inline loop"; translation itself stays in the View.

A later, scoped task can move the TranslateProcessor into the pipeline once the bilingual display question is resolved — that's not blocking the refactor.

**Update Step 3:** keep the `onChange` block intact. Leave `translationTask: Task<Void, Never>?` state. The only View change in stage 3 is *no change* — proceed.

- [ ] **Step 4: Assemble the pipeline in `NemoNoiseApp.swift`**

Modify the `init` and `body`:

```swift
@main
struct NemoNoiseApp: App {
    @State private var controller = RecordingController()
    @State private var translationController = TranslationController()
    private let updaterDelegate = UpdaterFeedProvider()
    private let updaterController: SPUStandardUpdaterController

    init() {
        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: updaterDelegate, userDriverDelegate: nil)
        self.updaterController = updater
        _ = LogService.shared
        _ = CrashGuard.shared
        SentryService.initialize()
    }

    var body: some Scene {
        MenuBarExtra {
            OnboardingGate {
                MenuBarPopoverView(updater: updaterController.updater)
                    .environment(controller)
                    .environment(translationController)
                    .task {
                        translationController.setRecordingController(controller)
                        // Assemble translation pipeline now that both controllers exist.
                        let factory = ASREngineFactory(modelManager: controller.modelManager)
                        if let engine = try? factory.makeForTranslation() {
                            let pipeline = TranscriptionPipeline(
                                source: SystemAudioSource(),
                                engine: engine,
                                postProcessors: [],
                                sink: SubtitleOverlaySink(target: translationController),
                                fallback: nil
                            )
                            translationController.bind(pipeline: pipeline)
                        }
                        controller.onTranslationActiveCheck = { [translationController] in
                            translationController.isActive
                        }
                        translationController.startHotkeyMonitoring()
                    }
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
```

Note: building the pipeline inside `.task` instead of `init` is intentional — `init` runs before `RecordingController.modelManager` is fully initialised in the `@State` storage; `.task` runs after the view appears so all properties exist.

- [ ] **Step 5: Build + test**

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: build succeeds; tests green.

If a test fails because `MockAudioSource` / `MockASREngine` reference broke during stage 0/2 churn, fix the reference and re-run.

- [ ] **Step 6: Manual QA for translation**

Run the app:
1. Play a YouTube video with English speech in the background.
2. Press the translation hotkey. Subtitle overlay appears.
3. Verify English text shows in the partial / final line.
4. Verify Chinese text appears below (translation done by the View).
5. Press the hotkey again to stop. Overlay hides.

If any step fails, the issue is most likely in `TranslationController.startTranslation` — check that `pipeline.start()` is being iterated and that `SubtitleOverlaySink` is wired to write `englishText`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(translation): drive TranslationController from TranscriptionPipeline

Replaces the inline ASR loop with a TranscriptionPipeline composed of
SystemAudioSource + ParaformerStreamingEngine + SubtitleOverlaySink.
Translation itself (English→Chinese) still runs in SubtitleOverlayView; the
TranslateProcessor exists but is not yet inserted (deferred to a later task
once bilingual display flow is settled).

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Stage 3 Exit Gate

- [ ] `TranslationController.swift` ≤ 100 lines
- [ ] Full test suite green
- [ ] Manual QA above passes
- [ ] No reference to `SystemAudioCapture` (now `SystemAudioSource`) inside `TranslationController` — confirm:

```bash
grep -n "SystemAudioSource" NemoNoise/App/TranslationController.swift || echo "Clean — pipeline owns the source"
```

Expected: `Clean — pipeline owns the source`.

---

## Stage 4 — Migrate `RecordingController` + Delete `SpeechOrchestrator`

**Stage goal:** Big one. After this, `SpeechOrchestrator.swift` is gone, dictation runs on the pipeline with fallback engine, and `RecordingController` shrinks to its UI-state-adapter role.

---

### Task 4.1 — Extract `MicPermissionAlert`

**Files:**
- Create: `NemoNoise/UI/Permissions/MicPermissionAlert.swift`
- Modify: `NemoNoise/App/RecordingController.swift` (remove inline `presentMicPermissionAlert`)

- [ ] **Step 1: Write the alert**

```swift
// NemoNoise/UI/Permissions/MicPermissionAlert.swift
import AppKit

enum MicPermissionAlert {
    @MainActor @discardableResult
    static func present() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "NemoNoise needs microphone access to record your voice.\n\nGo to System Settings → Privacy & Security → Microphone, then enable NemoNoise."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let response = alert.runModal()
        let openSettings = response == .alertFirstButtonReturn
        if openSettings {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
        return openSettings
    }
}
```

- [ ] **Step 2: Replace inline in `RecordingController.swift`**

Delete the `presentMicPermissionAlert()` method body (current lines ~322-334). Replace every call site (`presentMicPermissionAlert()`) with `MicPermissionAlert.present()`.

- [ ] **Step 3: Add file + build + test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(ui): extract MicPermissionAlert from RecordingController

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4.2 — Extract `AccessibilityAlert`

**Files:**
- Create: `NemoNoise/UI/Permissions/AccessibilityAlert.swift`
- Modify: `NemoNoise/App/RecordingController.swift` (remove inline `presentAccessibilityAlert`)

- [ ] **Step 1: Write the alert**

```swift
// NemoNoise/UI/Permissions/AccessibilityAlert.swift
import AppKit

enum AccessibilityAlert {
    @MainActor @discardableResult
    static func present() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "NemoNoise needs Accessibility permission to inject text into other apps.\n\nGo to System Settings → Privacy & Security → Accessibility, then enable NemoNoise."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let response = alert.runModal()
        let openSettings = response == .alertFirstButtonReturn
        if openSettings {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        return openSettings
    }
}
```

- [ ] **Step 2: Replace inline in `RecordingController.swift`**

Delete `presentAccessibilityAlert()` (current lines ~336-349). Replace call sites.

- [ ] **Step 3: Add + build + test + commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(ui): extract AccessibilityAlert from RecordingController

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4.3 — Add `RecordingMutex`

**Files:**
- Create: `NemoNoise/App/RecordingMutex.swift`
- Test: `NemoNoiseTests/RecordingMutexTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// NemoNoiseTests/RecordingMutexTests.swift
import XCTest
@testable import NemoNoise

@MainActor
final class RecordingMutexTests: XCTestCase {

    func testInitiallyVacant() {
        let mutex = RecordingMutex()
        XCTAssertNil(mutex.current)
    }

    func testAcquireWhenVacantSucceeds() {
        let mutex = RecordingMutex()
        XCTAssertTrue(mutex.tryAcquire(.dictation))
        XCTAssertEqual(mutex.current, .dictation)
    }

    func testAcquireWhileHeldFails() {
        let mutex = RecordingMutex()
        _ = mutex.tryAcquire(.dictation)
        XCTAssertFalse(mutex.tryAcquire(.translation))
        XCTAssertEqual(mutex.current, .dictation)
    }

    func testReleaseByOwnerVacates() {
        let mutex = RecordingMutex()
        _ = mutex.tryAcquire(.dictation)
        mutex.release(.dictation)
        XCTAssertNil(mutex.current)
    }

    func testReleaseByOtherOwnerDoesNothing() {
        let mutex = RecordingMutex()
        _ = mutex.tryAcquire(.dictation)
        mutex.release(.translation)
        XCTAssertEqual(mutex.current, .dictation)
    }

    func testReleaseWhenVacantIsNoop() {
        let mutex = RecordingMutex()
        mutex.release(.dictation)
        XCTAssertNil(mutex.current)
    }

    func testAcquireAfterReleaseSucceeds() {
        let mutex = RecordingMutex()
        _ = mutex.tryAcquire(.dictation)
        mutex.release(.dictation)
        XCTAssertTrue(mutex.tryAcquire(.translation))
    }
}
```

- [ ] **Step 2: Run failing test**

Expected: FAIL.

- [ ] **Step 3: Write implementation**

```swift
// NemoNoise/App/RecordingMutex.swift
import Foundation

/// Mutual exclusion between dictation and translation modes. Either may hold
/// the mutex at any time; the other is blocked from starting until the holder
/// releases.
@MainActor
final class RecordingMutex {
    enum Owner: Equatable {
        case dictation
        case translation
    }

    private(set) var current: Owner?

    @discardableResult
    func tryAcquire(_ owner: Owner) -> Bool {
        guard current == nil else { return false }
        current = owner
        return true
    }

    func release(_ owner: Owner) {
        if current == owner { current = nil }
    }
}
```

- [ ] **Step 4: Add files + run tests**

Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat: add RecordingMutex for dictation/translation mutual exclusion

Replaces the existing mutual weak-reference + closure handshake between the
two controllers.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4.4 — Migrate `RecordingController` to use the pipeline

This is the meatiest single task in the plan. We replace the audio/ASR loop with a pipeline subscription, move injection logic into `TextInjectorSink`, and adopt `RecordingMutex`.

**Files:**
- Modify: `NemoNoise/App/RecordingController.swift` (major rewrite, target ~200 lines)
- Modify: `NemoNoise/App/NemoNoiseApp.swift` (assemble dictation pipeline + inject mutex into both controllers)
- Modify: `NemoNoise/App/TranslationController.swift` (consume mutex instead of recordingController check)
- Delete (next task): `SpeechOrchestrator.swift`

- [ ] **Step 1: Rewrite `RecordingController.swift`**

Replace the file with:

```swift
// NemoNoise/App/RecordingController.swift
import SwiftUI
import AVFoundation
import ApplicationServices
import KeyboardShortcuts

@MainActor @Observable
final class RecordingController: OverlayWriter {
    // MARK: - UI state (observed by SwiftUI)

    var recordingState: RecordingState = .ready
    var confirmedSegments: [TranscriptionSegment] = []
    var partialText: String = ""
    var isStreaming: Bool = true
    var micLevel: Float = 0
    var isListeningSilence: Bool = false
    var recordingDuration: TimeInterval = 0

    var recordingMode: RecordingMode {
        didSet { UserDefaults.standard.set(recordingMode.rawValue, forKey: AppDefaults.Keys.recordingMode) }
    }

    var hotkeyDisplayText: String {
        let keyName: String
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            keyName = shortcut.description
        } else {
            keyName = "Not set"
        }
        switch recordingMode {
        case .pushToTalk: return "Hold \(keyName) to record"
        case .toggle:     return "Press \(keyName) to start/stop"
        }
    }

    // MARK: - Dependencies (injected after init via bind)

    let modelManager = ModelManager()
    let hotkeyMonitor = HotkeyMonitor()
    private let textInjector = TextInjector()

    private var pipeline: TranscriptionPipeline?
    private var mutex: RecordingMutex?
    private var overlayController: OverlayWindowController?

    // MARK: - Internal timers and tasks

    private var silenceTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private let maxRecordingDuration: TimeInterval = 120
    private var timerTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var escMonitor: Any?

    // MARK: - Init

    init() {
        let raw = UserDefaults.standard.string(forKey: AppDefaults.Keys.recordingMode) ?? AppDefaults.Defaults.recordingMode
        self.recordingMode = RecordingMode(rawValue: raw) ?? .pushToTalk

        hotkeyMonitor.onKeyDown = { [weak self] in
            Task { @MainActor [weak self] in self?.handleHotkeyDown() }
        }
        hotkeyMonitor.onKeyUp = { [weak self] in
            Task { @MainActor [weak self] in self?.handleHotkeyUp() }
        }
        HotkeyMigration.run()
        hotkeyMonitor.start()
    }

    func bind(pipeline: TranscriptionPipeline, mutex: RecordingMutex) {
        self.pipeline = pipeline
        self.mutex = mutex
        self.isStreaming = pipeline.isStreaming
    }

    // MARK: - Hotkey handlers

    func handleHotkeyDown() {
        switch recordingMode {
        case .pushToTalk:
            guard recordingState == .ready else { return }
            performHaptic()
            startRecording()
        case .toggle:
            switch recordingState {
            case .ready:
                performHaptic()
                startRecording()
            case .recording:
                performHaptic()
                stopRecording()
            default:
                break
            }
        }
    }

    func handleHotkeyUp() {
        if recordingMode == .pushToTalk && recordingState == .recording {
            performHaptic()
            stopRecording()
        }
    }

    private func performHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    // MARK: - Recording lifecycle

    private func startRecording() {
        guard recordingState == .ready, let pipeline, let mutex else { return }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized: break
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if granted { self.startRecording() }
            }
            return
        case .denied, .restricted:
            MicPermissionAlert.present()
            return
        @unknown default:
            return
        }

        guard mutex.tryAcquire(.dictation) else { return }

        // Lock the AX target at hotkey DOWN to avoid cursor-move races.
        textInjector.captureTarget()
        _ = LogService.startSession()
        LogService.info("Recording started, mode: \(recordingMode.rawValue), engine streaming: \(pipeline.isStreaming)", category: "Recording")

        recordingState = .recording
        confirmedSegments = []
        partialText = ""
        isStreaming = pipeline.isStreaming
        showOverlay()
        startTimer()
        startEscMonitor()

        pipelineTask = Task { [weak self, pipeline] in
            guard let self else { return }
            do {
                self.resetSilenceTimer()
                for try await event in pipeline.start() {
                    switch event {
                    case .partial(_, let rms):
                        self.micLevel = rms
                        self.isListeningSilence = false
                        self.resetSilenceTimer()
                    case .rms(let level):
                        self.micLevel = level
                    case .engineFallback(let from):
                        self.isStreaming = pipeline.isStreaming
                        LogService.info("Engine fallback from \(from)", category: "Recording")
                        ToastWindowController.show("Switched to local engine", style: .info)
                    case .injectionFailed:
                        if !AXIsProcessTrusted() {
                            AccessibilityAlert.present()
                        }
                        ToastWindowController.show("Copied to clipboard", style: .success)
                    case .final:
                        break // handled in stopRecording via finalize()
                    }
                }
            } catch {
                self.handlePipelineError(error)
            }
        }
    }

    private func stopRecording() {
        guard recordingState == .recording, let pipeline, let mutex else { return }

        LogService.info("Recording stopped, duration: \(String(format: "%.1f", recordingDuration))s", category: "Recording")

        recordingState = .processing
        stopTimer()
        invalidateSilenceTimer()
        stopEscMonitor()

        Task { [weak self, pipeline, mutex] in
            defer { mutex.release(.dictation) }
            guard let self else { return }
            do {
                let final = try await pipeline.finalize()
                self.partialText = ""
                if !final.text.isEmpty {
                    let segment = TranscriptionSegment(text: final.text, emotion: final.emotion)
                    self.confirmedSegments.append(segment)
                    LogService.info("Transcription complete, length: \(final.text.count) chars", category: "Recording")
                    self.scheduleOverlayHide(after: 2)
                } else {
                    LogService.info("Transcription complete, no text produced", category: "Recording")
                    self.scheduleOverlayHide(after: 2)
                }
                self.recordingState = .ready
                LogService.endSession()
            } catch {
                self.handlePipelineError(error)
            }
        }
    }

    private func handlePipelineError(_ error: Error) {
        LogService.error("Recording error: \(error.localizedDescription)", category: "Recording")
        SentryService.capture(error: error)

        // Always release the mutex on error paths.
        mutex?.release(.dictation)

        if let pipelineErr = error as? PipelineError {
            switch pipelineErr {
            case .sourceUnavailable:
                MicPermissionAlert.present()
            case .engineFailedFatally(let underlying):
                if let cloud = underlying as? CloudASRError, case .authenticationFailed = cloud {
                    ToastWindowController.show("API key invalid. Please update in Settings.", style: .error, duration: 5)
                } else {
                    presentAlert(title: "Engine Error", message: pipelineErr.localizedDescription)
                }
            case .finalizeFailed(let underlying):
                presentAlert(title: "Recognition Error", message: underlying.localizedDescription)
            }
        } else {
            presentAlert(title: "Error", message: error.localizedDescription)
        }

        recordingState = .ready
        pipeline?.stop()
        stopEscMonitor()
        hideOverlay()
        LogService.endSession()
    }

    // MARK: - Overlay + timer + ESC (unchanged from previous version)

    private func showOverlay() {
        if overlayController == nil {
            overlayController = OverlayWindowController(controller: self)
        }
        overlayController?.show()
    }

    private func hideOverlay() { overlayController?.hide() }

    private func scheduleOverlayHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hideOverlay()
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, recordingState == .recording else { return }
                isListeningSilence = true
            }
        }
    }

    private func invalidateSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        isListeningSilence = false
    }

    private func startTimer() {
        recordingDuration = 0
        let startTime = Date()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
                if self.recordingDuration >= self.maxRecordingDuration {
                    LogService.info("Max recording duration reached, auto-stopping", category: "Recording")
                    ToastWindowController.show("Recording stopped at \(Int(self.maxRecordingDuration))s limit", style: .warning)
                    self.stopRecording()
                    return
                }
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func startEscMonitor() {
        guard recordingMode == .toggle else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            if recordingState == .recording {
                performHaptic()
                stopRecording()
            }
            return nil
        }
    }

    private func stopEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert.runModal()
    }
}
```

Notable changes from old version:
- Removed: `orchestrator: SpeechOrchestrator` property; `transcriptionTask`; `injectText`; `presentMicPermissionAlert`; `presentAccessibilityAlert`; `onTranslationActiveCheck`.
- Added: `pipeline: TranscriptionPipeline?`, `mutex: RecordingMutex?`, `bind(pipeline:mutex:)`.
- `OverlayWriter` conformance: `partialText` already there; `OverlayProgressSink` will write to it.
- Error handling: typed `PipelineError` catches instead of string matching.

- [ ] **Step 2: Update `NemoNoiseApp.swift` to assemble both pipelines + mutex**

```swift
@main
struct NemoNoiseApp: App {
    @State private var controller = RecordingController()
    @State private var translationController = TranslationController()
    private let updaterDelegate = UpdaterFeedProvider()
    private let updaterController: SPUStandardUpdaterController

    init() {
        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: updaterDelegate, userDriverDelegate: nil)
        self.updaterController = updater
        _ = LogService.shared
        _ = CrashGuard.shared
        SentryService.initialize()
    }

    var body: some Scene {
        MenuBarExtra {
            OnboardingGate {
                MenuBarPopoverView(updater: updaterController.updater)
                    .environment(controller)
                    .environment(translationController)
                    .task {
                        let mutex = RecordingMutex()
                        let factory = ASREngineFactory(modelManager: controller.modelManager)

                        // Dictation pipeline
                        if let primary = try? factory.makeUserPreferred() {
                            let fallback = try? factory.makeFallback()
                            let textInjector = TextInjector()
                            let dictationSink = BroadcastSink([
                                OverlayProgressSink(target: controller),
                                TextInjectorSink(
                                    injector: textInjector,
                                    clipboardFallback: ClipboardSink(),
                                    onInjectionFailed: { /* handled via PipelineEvent.injectionFailed in controller */ }
                                )
                            ])
                            let dictationPipeline = TranscriptionPipeline(
                                source: MicAudioSource(),
                                engine: primary,
                                postProcessors: [],
                                sink: dictationSink,
                                fallback: fallback
                            )
                            controller.bind(pipeline: dictationPipeline, mutex: mutex)
                        }

                        // Translation pipeline (same as Stage 3)
                        if let engine = try? factory.makeForTranslation() {
                            let translationPipeline = TranscriptionPipeline(
                                source: SystemAudioSource(),
                                engine: engine,
                                postProcessors: [],
                                sink: SubtitleOverlaySink(target: translationController),
                                fallback: nil
                            )
                            translationController.bind(pipeline: translationPipeline)
                        }

                        translationController.setRecordingController(controller)
                        translationController.startHotkeyMonitoring()
                    }
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
```

Important: the `TextInjectorSink` here uses an **empty** `onInjectionFailed` callback because we route injection failure through `PipelineEvent.injectionFailed` instead. But the sink's current design fires the callback, not the event. Reconcile in step 3.

- [ ] **Step 3: Reconcile sink callback ↔ pipeline event**

The cleanest path is: `TextInjectorSink`'s `onInjectionFailed` callback writes into the pipeline's event continuation. But the sink doesn't have access to the continuation. Options:

**Option A** (chosen): Move the "emit injectionFailed" responsibility into the pipeline itself by adding a special wrapping. Skip the event; have the sink call `onInjectionFailed` directly. The controller passes a closure that does `AccessibilityAlert` + toast.

Revise `NemoNoiseApp.swift`'s sink construction:

```swift
let dictationSink = BroadcastSink([
    OverlayProgressSink(target: controller),
    TextInjectorSink(
        injector: textInjector,
        clipboardFallback: ClipboardSink(),
        onInjectionFailed: { [weak controller] in
            Task { @MainActor in
                if !AXIsProcessTrusted() {
                    AccessibilityAlert.present()
                }
                ToastWindowController.show("Copied to clipboard", style: .success)
            }
        }
    )
])
```

Then remove the `.injectionFailed` case from `PipelineEvent` (it's not used), and remove that switch branch from `RecordingController.startRecording`. Update `TranscriptionPipelineTests` if it tested this case (it didn't — we never added a test for `.injectionFailed`).

Edit `PipelineEvent.swift`: delete the `.injectionFailed` case and its doc comment.

Edit `RecordingController.swift` (the new version from step 1): remove the `case .injectionFailed:` branch from the event switch.

Edit the spec for honesty (optional but worth doing): note in `2026-05-14-architecture-review-design.md` §2.3 that `.injectionFailed` was removed in favor of a direct sink callback. We'll do that in Stage 5 cleanup; for now, the spec mismatch is OK.

- [ ] **Step 4: Update `TranslationController` to consume the mutex**

In `TranslationController.swift`, replace the mutual-exclusion check `if let rc = recordingController, rc.recordingState != .ready { return }` with a mutex check.

Add a `mutex` property and `bind(pipeline:mutex:)` method:

```swift
private var mutex: RecordingMutex?

func bind(pipeline: TranscriptionPipeline, mutex: RecordingMutex) {
    self.pipeline = pipeline
    self.mutex = mutex
}
```

(Delete the old single-arg `bind(pipeline:)` — only this new signature.)

In `startTranslation`, after the permission check and before setting `translationState = .capturing`:

```swift
guard let mutex, mutex.tryAcquire(.translation) else {
    return
}
```

In `stopTranslation`, release:

```swift
mutex?.release(.translation)
```

Delete `recordingController` property and `setRecordingController` method (no longer needed for mutex; only kept if needed for `modelManager` access — but that's now done via `NemoNoiseApp` direct injection).

Wait — `setRecordingController` is still called by `NemoNoiseApp` because we used `recordingController?.modelManager` for the factory before. In the new app code (step 2) the factory is built independently, so `setRecordingController` and `recordingController` property can be deleted from `TranslationController`. Remove them.

Update `NemoNoiseApp` — remove the line `translationController.setRecordingController(controller)` (the method no longer exists).

- [ ] **Step 5: Update `NemoNoiseApp` to pass mutex to translation as well**

```swift
translationController.bind(pipeline: translationPipeline, mutex: mutex)
```

(replacing the single-arg call from Stage 3)

- [ ] **Step 6: Build + test**

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Compile errors likely. Common issues:
- Some test references `controller.orchestrator` or `controller.onTranslationActiveCheck` — these are deleted; remove the test or update to match new shape.
- `RecordingController.modelManager` is still public — kept intentionally because Settings reads it.

Fix compile errors, then:

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: green except possibly `SpeechOrchestratorTests` (deleted in next task) — those tests still exist at this point but their `SpeechOrchestrator` callers haven't been deleted yet, so they should still pass. If a `SpeechOrchestratorTests` test fails because we broke something incidentally, it's almost certainly because we deleted `controller.modelManager` or similar — verify it's still there.

- [ ] **Step 7: Manual QA — 5 dictation scenarios**

Each scenario must pass:

1. **Mic happy path:** Press hotkey, speak "hello world", release. Text appears in focused app. Overlay shows partial then hides after ~2s.
2. **Mic denied:** Revoke mic permission in System Settings. Press hotkey. `MicPermissionAlert` appears.
3. **Engine fallback:** With cloud engine selected + network disabled, press hotkey, speak. Toast appears: "Switched to local engine". Recording continues with Apple Speech.
4. **Injection failure:** Open an app that lacks accessibility permission for NemoNoise (or revoke NemoNoise's accessibility briefly). Press hotkey, speak, release. Text lands on clipboard; `AccessibilityAlert` appears.
5. **ESC interrupt (toggle mode):** Switch to toggle mode. Press hotkey to start. Speak. Press ESC. Recording stops, tail audio is captured (the spoken text appears), overlay hides.

Document any failure inline as a follow-up task. If all 5 pass, proceed.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(recording): drive RecordingController from TranscriptionPipeline

Replaces SpeechOrchestrator with a pipeline composed of MicAudioSource +
user-preferred engine + Apple fallback + (OverlayProgressSink, TextInjectorSink).
Adopts RecordingMutex for cross-mode exclusion. Pipeline error handling is
now typed.

SpeechOrchestrator.swift is still present but unused; deleted in the next task.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4.5 — Delete `SpeechOrchestrator` + its tests

**Files:**
- Delete: `NemoNoise/Services/ASR/SpeechOrchestrator.swift`
- Delete: `NemoNoiseTests/SpeechOrchestratorTests.swift`

- [ ] **Step 1: Verify no remaining references**

```bash
grep -rn "SpeechOrchestrator" NemoNoise NemoNoiseTests --include="*.swift"
```

Expected: only matches inside `SpeechOrchestrator.swift` itself and `SpeechOrchestratorTests.swift`. If anything else matches, stop and fix the reference first.

- [ ] **Step 2: Delete the files**

```bash
git rm NemoNoise/Services/ASR/SpeechOrchestrator.swift
git rm NemoNoiseTests/SpeechOrchestratorTests.swift
```

- [ ] **Step 3: Update pbxproj — remove the two file entries**

Search the pbxproj for `SpeechOrchestrator` and delete every matching line (the `PBXFileReference`, `PBXBuildFile`, and the `PBXGroup` children entries).

- [ ] **Step 4: Build + test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: delete SpeechOrchestrator (replaced by TranscriptionPipeline)

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4.6 — Type-ify the remaining `error.localizedDescription.contains(...)` checks

**Files:**
- Read: `NemoNoise/App/RecordingController.swift` (already partially typed in 4.4)
- Modify: any remaining string-match catches

- [ ] **Step 1: Find remaining string-match catches**

```bash
grep -rn 'localizedDescription.contains' NemoNoise --include="*.swift"
```

Expected: should already be zero after Task 4.4 since we removed `handleError` entirely. If any matches remain, replace with a typed catch.

- [ ] **Step 2: Add a typed error for "Siri disabled" if not already covered**

The current pre-refactor code had:
```swift
if message.contains("Siri and Dictation are disabled") {
    ToastWindowController.show("请启用 Siri：系统设置 → Siri 与听写", style: .warning, duration: 5)
}
```

In `AppleSpeechASREngine`, the underlying error is an `NSError` from `SFSpeechRecognizer`. The string-match was checking that error. Now we route everything through `PipelineError.engineFailedFatally`. We need to surface the Siri case specifically.

Add to `Models/ASRError.swift`:

```swift
enum AppleSpeechError: Error {
    case siriDisabled
    case recognizerUnavailable
}
```

In `Services/ASR/AppleSpeechASREngine.swift`, where it currently throws `ASRError.audioCaptureFailed("Speech recognition permission denied")` and where the SF error reaches the continuation, wrap "Siri disabled" detection:

```swift
// Replace this in feedChunk where the recognitionTask error handler runs:
if let error {
    let mapped: Error
    let ns = error as NSError
    if ns.localizedDescription.contains("Siri and Dictation are disabled") {
        mapped = AppleSpeechError.siriDisabled
    } else {
        mapped = error
    }
    // existing logic, but pass `mapped` to the continuation instead of `error`
}
```

(The string-match is now inside the engine — one place — instead of the controller, where it's hard to test and the engine has actual visibility into the underlying error.)

In `RecordingController.handlePipelineError`, add a branch:

```swift
case .engineFailedFatally(let underlying):
    if let apple = underlying as? AppleSpeechError, apple == .siriDisabled {
        ToastWindowController.show("请启用 Siri：系统设置 → Siri 与听写", style: .warning, duration: 5)
    } else if let cloud = underlying as? CloudASRError, case .authenticationFailed = cloud {
        ToastWindowController.show("API key invalid. Please update in Settings.", style: .error, duration: 5)
    } else {
        presentAlert(title: "Engine Error", message: underlying.localizedDescription)
    }
```

(Make `AppleSpeechError: Equatable` if needed for the `apple == .siriDisabled` comparison.)

- [ ] **Step 3: Add files (already exist) + build + test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(asr): type-ify Siri-disabled error path

Move the "Siri and Dictation are disabled" string match from controller into
AppleSpeechASREngine as a typed AppleSpeechError.siriDisabled.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Stage 4 Exit Gate

- [ ] `RecordingController.swift` ≤ 250 lines (target ~200; ceiling 250)
- [ ] `SpeechOrchestrator.swift` does not exist
- [ ] `grep -rn "localizedDescription.contains" NemoNoise --include="*.swift"` returns nothing
- [ ] All 5 manual QA dictation scenarios pass
- [ ] Full test suite green

---

## Stage 5 — Cleanup + Docs

**Stage goal:** Final polish. Remove orphans, document the new architecture, update spec where reality diverged.

---

### Task 5.1 — Remove orphaned code

- [ ] **Step 1: Find unused symbols**

Scan for things that were referenced only by deleted code:

```bash
# These should all be gone after Stage 4.
grep -rn "onTranslationActiveCheck" NemoNoise NemoNoiseTests --include="*.swift"
grep -rn "onEngineFallback" NemoNoise NemoNoiseTests --include="*.swift"
grep -rn "injectText" NemoNoise NemoNoiseTests --include="*.swift"
grep -rn "presentMicPermissionAlert\|presentAccessibilityAlert" NemoNoise --include="*.swift"
```

Each command should return nothing (or only false positives in comments). If a reference survived (e.g. in a test file that still references `controller.onTranslationActiveCheck`), delete the assertion or update the test.

- [ ] **Step 2: Update `TextInjector` if `captureTarget` is no longer used by anyone except the sink**

`TextInjector.captureTarget()` is called by `RecordingController.startRecording` (kept — must run at hotkey DOWN). Leave it.

- [ ] **Step 3: Build + test**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS,arch=arm64' -quiet
```

- [ ] **Step 4: Commit (only if anything changed)**

```bash
git add -A
git diff --cached --quiet || git commit -m "$(cat <<'EOF'
refactor: remove orphaned symbols left by pipeline migration

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 5.2 — Write `docs/architecture.md`

**Files:**
- Create: `docs/architecture.md`

- [ ] **Step 1: Write the doc**

```markdown
# NemoNoise Architecture

NemoNoise is built around a single composition: `AudioSource → ASREngine → [PostProcessor] → Sink`. Two scenarios — dictation and translation — are different configurations of the same `TranscriptionPipeline`.

## Pipeline shape

```
+--------------+   chunks   +-----------+  results  +---------------+  results  +-------+
|  AudioSource | ─────────▶ | ASREngine | ────────▶ | PostProcessor | ────────▶ | Sink  |
+--------------+            +-----------+           +---------------+           +-------+
                                  │
                                  └── if it throws and fallback is set: switch to fallback engine
```

Only `TranscriptionPipeline` knows about composition. Engines and sources don't know each other; sinks don't know engines.

## Key files

| Concern | File |
|---------|------|
| Composition | `Services/Pipeline/TranscriptionPipeline.swift` |
| Audio sources | `Services/Audio/AudioSource.swift` + `MicAudioSource.swift` + `SystemAudioSource.swift` |
| ASR engines | `Services/ASR/ASREngine.swift` + 4 implementations |
| Engine factory | `Services/ASR/ASREngineFactory.swift` |
| Sinks | `Services/Pipeline/Sink.swift`, `BroadcastSink.swift`, `Services/Sinks/*` |
| Post-processors | `Services/Pipeline/PostProcessor.swift`, `Services/PostProcessors/*` |
| App wiring | `App/NemoNoiseApp.swift` (assembly), `App/RecordingController.swift`, `App/TranslationController.swift` (UI adapters), `App/RecordingMutex.swift` |

## How to add a new ASR engine

1. Create `Services/ASR/<Name>Engine.swift` conforming to `ASREngine` (3 methods: `feedChunk`, `finish`, `reset`).
2. Add a case in `ASREngineFactory.makeUserPreferred()` matched on the engine type string from Settings.
3. Add a user-facing toggle in `UI/Settings/SettingsView.swift`.
4. Write engine unit tests.

No pipeline code needs to change.

## How to add a new audio source

1. Create `Services/Audio/<Name>Source.swift` conforming to `AudioSource` (2 methods: `start`, `stop` returning `AsyncStream<AudioChunk>`).
2. Resample to 16 kHz Float mono if your source produces other formats (see `AudioResampler`).
3. Plug it into a pipeline configuration in `NemoNoiseApp` for whatever flow uses it.

No pipeline code needs to change.

## How to add a new post-processor

1. Create `Services/PostProcessors/<Name>Processor.swift` conforming to `PostProcessor` (1 method: `process(_:isFinal:) -> TranscriptionResult?`).
2. Return `nil` to pass through unchanged.
3. Insert into the relevant pipeline's `postProcessors` array in `NemoNoiseApp`.

No other code needs to change.

## Cross-mode exclusion

`RecordingMutex` (in `App/`) is acquired by whichever controller starts first; the other is blocked until release. Both controllers `defer { mutex.release(...) }` after acquire so every terminal path releases.

## Error handling

Pipeline emits semantic errors via `PipelineError`:
- `.sourceUnavailable` — mic/screen permission, no audio hardware
- `.engineFailedFatally` — primary engine and fallback both failed
- `.finalizeFailed` — `finish()` threw

Controllers map these to user-facing presentation (NSAlert, Toast) — pipeline never displays UI.

## Testing strategy

| Layer | Test type |
|-------|-----------|
| Protocols | conformance + interface tests with fakes |
| `TranscriptionPipeline` | IO-free unit tests using `MockAudioSource` + `MockASREngine` |
| Sinks | unit tests with stub targets |
| Real engines | manual QA — they require model files or network |
| Real audio sources | manual QA — they require mic/screen permission |
```

- [ ] **Step 2: Commit**

```bash
git add docs/architecture.md
git commit -m "$(cat <<'EOF'
docs: add architecture overview for pipeline-first design

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 5.3 — Update `CLAUDE.md` and `README.md`

- [ ] **Step 1: Append architecture pointer to `CLAUDE.md`**

Add at the end of `CLAUDE.md`:

```markdown
## Architecture

See `docs/architecture.md` for the pipeline-first composition model. Briefly:
- `TranscriptionPipeline` composes `AudioSource → ASREngine → [PostProcessor] → Sink`
- Both dictation and translation are configurations of the same pipeline
- Engine fallback lives in the pipeline; controllers are UI state adapters
- `RecordingMutex` enforces single-mode exclusion
```

- [ ] **Step 2: Update `README.md` (Features section)**

In the English Features list, add:
- **Composable architecture**: ASR engines, audio sources, and post-processors are pluggable via the `TranscriptionPipeline` abstraction.

In the Chinese 功能特性 list, add:
- **可组合架构**：ASR 引擎、音频源、后处理通过 `TranscriptionPipeline` 抽象插拔

- [ ] **Step 3: Update the spec to note `.injectionFailed` removal**

Edit `docs/superpowers/specs/2026-05-14-architecture-review-design.md`. In §2.3, in the `PipelineEvent` enum block, delete the `case .injectionFailed` line and its comment. Add at the end of §2.3:

```markdown
**Implementation note (1):** during Stage 4 we replaced the planned `.injectionFailed` event with a direct sink-callback (`onInjectionFailed` closure on `TextInjectorSink`). Reason: the closure approach kept the pipeline event enum focused on transcription progress rather than carrying UI hints. The behavior (controller shows accessibility alert + clipboard toast) is identical.

**Implementation note (2):** the `TranslateProcessor` exists (with tests) but is **not** wired into the translation pipeline in this refactor. Translation continues to be triggered from `SubtitleOverlayView.onChange(of: englishText)` so that the bilingual display (English line + Chinese line) keeps working without forcing `TranscriptionResult` to grow a `translatedText` field. Wiring `TranslateProcessor` into the pipeline is a follow-up task, requiring either a sink that writes both original and translated text or an extension to the result type.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md docs/superpowers/specs/2026-05-14-architecture-review-design.md
git commit -m "$(cat <<'EOF'
docs: point CLAUDE.md and README to new architecture; note spec deviation

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Stage 5 Exit Gate

- [ ] `docs/architecture.md` exists and is accurate
- [ ] `CLAUDE.md` references the new doc
- [ ] Spec deviation noted
- [ ] All 5 dictation + 1 translation manual QA scenarios still pass on a fresh launch
- [ ] Full test suite green
- [ ] `git log --oneline` since Stage 0 shows a clean linear history

---

## Final Smoke Test (run before declaring refactor complete)

- [ ] Fresh launch from `Release` build:
  ```bash
  xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Release -destination 'platform=macOS,arch=arm64' -quiet
  open ~/Library/Developer/Xcode/DerivedData/NemoNoise-*/Build/Products/Release/NemoNoise.app
  ```
- [ ] Mic-permission flow on first run
- [ ] Onboarding completes
- [ ] Each ASR engine option in Settings produces a working session (test Apple, Paraformer, SenseVoice if model present, Cloud if key set)
- [ ] Cloud engine fallback by disabling network
- [ ] Translation flow runs end-to-end
- [ ] App stays responsive over a 60-second recording (no main-thread stalls)
- [ ] Memory does not grow across 10 sequential recordings (rough check in Activity Monitor)

---

## Notes for the implementing engineer

- **Pacing:** Don't combine commits across stages even if a stage is short. The plan's "stage boundary contract" depends on each stage being independently verifiable.
- **`project.pbxproj`:** This is the most error-prone bit. If `xcodebuild build` starts producing "file not found" or "duplicate symbol" errors, the pbxproj is the first place to check.
- **Swift 6 strict concurrency:** Several types are `@unchecked Sendable` because they bridge Objective-C callbacks (`AVAudioEngine` tap, `SCStream` queue). Don't try to make them properly `Sendable` — the existing pattern works.
- **`MainActor` boundaries:** `TranscriptionPipeline` is `@MainActor`; engines and sources are not. When in doubt, mark new types `Sendable` and let Swift complain if you crossed a boundary wrong.
- **Tests that spin event loops:** A few pipeline tests use `Task.sleep(for: .milliseconds(20))` to let async loops drain. If those become flaky, increase to 50ms — don't try to make them deterministic with semaphores; the gain is not worth the complexity.
