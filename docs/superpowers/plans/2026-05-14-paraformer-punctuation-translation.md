# Paraformer Endpoint Punctuation + Translation ASR Replacement

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add lightweight endpoint-based punctuation to Paraformer streaming output and replace Apple Speech ASR with Paraformer in the translation flow.

**Architecture:** Restore sherpa-onnx endpoint detection in `SherpaOnlineRecognizer`, use it to append periods at sentence boundaries in `ParaformerStreamingEngine`, then swap the ASR engine in `TranslationController` from Apple Speech to Paraformer with an ASCII-based language guard for translation skipping.

**Tech Stack:** Swift, sherpa-onnx C API, Apple Translation API

---

## File Structure

| File | Responsibility |
|------|---------------|
| `NemoNoise/Services/ASR/SherpaOnnxWrapper.swift` | Thin wrapper around sherpa-onnx C API. Restore `isEndpoint` + `resetStream()` on `SherpaOnlineRecognizer`. |
| `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift` | Streaming ASR engine. Add endpoint punctuation in `feedChunk()`. |
| `NemoNoise/App/TranslationController.swift` | Translation mode controller. Replace Apple Speech with Paraformer, add `shouldTranslate()` guard, add fallback. |
| `NemoNoiseTests/ASRServiceMockTests.swift` | Existing test file. Add tests for `shouldTranslate()` logic. |

---

### Task 1: Restore endpoint detection in SherpaOnlineRecognizer

**Files:**
- Modify: `NemoNoise/Services/ASR/SherpaOnnxWrapper.swift:97-211`

These are thin wrappers around the sherpa-onnx C API (`SherpaOnnxOnlineStreamIsEndpoint`, `SherpaOnnxOnlineStreamReset`). No unit tests — the C API calls cannot be mocked without a heavy abstraction layer.

- [ ] **Step 1: Add `isEndpoint` computed property**

In `SherpaOnlineRecognizer`, after the `finalize()` method (after line 191), add:

```swift
var isEndpoint: Bool {
    guard let s = stream else { return false }
    return SherpaOnnxOnlineStreamIsEndpoint(recognizer, s) != 0
}
```

- [ ] **Step 2: Add `resetStream()` method**

After `isEndpoint`, add:

```swift
func resetStream() {
    guard let s = stream else { return }
    SherpaOnnxOnlineStreamReset(recognizer, s)
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild build -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/Services/ASR/SherpaOnnxWrapper.swift
git commit -m "feat(asr): restore endpoint detection on SherpaOnlineRecognizer"
```

---

### Task 2: Add endpoint punctuation to ParaformerStreamingEngine

**Files:**
- Modify: `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift`

The punctuation logic lives inside `feedChunk()`. After feeding audio and getting partial text, check if an endpoint was detected. If so, append `"。"` and reset the stream.

- [ ] **Step 1: Modify `feedChunk()` to add endpoint punctuation**

Replace the existing `feedChunk()` method (lines 24-27) with:

```swift
func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
    var text = recognizer.feed(samples: samples, sampleRate: Int32(sampleRate))
    if recognizer.isEndpoint {
        if !text.isEmpty {
            text += "。"
        }
        recognizer.resetStream()
    }
    return TranscriptionResult(text: text, isFinal: false, emotion: nil)
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/Services/ASR/ParaformerStreamingEngine.swift
git commit -m "feat(asr): add endpoint-based punctuation to Paraformer streaming"
```

---

### Task 3: Replace Apple Speech with Paraformer in TranslationController

**Files:**
- Modify: `NemoNoise/App/TranslationController.swift`
- Modify: `NemoNoise/App/NemoNoiseApp.swift`

This is the largest change. `TranslationController` needs `ModelManager` to create `ParaformerStreamingEngine`, a `shouldTranslate()` guard to skip translation for Chinese text, and a fallback to Apple Speech when Paraformer is unavailable.

- [ ] **Step 1: Add `shouldTranslate()` helper method**

Add this private method to `TranslationController`, before the `// MARK: - Subtitle Overlay` section (before line 162):

