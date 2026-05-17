# Streaming Translation Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make translation mode actually produce Chinese subtitles during streaming, by propagating `isFinal` end-to-end and wiring `TranslateProcessor` into the pipeline.

**Architecture:** Two-commit change. Commit 1 fixes the pipeline contract (engines and pipeline honor `TranscriptionResult.isFinal` mid-stream). Commit 2 wires `TranslateProcessor` in and teaches `SubtitleOverlaySink` to render bilingual results using a new `originalText` field. Dictation pipeline is held invariant via regression tests.

**Tech Stack:** Swift 6, XCTest, Apple `Speech.framework`, Apple `Translation.framework`, sherpa-onnx (Paraformer streaming).

**Spec:** `docs/superpowers/specs/2026-05-17-streaming-translation-fix-design.md`

**Test command (used throughout):**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/<TestClass> 2>&1 | tail -30
```

For full suite drop `-only-testing` and increase `tail` to 80.

---

## File Map

| File | Action | Why |
|------|--------|-----|
| `NemoNoise/Models/TranscriptionResult.swift` | modify | Add `originalText: String?` field |
| `NemoNoise/Services/Pipeline/TranscriptionPipeline.swift` | modify | Read `result.isFinal` in streaming loop |
| `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift` | modify | Emit `isFinal: true` at endpoint |
| `NemoNoise/Services/ASR/AppleSpeechASREngine.swift` | modify | Queue mid-stream finals, drain in `feedChunk` |
| `NemoNoise/Services/Sinks/SubtitleOverlaySink.swift` | modify | Bilingual rendering driven by `originalText` |
| `NemoNoise/Services/PostProcessors/TranslateProcessor.swift` | modify | Populate `originalText` on success |
| `NemoNoise/App/PipelineProvider.swift` | modify | Wire `TranslateProcessor` into translation postProcessors |
| `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift` | modify | Remove view-level onChange translation block |
| `NemoNoise/App/TranslationController.swift` | modify | Remove unused `isTranslating` field |
| `NemoNoiseTests/ASREngineMockTests.swift` | modify | Extend `MockASREngine` to support emitting `isFinal: true` mid-stream |
| `NemoNoiseTests/TranscriptionPipelineTests.swift` | modify | Add mid-stream-final propagation test |
| `NemoNoiseTests/ParaformerStreamingEngineTests.swift` | create | Endpoint-emits-final test (small unit slice) |
| `NemoNoiseTests/AppleSpeechASREngineQueueTests.swift` | create | Pure-state queue tests, no SFSpeech IO |
| `NemoNoiseTests/SubtitleOverlaySinkTests.swift` | modify | Update existing + add bilingual tests |
| `NemoNoiseTests/TranslateProcessorTests.swift` | modify | Add originalText assertions |

---

## Commit Group A — Pipeline `isFinal` propagation

### Task 1: Add `originalText` to `TranscriptionResult`

**Files:**
- Modify: `NemoNoise/Models/TranscriptionResult.swift`

- [ ] **Step 1: Edit the struct**

Replace the file contents with:

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
    let originalText: String?

    init(text: String, isFinal: Bool, emotion: String?, originalText: String? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.emotion = emotion
        self.originalText = originalText
    }
}
```

- [ ] **Step 2: Verify the project builds**

Run:
```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. The default `nil` on `originalText` means every existing call site continues to compile.

- [ ] **Step 3: Verify the existing test suite still passes**

Run:
```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: all tests pass. No commit yet — this change is part of Commit 1.

---

### Task 2: Pipeline honors `result.isFinal` in the streaming loop

**Files:**
- Modify: `NemoNoiseTests/ASREngineMockTests.swift:4-35` (extend `MockASREngine`)
- Modify: `NemoNoiseTests/TranscriptionPipelineTests.swift` (add test)
- Modify: `NemoNoise/Services/Pipeline/TranscriptionPipeline.swift:53-89` (loop change)

- [ ] **Step 1: Extend `MockASREngine` to emit mid-stream finals**

Replace the `feedChunk` method and add the supporting fields in `NemoNoiseTests/ASREngineMockTests.swift`. The class body should become:

```swift
final class MockASREngine: ASREngine, @unchecked Sendable {
    var isStreaming: Bool = true
    private(set) var feedChunkCallCount = 0
    private(set) var finishCallCount = 0
    private(set) var resetCallCount = 0
    private(set) var lastFeedSamples: [Float]?
    private(set) var lastFeedSampleRate: Int?

    // Control hooks for testing
    var feedChunkResultText: String = "mock partial"
    var feedChunkShouldThrow: Error?
    var finishResultText: String = "mock final"
    var finishShouldThrow: Error?

    /// FIFO queue of results to return from successive `feedChunk` calls.
    /// When the queue is non-empty, `feedChunk` pops from the front
    /// (ignoring `feedChunkResultText`). Use this to simulate mid-stream
    /// finals interleaved with partials.
    var feedChunkScript: [TranscriptionResult] = []

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        feedChunkCallCount += 1
        lastFeedSamples = samples
        lastFeedSampleRate = sampleRate
        if let err = feedChunkShouldThrow { throw err }
        if !feedChunkScript.isEmpty {
            return feedChunkScript.removeFirst()
        }
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

- [ ] **Step 2: Add the failing pipeline test**

Append to `NemoNoiseTests/TranscriptionPipelineTests.swift` (inside the second `extension TranscriptionPipelineTests { ... }` block, before its closing brace):

```swift
    // MARK: - Mid-stream isFinal propagation

    func testEngineMidStreamFinalYieldsFinalEvent() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        engine.feedChunkScript = [
            TranscriptionResult(text: "sentence one.", isFinal: true, emotion: nil)
        ]
        let sink = RecordingSink()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, postProcessors: [], sink: sink, fallback: nil
        )

        let events = pipeline.start()
        var collected: [PipelineEvent] = []
        let consumer = Task {
            for try await event in events {
                collected.append(event)
                if case .final = event { break }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        source.emit(samples: [0.1])
        try await Task.sleep(for: .milliseconds(50))
        source.finishStream()
        _ = try? await consumer.value
        pipeline.stop()

        XCTAssertTrue(collected.contains { event in
            if case .final(let r) = event { return r.text == "sentence one." && r.isFinal }
            return false
        }, "engine's mid-stream isFinal=true must surface as PipelineEvent.final, got: \(collected)")
    }

    func testEngineMidStreamFinalDeliveredToSinkWithIsFinalTrue() async throws {
        let source = MockAudioSource()
        let engine = MockASREngine()
        engine.feedChunkScript = [
            TranscriptionResult(text: "sentence one.", isFinal: true, emotion: nil)
        ]
        let sink = RecordingSink()
        let pipeline = TranscriptionPipeline(
            source: source, engine: engine, postProcessors: [], sink: sink, fallback: nil
        )

        let events = pipeline.start()
        let consumer = Task {
            for try await event in events {
                if case .final = event { break }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        source.emit(samples: [0.1])
        try await Task.sleep(for: .milliseconds(60))
        source.finishStream()
        _ = try? await consumer.value
        pipeline.stop()

        let finalDelivery = sink.deliveries.first { $0.isFinal && $0.text == "sentence one." }
        XCTAssertNotNil(finalDelivery, "sink.deliver must be called with isFinal=true for the mid-stream final, got: \(sink.deliveries)")
    }
```

Note: `RecordingSink` is the test-side sink already used in `TranscriptionPipelineTests`. If it does not expose a `deliveries: [(text: String, isFinal: Bool)]` list, find its definition (search `class RecordingSink` in the test bundle) and add the array if missing. If it already records via `received: [TranscriptionResult]` or similar, adapt the assertion above to that field name.

- [ ] **Step 3: Run the new tests to verify they fail**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/TranscriptionPipelineTests 2>&1 | tail -40
```

Expected: `testEngineMidStreamFinalYieldsFinalEvent` and `testEngineMidStreamFinalDeliveredToSinkWithIsFinalTrue` FAIL. The first should fail because the pipeline yields `.partial` instead of `.final`; the second because `sink.deliver` is called with `isFinal=false`.

- [ ] **Step 4: Modify the pipeline streaming loop**

In `NemoNoise/Services/Pipeline/TranscriptionPipeline.swift`, replace the for-await body in `start()` (currently lines 58–82) with:

```swift
                    for await chunk in audioStream {
                        let engine = engineBox.engine
                        do {
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
                        } catch where !usingFallback && fallbackEngine != nil {
                            usingFallback = true
                            engineBox.engine = fallbackEngine!
                            engineBox.engine.reset()
                            continuation.yield(.engineFallback(from: originalEngineName))
                        } catch {
                            continuation.finish(throwing: PipelineError.engineFailedFatally(underlying: error))
                            return
                        }
                    }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/TranscriptionPipelineTests 2>&1 | tail -30
```

Expected: all `TranscriptionPipelineTests` pass, including the two new tests.

---

### Task 3: `ParaformerStreamingEngine` emits `isFinal: true` at endpoint

**Files:**
- Create: `NemoNoiseTests/ParaformerStreamingEngineTests.swift`
- Modify: `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift:24-33`

> **Note:** `ParaformerStreamingEngine` requires real ONNX model files at construction. We can't unit-test the engine itself without those files. Instead, the unit test asserts the protocol contract by exercising the only branch that is pure logic (the endpoint-vs-non-endpoint return shape) via a small thin testable helper. If extracting a helper feels like over-engineering, mark the test class as a placeholder and rely on the existing `MockASREngine`-backed pipeline test (Task 2) plus manual QA (Task 12). Pick one path and continue.

Recommended path: extract a small pure function and test that.

- [ ] **Step 1: Add the failing test (pure-logic helper)**

Create `NemoNoiseTests/ParaformerStreamingEngineTests.swift`:

```swift
import XCTest
@testable import NemoNoise

final class ParaformerStreamingEngineTests: XCTestCase {

    func testBuildResultAtEndpointAddsPeriodAndMarksFinal() {
        let result = ParaformerStreamingEngine.buildResult(rawText: "hello world", isEndpoint: true)
        XCTAssertTrue(result.isFinal)
        XCTAssertEqual(result.text, "hello world。")
    }

    func testBuildResultAtEndpointWithEmptyTextStaysEmpty() {
        let result = ParaformerStreamingEngine.buildResult(rawText: "", isEndpoint: true)
        XCTAssertTrue(result.isFinal)
        XCTAssertEqual(result.text, "")
    }

    func testBuildResultMidStreamMarksPartial() {
        let result = ParaformerStreamingEngine.buildResult(rawText: "partial", isEndpoint: false)
        XCTAssertFalse(result.isFinal)
        XCTAssertEqual(result.text, "partial")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/ParaformerStreamingEngineTests 2>&1 | tail -20
```

Expected: compile failure — `buildResult` does not exist on `ParaformerStreamingEngine`.

- [ ] **Step 3: Implement the engine change**

Replace the body of `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift` with:

```swift
import Foundation

final class ParaformerStreamingEngine: ASREngine, @unchecked Sendable {
    private let recognizer: SherpaOnlineRecognizer

    init(modelDir: URL) throws {
        let encoderPath = modelDir.appendingPathComponent("encoder.int8.onnx").path
        let decoderPath = modelDir.appendingPathComponent("decoder.int8.onnx").path
        let tokensPath  = modelDir.appendingPathComponent("tokens.txt").path
        let start = ContinuousClock.now
        guard let r = SherpaOnlineRecognizer(
            encoderPath: encoderPath,
            decoderPath: decoderPath,
            tokensPath: tokensPath
        ) else {
            LogService.error("Model init failed, encoder: \(encoderPath)", category: "ASR")
            throw ASRError.engineInitFailed
        }
        recognizer = r
        let elapsed = ContinuousClock.now - start
        LogService.info("Model loaded, init duration: \(elapsed.description)", category: "ParaformerStreamingEngine")
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        let text = recognizer.feed(samples: samples, sampleRate: Int32(sampleRate))
        let isEndpoint = recognizer.isEndpoint
        if isEndpoint {
            recognizer.resetStream()
        }
        return Self.buildResult(rawText: text, isEndpoint: isEndpoint)
    }

    func finish() async throws -> TranscriptionResult {
        let text = recognizer.finalize()
        return TranscriptionResult(text: text, isFinal: true, emotion: nil)
    }

    func reset() {
        recognizer.startStream()
    }

    /// Pure helper to keep the endpoint-handling logic unit-testable without
    /// needing the underlying ONNX recognizer to be loaded.
    static func buildResult(rawText: String, isEndpoint: Bool) -> TranscriptionResult {
        if isEndpoint {
            let text = rawText.isEmpty ? "" : rawText + "。"
            return TranscriptionResult(text: text, isFinal: true, emotion: nil)
        }
        return TranscriptionResult(text: rawText, isFinal: false, emotion: nil)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/ParaformerStreamingEngineTests 2>&1 | tail -20
```

Expected: all three tests pass.

---

### Task 4: `AppleSpeechASREngine` queues mid-stream finals

**Files:**
- Create: `NemoNoiseTests/AppleSpeechASREngineQueueTests.swift`
- Modify: `NemoNoise/Services/ASR/AppleSpeechASREngine.swift:11-17` (State), `:59-112` (callback), `:43-121` (feedChunk), `:123-162` (finish)

> The Speech.framework parts are unreachable without permission and a live recognizer, so we **extract the queue logic into a separate type** that is pure-data and unit-testable, then have `AppleSpeechASREngine` compose it.

- [ ] **Step 1: Add the failing tests**

Create `NemoNoiseTests/AppleSpeechASREngineQueueTests.swift`:

```swift
import XCTest
@testable import NemoNoise

final class AppleSpeechFinalQueueTests: XCTestCase {

    func testPopReturnsNilWhenEmpty() {
        var queue = AppleSpeechFinalQueue()
        XCTAssertNil(queue.popNext())
    }

    func testEnqueueThenPopReturnsFIFO() {
        var queue = AppleSpeechFinalQueue()
        queue.enqueue(TranscriptionResult(text: "first.", isFinal: true, emotion: nil))
        queue.enqueue(TranscriptionResult(text: "second.", isFinal: true, emotion: nil))
        XCTAssertEqual(queue.popNext()?.text, "first.")
        XCTAssertEqual(queue.popNext()?.text, "second.")
        XCTAssertNil(queue.popNext())
    }

    func testDrainConcatenatesAllPending() {
        var queue = AppleSpeechFinalQueue()
        queue.enqueue(TranscriptionResult(text: "first.", isFinal: true, emotion: nil))
        queue.enqueue(TranscriptionResult(text: "second.", isFinal: true, emotion: nil))
        queue.enqueue(TranscriptionResult(text: "third.", isFinal: true, emotion: nil))
        let drained = queue.drainConcatenated()
        XCTAssertEqual(drained?.text, "first. second. third.")
        XCTAssertTrue(drained?.isFinal == true)
        XCTAssertNil(queue.popNext(), "queue must be empty after drain")
    }

    func testDrainReturnsNilWhenEmpty() {
        var queue = AppleSpeechFinalQueue()
        XCTAssertNil(queue.drainConcatenated())
    }

    func testDrainOfSingleEntryReturnsItVerbatim() {
        var queue = AppleSpeechFinalQueue()
        queue.enqueue(TranscriptionResult(text: "only.", isFinal: true, emotion: "joy"))
        let drained = queue.drainConcatenated()
        XCTAssertEqual(drained?.text, "only.")
        XCTAssertEqual(drained?.emotion, "joy")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/AppleSpeechFinalQueueTests 2>&1 | tail -20
```

Expected: compile failure — `AppleSpeechFinalQueue` does not exist.

- [ ] **Step 3: Implement the queue + engine integration**

Edit `NemoNoise/Services/ASR/AppleSpeechASREngine.swift`. At the top of the file, just under the imports, add:

```swift
/// FIFO queue of mid-stream final results emitted by SFSpeech. Extracted as a
/// value type so the queueing logic is unit-testable without an SFSpeech IO
/// dependency.
struct AppleSpeechFinalQueue {
    private var pending: [TranscriptionResult] = []

    mutating func enqueue(_ result: TranscriptionResult) {
        pending.append(result)
    }

    mutating func popNext() -> TranscriptionResult? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    /// Drain every queued final into one concatenated result (text joined by
    /// a single space, emotion of the first non-nil). Returns nil if empty.
    mutating func drainConcatenated() -> TranscriptionResult? {
        guard !pending.isEmpty else { return nil }
        let pieces = pending.map(\.text).filter { !$0.isEmpty }
        let combined = pieces.joined(separator: " ")
        let emotion = pending.compactMap(\.emotion).first
        pending.removeAll()
        return TranscriptionResult(text: combined, isFinal: true, emotion: emotion)
    }

    var isEmpty: Bool { pending.isEmpty }
}
```

Then replace the existing `State` struct (currently lines 11–17) with:

```swift
    private struct State {
        var partialText: String = ""
        var queue: AppleSpeechFinalQueue = AppleSpeechFinalQueue()
        var finishContinuation: CheckedContinuation<TranscriptionResult, Error>?
        var pendingError: Error?
    }
```

Update the recognition-task callback (the `if result.isFinal` branch, currently lines 94–107) to enqueue, and resume the finish continuation if one is waiting:

```swift
                if let result {
                    if result.isFinal {
                        let transcription = TranscriptionResult(
                            text: result.bestTranscription.formattedString,
                            isFinal: true,
                            emotion: nil
                        )
                        let cont = self.stateLock.withLock { state -> CheckedContinuation<TranscriptionResult, Error>? in
                            if let c = state.finishContinuation {
                                state.finishContinuation = nil
                                return c
                            }
                            state.queue.enqueue(transcription)
                            return nil
                        }
                        cont?.resume(returning: transcription)
                    } else {
                        self.stateLock.withLock { $0.partialText = result.bestTranscription.formattedString }
                    }
                }
```

Update the `feedChunk` body. After the early `recognizer.isAvailable` guard and the task-creation block (i.e. starting from the part that currently feeds the buffer and returns the partial), pop a queued final first:

```swift
    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        guard recognizer.isAvailable else {
            throw ASRError.audioCaptureFailed("Speech recognizer not available")
        }

        if request == nil {
            guard await requestPermission() else {
                throw ASRError.audioCaptureFailed("Speech recognition permission denied")
            }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = false
            req.addsPunctuation = true
            request = req

            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    let ns = error as NSError
                    let isNoSpeech = ns.code == 1110
                        || ns.localizedDescription.localizedCaseInsensitiveContains("no speech")
                    if isNoSpeech {
                        let empty = TranscriptionResult(text: "", isFinal: true, emotion: nil)
                        let cont = self.stateLock.withLock { state -> CheckedContinuation<TranscriptionResult, Error>? in
                            let cont = state.finishContinuation
                            state.finishContinuation = nil
                            if cont == nil { state.queue.enqueue(empty) }
                            return cont
                        }
                        cont?.resume(returning: empty)
                        return
                    }
                    let mapped: Error
                    if ns.localizedDescription.contains("Siri and Dictation are disabled") {
                        mapped = AppleSpeechError.siriDisabled
                    } else {
                        mapped = error
                    }
                    let cont = self.stateLock.withLock { state -> CheckedContinuation<TranscriptionResult, Error>? in
                        state.pendingError = mapped
                        let cont = state.finishContinuation
                        state.finishContinuation = nil
                        return cont
                    }
                    cont?.resume(throwing: mapped)
                    return
                }
                if let result {
                    if result.isFinal {
                        let transcription = TranscriptionResult(
                            text: result.bestTranscription.formattedString,
                            isFinal: true,
                            emotion: nil
                        )
                        let cont = self.stateLock.withLock { state -> CheckedContinuation<TranscriptionResult, Error>? in
                            if let c = state.finishContinuation {
                                state.finishContinuation = nil
                                return c
                            }
                            state.queue.enqueue(transcription)
                            return nil
                        }
                        cont?.resume(returning: transcription)
                    } else {
                        self.stateLock.withLock { $0.partialText = result.bestTranscription.formattedString }
                    }
                }
            }
        }

        // Pop any queued mid-stream final BEFORE feeding more audio so the
        // pipeline sees finals in order.
        if let queued = stateLock.withLock({ $0.queue.popNext() }) {
            // Still feed this chunk for future recognition — but the result
            // we return is the queued final.
            if let buffer = makePCMBuffer(from: samples, sampleRate: sampleRate) {
                request?.append(buffer)
            }
            return queued
        }

        if let buffer = makePCMBuffer(from: samples, sampleRate: sampleRate) {
            request?.append(buffer)
        }

        let partial = stateLock.withLock { $0.partialText }
        return TranscriptionResult(text: partial, isFinal: false, emotion: nil)
    }
```

Update `finish()` to drain the queue when non-empty:

```swift
    func finish() async throws -> TranscriptionResult {
        request?.endAudio()

        // If finals were queued but not yet drained by feedChunk, return their
        // concatenation rather than waiting on the recognizer.
        let snapshot = stateLock.withLock { state -> (TranscriptionResult?, Error?) in
            if let err = state.pendingError {
                state.pendingError = nil
                return (nil, err)
            }
            if let drained = state.queue.drainConcatenated() {
                return (drained, nil)
            }
            return (nil, nil)
        }
        if let error = snapshot.1 {
            LogService.error("Recognition failed: \(error.localizedDescription)", category: "AppleSpeechASREngine")
            throw error
        }
        if let final = snapshot.0 {
            LogService.info("Recognition complete (drained queue), length: \(final.text.count) chars", category: "AppleSpeechASREngine")
            return final
        }

        if task != nil {
            return try await withCheckedThrowingContinuation { continuation in
                let resolved = self.stateLock.withLock { state -> (TranscriptionResult?, Error?) in
                    if let error = state.pendingError {
                        state.pendingError = nil
                        return (nil, error)
                    }
                    if let drained = state.queue.drainConcatenated() {
                        return (drained, nil)
                    }
                    state.finishContinuation = continuation
                    return (nil, nil)
                }
                if let error = resolved.1 {
                    continuation.resume(throwing: error)
                } else if let final = resolved.0 {
                    continuation.resume(returning: final)
                }
            }
        }

        return TranscriptionResult(text: "", isFinal: true, emotion: nil)
    }
```

Update `reset()` (currently lines 164–169):

```swift
    func reset() {
        task?.cancel()
        task = nil
        request = nil
        stateLock.withLock { state in state = State() }
    }
```

(unchanged from before, since `State`'s default initializer now zeros the queue too).

- [ ] **Step 4: Run the queue tests to verify they pass**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/AppleSpeechFinalQueueTests 2>&1 | tail -20
```

Expected: all five queue tests pass.

- [ ] **Step 5: Run the full test suite to make sure nothing else broke**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -50
```

Expected: all tests pass. Any pre-existing Apple Speech tests should still pass because the user-visible `finish()` contract is unchanged for the no-queue path.

---

### Task 5: Dictation regression — pipeline integration test

Lock in the invariant that `OverlayProgressSink` ignores mid-stream finals so dictation cannot regress.

**Files:**
- Modify: `NemoNoiseTests/OverlayProgressSinkTests.swift`

- [ ] **Step 1: Add the regression test**

Append to `NemoNoiseTests/OverlayProgressSinkTests.swift` (inside the `OverlayProgressSinkTests` class):

```swift
    func testMidStreamFinalDoesNotMutateTargetState() async {
        let target = StubOverlayTarget()
        target.partialText = "in-flight partial"
        let sink = OverlayProgressSink(target: target)
        // Simulating the new pipeline behavior: a mid-stream isFinal=true delivery
        await sink.deliver(
            TranscriptionResult(text: "sentence one.", isFinal: true, emotion: nil),
            isFinal: true
        )
        XCTAssertEqual(target.partialText, "in-flight partial",
                       "partialText must be preserved across mid-stream finals")
        XCTAssertEqual(target.promotedSegments, [],
                       "mid-stream finals must NOT promote partial segments via the dictation sink")
    }
```

- [ ] **Step 2: Run the test to verify it passes**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/OverlayProgressSinkTests 2>&1 | tail -20
```

Expected: PASS. This test is green from day one — `OverlayProgressSink.deliver` already has `guard !isFinal, !result.text.isEmpty else { return }`. The test exists to catch any future refactor that breaks the invariant.

---

### Task 6: Commit Group A

- [ ] **Step 1: Inspect the staged set**

```bash
git status
git diff --stat
```

Expected files modified or created:
- `NemoNoise/Models/TranscriptionResult.swift`
- `NemoNoise/Services/Pipeline/TranscriptionPipeline.swift`
- `NemoNoise/Services/ASR/ParaformerStreamingEngine.swift`
- `NemoNoise/Services/ASR/AppleSpeechASREngine.swift`
- `NemoNoiseTests/ASREngineMockTests.swift`
- `NemoNoiseTests/TranscriptionPipelineTests.swift`
- `NemoNoiseTests/ParaformerStreamingEngineTests.swift` (new)
- `NemoNoiseTests/AppleSpeechASREngineQueueTests.swift` (new)
- `NemoNoiseTests/OverlayProgressSinkTests.swift`

- [ ] **Step 2: Run the full suite one more time**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -50
```

Expected: all tests pass.

- [ ] **Step 3: Stage and commit**

```bash
git add NemoNoise/Models/TranscriptionResult.swift \
        NemoNoise/Services/Pipeline/TranscriptionPipeline.swift \
        NemoNoise/Services/ASR/ParaformerStreamingEngine.swift \
        NemoNoise/Services/ASR/AppleSpeechASREngine.swift \
        NemoNoiseTests/ASREngineMockTests.swift \
        NemoNoiseTests/TranscriptionPipelineTests.swift \
        NemoNoiseTests/ParaformerStreamingEngineTests.swift \
        NemoNoiseTests/AppleSpeechASREngineQueueTests.swift \
        NemoNoiseTests/OverlayProgressSinkTests.swift

git commit -m "$(cat <<'EOF'
fix(pipeline): propagate result.isFinal end-to-end

TranscriptionPipeline's streaming loop ignored result.isFinal and hard-
coded isFinal: false on every sink and post-processor call. Engines also
swallowed mid-stream segmentation: Paraformer returned isFinal: false at
endpoint; AppleSpeech stored mid-stream finals in a single slot drained
only by finish().

This commit makes both layers honor the field:
- Pipeline reads result.isFinal and emits .final mid-stream when true.
- ParaformerStreamingEngine returns isFinal: true at endpoint.
- AppleSpeechASREngine queues mid-stream finals into a FIFO, pops them
  from feedChunk in order, and concatenates any unpopped entries on
  finish() as a safety net.

OverlayProgressSink (dictation) already ignores isFinal=true, so this
change is dictation-invariant. Regression test added to lock that in.

No user-facing change yet — Commit 2 will wire TranslateProcessor.
EOF
)"
```

Expected: commit created. Verify with `git log -1 --stat`.

---

## Commit Group B — `TranslateProcessor` wiring + bilingual sink

### Task 7: Extend `SubtitleWriter` with `chineseText`

**Files:**
- Modify: `NemoNoise/Services/Sinks/SubtitleOverlaySink.swift:3-7`
- Modify: `NemoNoiseTests/SubtitleOverlaySinkTests.swift:4-8`

- [ ] **Step 1: Add the requirement to the protocol**

In `NemoNoise/Services/Sinks/SubtitleOverlaySink.swift`, replace the protocol declaration (lines 3–7) with:

```swift
@MainActor
protocol SubtitleWriter: AnyObject {
    var englishText: String { get set }
    var partialText: String { get set }
    var chineseText: String { get set }
}
```

`TranslationController` already declares `chineseText` (`App/TranslationController.swift:9`), so its conformance is automatic.

- [ ] **Step 2: Update the test stub**

In `NemoNoiseTests/SubtitleOverlaySinkTests.swift`, replace lines 4–8 with:

```swift
@MainActor
final class StubSubtitleTarget: SubtitleWriter {
    var englishText: String = ""
    var partialText: String = ""
    var chineseText: String = ""
}
```

- [ ] **Step 3: Verify the build**

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 8: Bilingual rendering in `SubtitleOverlaySink`

**Files:**
- Modify: `NemoNoiseTests/SubtitleOverlaySinkTests.swift` (extend with new tests)
- Modify: `NemoNoise/Services/Sinks/SubtitleOverlaySink.swift:16-26` (deliver)

- [ ] **Step 1: Add the failing tests**

Append to `NemoNoiseTests/SubtitleOverlaySinkTests.swift` (inside the `SubtitleOverlaySinkTests` class):

```swift
    func testBilingualFinalSetsBothLanguages() async {
        let target = StubSubtitleTarget()
        target.partialText = "in-flight"
        let sink = SubtitleOverlaySink(target: target)
        let result = TranscriptionResult(
            text: "你好。",
            isFinal: true,
            emotion: nil,
            originalText: "Hello."
        )
        await sink.deliver(result, isFinal: true)
        XCTAssertEqual(target.englishText, "Hello.", "english must be the originalText")
        XCTAssertEqual(target.chineseText, "你好。", "chinese must be the translated text")
        XCTAssertEqual(target.partialText, "", "partial must be cleared on bilingual final")
    }

    func testUnTranslatedFinalLeavesChineseUntouched() async {
        let target = StubSubtitleTarget()
        target.chineseText = "stale-chinese"
        let sink = SubtitleOverlaySink(target: target)
        let result = TranscriptionResult(
            text: "Hello.",
            isFinal: true,
            emotion: nil,
            originalText: nil
        )
        await sink.deliver(result, isFinal: true)
        XCTAssertEqual(target.englishText, "Hello.")
        XCTAssertEqual(target.chineseText, "stale-chinese",
                       "translation-failed finals must not overwrite previously good chinese")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/SubtitleOverlaySinkTests 2>&1 | tail -30
```

Expected: `testBilingualFinalSetsBothLanguages` FAILS (`chineseText` stays empty); `testUnTranslatedFinalLeavesChineseUntouched` may pass coincidentally because the current sink does not touch `chineseText`. Both will be locked in after the change.

- [ ] **Step 3: Implement bilingual rendering**

Replace the `deliver` method in `NemoNoise/Services/Sinks/SubtitleOverlaySink.swift` (lines 16–26) with:

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
                target.partialText = ""
            } else {
                target.partialText = result.text
            }
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/SubtitleOverlaySinkTests 2>&1 | tail -30
```

Expected: all five `SubtitleOverlaySinkTests` pass.

---

### Task 9: `TranslateProcessor` preserves source via `originalText`

**Files:**
- Modify: `NemoNoiseTests/TranslateProcessorTests.swift:28-48` (extend assertions)
- Modify: `NemoNoise/Services/PostProcessors/TranslateProcessor.swift:16-27`

- [ ] **Step 1: Strengthen the existing tests + add new ones**

Replace `testFinalTranslates` and `testTranslationErrorReturnsOriginalNotNil` in `NemoNoiseTests/TranslateProcessorTests.swift`, and append `testFinalPopulatesOriginalText` and `testFailureLeavesOriginalTextNil`:

```swift
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

    func testFinalPopulatesOriginalText() async throws {
        let service = StubTranslationService()
        service.resultText = "你好"
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "hello", isFinal: true, emotion: "joy")

        let out = try await processor.process(input, isFinal: true)
        XCTAssertEqual(out?.originalText, "hello",
                       "successful translation must preserve the source in originalText")
        XCTAssertEqual(out?.emotion, "joy", "emotion must survive the processor")
    }

    func testTranslationErrorReturnsOriginalNotNil() async throws {
        let service = StubTranslationService()
        service.shouldThrow = NSError(domain: "translate", code: 1)
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "hello", isFinal: true, emotion: nil)

        let out = try await processor.process(input, isFinal: true)
        XCTAssertEqual(out?.text, "hello", "on failure, keep the source text as the primary text")
    }

    func testFailureLeavesOriginalTextNil() async throws {
        let service = StubTranslationService()
        service.shouldThrow = NSError(domain: "translate", code: 1)
        let processor = TranslateProcessor(service: service)
        let input = TranscriptionResult(text: "hello", isFinal: true, emotion: nil)

        let out = try await processor.process(input, isFinal: true)
        XCTAssertNil(out?.originalText,
                     "on failure, originalText must be nil so the sink treats this as un-translated")
    }
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/TranslateProcessorTests 2>&1 | tail -30
```

Expected: `testFinalPopulatesOriginalText` and `testFailureLeavesOriginalTextNil` FAIL — the current processor does not set `originalText`.

- [ ] **Step 3: Implement the processor change**

Replace `NemoNoise/Services/PostProcessors/TranslateProcessor.swift` with:

```swift
import Foundation

/// PostProcessor that translates final transcriptions via a TranslationService.
/// Partial results pass through unchanged (translating every keystroke is
/// expensive and produces unstable text).
///
/// On success, the translated text becomes `result.text` and the source is
/// preserved in `result.originalText` so downstream sinks can render both.
/// On failure, the source is returned as `result.text` and `originalText` is
/// left nil — sinks treat this as un-translated and avoid overwriting any
/// previously-good Chinese.
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
            return TranscriptionResult(
                text: translated,
                isFinal: true,
                emotion: result.emotion,
                originalText: result.text
            )
        } catch {
            LogService.warn("Translation failed, returning source: \(error.localizedDescription)", category: "TranslateProcessor")
            return TranscriptionResult(
                text: result.text,
                isFinal: true,
                emotion: result.emotion,
                originalText: nil
            )
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/TranslateProcessorTests 2>&1 | tail -30
```

Expected: all six `TranslateProcessorTests` pass.

---

### Task 10: Wire `TranslateProcessor` into the translation pipeline

**Files:**
- Modify: `NemoNoise/App/PipelineProvider.swift:119-145`

- [ ] **Step 1: Add `TranslateProcessor` to `applyTranslation`'s postProcessors**

Replace the `applyTranslation` method in `NemoNoise/App/PipelineProvider.swift` (lines 119–145) with:

```swift
    private func applyTranslation(result: Result<EngineBuild, Error>,
                                  punctuator: SherpaOfflinePunctuator?) {
        switch result {
        case .failure(let error):
            translation = .failed(error.localizedDescription)
            // Don't toast — translation is opt-in; surface in popover only.
            LogService.warn("Translation engine init failed: \(error.localizedDescription)",
                            category: "PipelineProvider")
        case .success(let build):
            if let translationController {
                var postProcessors: [any PostProcessor] = []
                if let punctuator {
                    postProcessors.append(PunctuationProcessor(punctuator: punctuator))
                }
                postProcessors.append(
                    TranslateProcessor(service: translationController.translationService)
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
        }
    }
```

Order: PunctuationProcessor first (so the translated text receives punctuated English as its source), TranslateProcessor second.

- [ ] **Step 2: Verify the build and run `PipelineProviderTests`**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/PipelineProviderTests 2>&1 | tail -30
```

Expected: pass. If `PipelineProviderTests` makes assertions about the count of postProcessors in the translation pipeline, update the assertion to reflect the new count (punctuator-dependent + 1). Inspect failures and adjust assertions to match the new wiring.

---

### Task 11: Remove view-level translation onChange + dead `isTranslating`

**Files:**
- Modify: `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift:1-61`
- Modify: `NemoNoise/App/TranslationController.swift:10`

- [ ] **Step 1: Simplify `SubtitleOverlayView`**

Replace the entire `SubtitleOverlayView.swift` file contents with:

```swift
import SwiftUI
import Translation

struct SubtitleOverlayView: View {
    @Environment(TranslationController.self) private var controller
    @Namespace private var glassNS

    private var subtitleStatusGlass: Glass {
        GlassTint.forSubtitle(controller.translationState).map { Glass.regular.tint($0) } ?? Glass.regular
    }

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                statusGroup
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(subtitleStatusGlass, in: .capsule)
                    .glassEffectID("subtitle-status", in: glassNS)

                if showTextCapsule {
                    textGroup
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("subtitle-text", in: glassNS)
                        .transition(.opacity)
                }
            }
        }
        .frame(minWidth: 400, maxWidth: 900)
        .animation(.smooth(duration: 0.4), value: controller.translationState)
        .translationTask(.init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))) { session in
            controller.translationService.setSession(session)
        }
    }

    private var showTextCapsule: Bool {
        controller.translationState == .capturing
            || !controller.englishText.isEmpty
            || !controller.partialText.isEmpty
    }

    private var statusGroup: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.translationState == .capturing ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            SpectrumBarsView(
                spectrum: controller.spectrum,
                isActive: controller.translationState == .capturing,
                barCount: 16,
                barColor: .green
            )
        }
    }

    private var textGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayEnglishText)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(controller.chineseText.isEmpty ? displayEnglishText : controller.chineseText)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayEnglishText: String {
        if !controller.partialText.isEmpty {
            return controller.partialText
        }
        if !controller.englishText.isEmpty {
            return controller.englishText
        }
        return "Listening…"
    }
}
```

Removed: `translationSession` and `translationTask` `@State` fields, the `.onChange(of: controller.englishText)` block, the `.onDisappear` cleanup. Kept: `.translationTask` so the session is still injected.

- [ ] **Step 2: Remove `isTranslating` from `TranslationController`**

In `NemoNoise/App/TranslationController.swift`, delete line 10:

```swift
    var isTranslating: Bool = false
```

If anything references `controller.isTranslating`, the build will fail. Grep first:

```bash
grep -rn "isTranslating" NemoNoise/ NemoNoiseTests/
```

Expected: matches only in the file being edited (and possibly in `GlassTint.swift` if it consumed the flag — if so, remove that branch too).

Also delete the stale comment `// populated by SubtitleOverlayView post-translation` on the `chineseText` line.

- [ ] **Step 3: Build the project**

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full test suite**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -60
```

Expected: all tests pass.

---

### Task 12: Manual QA — verify end-to-end

This step cannot be automated. Run it on the actual machine.

- [ ] **Step 1: Run the app**

```bash
xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise \
  -configuration Debug -destination 'platform=macOS' build
open build/Debug/NemoNoise.app
```

Or run from Xcode directly (Cmd+R).

- [ ] **Step 2: Set up Screen Recording permission**

System Settings → Privacy & Security → Screen Recording → ensure NemoNoise is enabled.

- [ ] **Step 3: Trigger translation mode**

Use the menu bar toggle (the "Translation Mode" item) OR the hotkey bound to `translationMode` in Settings. The subtitle bar appears at the bottom of the screen.

- [ ] **Step 4: Play English audio**

Open a YouTube video with clear English speech. Expected within ~3-7 seconds (depending on first-sentence length):
- Top line: English original.
- Bottom line: Chinese translation.
- Both lines update sentence-by-sentence, not character-by-character.

Cold-start caveat: the first sentence may show only English briefly while `TranslationSession` finishes initializing. Subsequent sentences should translate normally.

- [ ] **Step 5: Stop translation mode**

Press the hotkey or menu bar toggle again. Subtitle overlay hides cleanly.

- [ ] **Step 6: Sanity-check dictation still works**

Press the dictation hotkey, speak a short phrase, release. Expected:
- Overlay appears, partial text scrolls, text is injected into the focused field on stop.
- No subtitle overlay appears.
- No double injection, no clipboard clobber.

If any of the above fails, return to Phase 1 of `superpowers:systematic-debugging` — do not patch over.

---

### Task 13: Commit Group B

- [ ] **Step 1: Inspect the staged set**

```bash
git status
git diff --stat
```

Expected files modified:
- `NemoNoise/Services/PostProcessors/TranslateProcessor.swift`
- `NemoNoise/Services/Sinks/SubtitleOverlaySink.swift`
- `NemoNoise/App/PipelineProvider.swift`
- `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift`
- `NemoNoise/App/TranslationController.swift`
- `NemoNoiseTests/SubtitleOverlaySinkTests.swift`
- `NemoNoiseTests/TranslateProcessorTests.swift`
- `NemoNoiseTests/PipelineProviderTests.swift` (if assertions had to be updated in Task 10)

- [ ] **Step 2: Final test run**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -60
```

Expected: all tests pass.

- [ ] **Step 3: Stage and commit**

```bash
git add NemoNoise/Services/PostProcessors/TranslateProcessor.swift \
        NemoNoise/Services/Sinks/SubtitleOverlaySink.swift \
        NemoNoise/App/PipelineProvider.swift \
        NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift \
        NemoNoise/App/TranslationController.swift \
        NemoNoiseTests/SubtitleOverlaySinkTests.swift \
        NemoNoiseTests/TranslateProcessorTests.swift
# Add PipelineProviderTests.swift too if it was modified in Task 10.

git commit -m "$(cat <<'EOF'
feat(translation): wire TranslateProcessor into pipeline, bilingual sink

Translation mode now produces Chinese subtitles during streaming. The
view-level .onChange(of: englishText) workaround is removed; translation
runs as a post-processor on every mid-stream final result emitted by the
ASR engine.

- TranscriptionResult: TranslateProcessor sets originalText to the source
  on success and leaves it nil on failure.
- SubtitleOverlaySink: renders bilingual output when originalText is
  present; falls back to english-only for un-translated finals (so a
  failed translation does not clobber the previously-good Chinese).
- PipelineProvider.applyTranslation: appends TranslateProcessor after
  PunctuationProcessor.
- SubtitleOverlayView: keeps .translationTask to inject the session,
  removes the onChange translation block and its companion state.
- TranslationController: drops the now-dead isTranslating flag.

Together with the previous commit's isFinal propagation, this delivers
the bug fix described in
docs/superpowers/specs/2026-05-17-streaming-translation-fix-design.md
EOF
)"
```

Expected: commit created. Verify with `git log -2 --stat`.

---

## Self-Review (done)

Spec coverage check:

| Spec section | Plan task(s) |
|--------------|--------------|
| §1 `TranscriptionResult` model | Task 1 |
| §2 Pipeline streaming loop | Task 2 |
| §3 Paraformer endpoint | Task 3 |
| §4 Apple Speech queue + finish drain | Task 4 |
| §5 `TranslateProcessor` success + failure | Task 9 |
| §6 `SubtitleOverlaySink` rendering | Tasks 7, 8 |
| §7 `PipelineProvider.applyTranslation` | Task 10 |
| §8 `SubtitleOverlayView` simplification | Task 11 |
| §9 Dictation invariant | Task 5 |
| §10 `TranslationController` (`isTranslating` removal) | Task 11 |
| Testing strategy (8 tests) | Tasks 2 (pipeline 2 tests), 3 (paraformer 3 tests), 4 (queue 5 tests), 5 (regression), 8 (sink 2 tests), 9 (processor 2 tests) |
| Manual QA | Task 12 |
| Migration (2 commits) | Tasks 6, 13 |

No spec section is uncovered. No placeholder strings (`TBD`, `TODO`, `implement later`) anywhere. All type and method names are consistent across tasks (e.g. `AppleSpeechFinalQueue` is defined in Task 4 Step 3 and referenced only by tests in Task 4 Step 1 and the engine itself; `originalText: String?` is defined in Task 1 and consumed in Tasks 8, 9 with matching shape).