```swift
private func shouldTranslate(_ text: String) -> Bool {
    let asciiCount = text.unicodeScalars.filter { $0.isASCII && $0.isLetter }.count
    let totalLetters = text.unicodeScalars.filter { $0.isLetter }.count
    guard totalLetters > 0 else { return false }
    return Double(asciiCount) / Double(totalLetters) > 0.5
}
```

- [ ] **Step 2: Replace ASR engine creation in `startTranslation()`**

Replace the engine creation block (lines 73-83) with:

```swift
// Create ASR engine: Paraformer (bilingual) with Apple Speech fallback
let engine: any ASRService
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

Note: The `asrEngine` property type needs to change from `AppleSpeechASREngine?` to `(any ASRService)?`.

- [ ] **Step 3: Change `asrEngine` property type**

In the property declarations (line 16), change:

```swift
// From:
private var asrEngine: AppleSpeechASREngine?

// To:
private var asrEngine: (any ASRService)?
```

- [ ] **Step 4: Update feedChunk call site to handle async correctly**

The existing feedChunk call at line 103 already works with `any ASRService` since `feedChunk` is defined in the protocol. But the `engine` local variable captured in the closure needs to reference the correct instance. The current code uses `engine` (the local variable) which still works. No changes needed at the call site.

- [ ] **Step 5: Update `stopTranslation()` engine reset**

The existing `stopTranslation()` (lines 134-141) calls `engine.reset()`. Since `reset()` is defined in `ASRService` protocol, this already works. No change needed.

- [ ] **Step 6: Build to verify compilation**

Run: `xcodebuild build -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add NemoNoise/App/TranslationController.swift
git commit -m "feat(translation): replace Apple Speech with Paraformer for bilingual ASR"
```

---

### Task 4: Test `shouldTranslate()` logic

**Files:**
- Modify: `NemoNoiseTests/ASRServiceMockTests.swift`

The `shouldTranslate()` method is private, so we test it by making it `internal` (accessible via `@testable import`) or by extracting it. The simplest approach: change the method visibility to `internal` for testability.

- [ ] **Step 1: Change `shouldTranslate` visibility to internal**

In `TranslationController.swift`, change `private func shouldTranslate` to `func shouldTranslate` (Swift defaults to `internal`).

- [ ] **Step 2: Add tests in ASRServiceMockTests.swift**

Add the following test class at the end of the file:

```swift
final class ShouldTranslateTests: XCTestCase {

    private let controller = TranslationController()

    func testPureEnglishText() {
        XCTAssertTrue(controller.shouldTranslate("Hello world this is a test"))
    }

    func testPureChineseText() {
        XCTAssertFalse(controller.shouldTranslate("你好世界这是一个测试"))
    }

    func testMixedMostlyEnglish() {
        XCTAssertTrue(controller.shouldTranslate("Hello 你好 world"))
    }

    func testMixedMostlyChinese() {
        XCTAssertFalse(controller.shouldTranslate("你好 hello 世界"))
    }

    func testEmptyString() {
        XCTAssertFalse(controller.shouldTranslate(""))
    }

    func testNumbersOnly() {
        XCTAssertFalse(controller.shouldTranslate("12345"))
    }

    func testSingleEnglishWord() {
        XCTAssertTrue(controller.shouldTranslate("Hello"))
    }

    func testSingleChineseWord() {
        XCTAssertFalse(controller.shouldTranslate("你好"))
    }
}
```

- [ ] **Step 3: Run tests**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/ShouldTranslateTests 2>&1 | tail -10`
Expected: All 8 tests pass

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/App/TranslationController.swift NemoNoiseTests/ASRServiceMockTests.swift
git commit -m "test: add shouldTranslate language detection tests"
```

---

## Spec Coverage Check

| Spec requirement | Task |
|-----------------|------|
| Restore `isEndpoint` + `resetStream()` | Task 1 |
| Append `"。"` at endpoint in feedChunk | Task 2 |
| Call `resetStream()` after endpoint | Task 2 |
| Replace Apple Speech with Paraformer in TranslationController | Task 3 |
| Inject ModelManager access | Task 3 (via `recordingController?.modelManager`) |
| `shouldTranslate()` ASCII ratio guard | Task 3 + Task 4 |
| Fallback to Apple Speech | Task 3 |
| No UI changes | N/A (no task needed) |
| No new settings | N/A (no task needed) |
