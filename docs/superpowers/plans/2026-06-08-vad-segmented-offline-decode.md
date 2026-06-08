# VAD-Segmented Offline Decode (VAD Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make offline dictation engines (Qwen3 / SenseVoice) emit text progressively at speech pauses by decoding short VAD-cut segments, fixing both the long end-of-recording wait and the garbling caused by feeding over-long audio to an LLM-decoder ASR.

**Architecture:** A new pure `VADSegmenter` state machine cuts the audio stream into utterance-sized segments at silence boundaries. A new `VADSegmentingEngine` (`ASREngine` decorator) drives the Silero detector + segmenter, decodes each completed segment through the wrapped offline engine, and emits each segment as an `isFinal` result — exactly how the existing streaming engines emit endpoints. `PipelineProvider` wires offline engines through this decorator (no `VADGatedSource`); streaming/Apple engines keep the Phase-1 `VADGatedSource` path. Neither `TranscriptionPipeline` nor the `ASREngine` protocol changes.

**Tech Stack:** Swift, XCTest, sherpa-onnx (Silero VAD + Qwen3/SenseVoice), existing `VADConfig` / `VADSpeechDetector` / `OverlayProgressSink` infrastructure.

**Spec:** `docs/superpowers/specs/2026-06-08-vad-segmented-offline-decode-design.md`

---

## File Structure

- **Modify** `NemoNoise/Services/Audio/VAD/VADSpeechDetector.swift` — add three timing fields to `VADConfig`.
- **Create** `NemoNoise/Services/Audio/VAD/VADSegmenter.swift` — pure segmentation state machine + `SegmenterEvent` enum.
- **Create** `NemoNoise/Services/ASR/VADSegmentingEngine.swift` — `ASREngine` decorator: detector + segmenter + per-segment decode.
- **Modify** `NemoNoise/App/PipelineProvider.swift` — branch dictation wiring by `isStreaming`; split `makeGatedMicSource` into `makeDetector` + `makeMicSource`.
- **Create** `NemoNoiseTests/VADSegmenterTests.swift` — pure unit tests for the state machine.
- **Create** `NemoNoiseTests/VADSegmentingEngineTests.swift` — unit tests with a scripted detector + spy inner engine.

**Build/test commands** (Xcode project; adjust scheme name if different — discover with `xcodebuild -list`):

```bash
# Run a single test class:
xcodebuild test -scheme NemoNoise -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/VADSegmenterTests 2>&1 | tail -30

# Run the whole suite:
xcodebuild test -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -40
```

> If `xcodebuild` is unavailable in your environment, run the equivalent tests from Xcode (⌘U) and paste the result. Every "run the test" step below means: run that test class and confirm the pass/fail stated.

---

## Task 1: Extend `VADConfig` with segmentation timings

**Files:**
- Modify: `NemoNoise/Services/Audio/VAD/VADSpeechDetector.swift:18-27`

- [ ] **Step 1: Add the three timing fields to `VADConfig`**

Open `NemoNoise/Services/Audio/VAD/VADSpeechDetector.swift`. The current struct is:

```swift
struct VADConfig {
    /// Window fed to the detector; Silero's native window at 16 kHz.
    var windowSize: Int = 512
    /// Windows of pre-speech audio retained to recover clipped onsets.
    /// 3 × 512 / 16000 ≈ 96 ms.
    var preSpeechWindows: Int = 3
    /// Energy-fallback RMS threshold (used only by EnergySpeechDetector).
    var energyThreshold: Float = 0.02

    static let `default` = VADConfig()
}
```

Replace it with (adds three fields, keeps the implicit memberwise init working):

```swift
struct VADConfig {
    /// Window fed to the detector; Silero's native window at 16 kHz.
    var windowSize: Int = 512
    /// Windows of pre-speech audio retained to recover clipped onsets.
    /// 3 × 512 / 16000 ≈ 96 ms.
    var preSpeechWindows: Int = 3
    /// Energy-fallback RMS threshold (used only by EnergySpeechDetector).
    var energyThreshold: Float = 0.02

    // MARK: - Segmentation (VADSegmenter, Phase 2)

    /// Sustained silence after speech that closes a segment (hangover).
    /// 600 ms keeps natural in-sentence pauses from splitting a segment.
    var minSilenceMs: Int = 600
    /// Minimum speech duration for a segment to count; shorter runs are
    /// treated as noise blips and discarded. ~200 ms.
    var minSpeechMs: Int = 200
    /// Hard cap on a single segment with no pause; forces a cut so no
    /// offline decode ever exceeds the model's short-audio window. 15 s.
    var maxSegmentMs: Int = 15000

    static let `default` = VADConfig()
}
```

- [ ] **Step 2: Confirm the project still builds**

Run: `xcodebuild build -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **` (new fields have defaults; nothing else changes).

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/Services/Audio/VAD/VADSpeechDetector.swift
git commit -m "feat(vad): add segmentation timing fields to VADConfig"
```

---

## Task 2: `VADSegmenter` — failing tests first

**Files:**
- Create: `NemoNoiseTests/VADSegmenterTests.swift`

The segmenter does not exist yet, so these tests will fail to compile first (that is the expected "red"). We use small timing values so window counts stay tiny: at `windowSize = 512` each window is `512/16000 = 32 ms`. With `minSilenceMs = 64` → 2 windows, `minSpeechMs = 32` → 1 window, `maxSegmentMs = 320` → 10 windows, `preSpeechWindows = 2`.

- [ ] **Step 1: Write the failing tests**

Create `NemoNoiseTests/VADSegmenterTests.swift`:

```swift
import XCTest
@testable import NemoNoise

final class VADSegmenterTests: XCTestCase {
    private let W = 512

    /// Small thresholds so tests are short. 32 ms/window.
    private func cfg() -> VADConfig {
        var c = VADConfig()
        c.windowSize = 512
        c.preSpeechWindows = 2
        c.minSilenceMs = 64    // 2 windows
        c.minSpeechMs = 32     // 1 window
        c.maxSegmentMs = 320   // 10 windows
        return c
    }

    private func win(_ v: Float) -> [Float] { [Float](repeating: v, count: 512) }

    func testNonSpeechNeverEmitsSegment() {
        let seg = VADSegmenter(config: cfg())
        for _ in 0..<5 {
            XCTAssertEqual(seg.step(window: win(0.0), isSpeech: false), .buffering)
        }
    }

    func testSpeechThenSilenceEmitsSegment() {
        let seg = VADSegmenter(config: cfg())
        XCTAssertEqual(seg.step(window: win(0.5), isSpeech: true), .buffering)   // onset
        XCTAssertEqual(seg.step(window: win(0.5), isSpeech: true), .buffering)   // 2nd speech
        XCTAssertEqual(seg.step(window: win(0.0), isSpeech: false), .buffering)  // silence 1
        // silence 2 reaches minSilence (2 windows) -> close
        guard case .segment(let samples) = seg.step(window: win(0.0), isSpeech: false) else {
            return XCTFail("expected segment")
        }
        // onset + 2nd speech + 2 silence windows = 4 windows
        XCTAssertEqual(samples.count, 4 * W)
    }

    func testOnsetPrependsPreSpeechBuffer() {
        let seg = VADSegmenter(config: cfg())   // preSpeechWindows = 2
        _ = seg.step(window: win(0.1), isSpeech: false)
        _ = seg.step(window: win(0.2), isSpeech: false)
        _ = seg.step(window: win(0.9), isSpeech: true)   // onset, should prepend 0.1, 0.2
        _ = seg.step(window: win(0.0), isSpeech: false)
        guard case .segment(let s) = seg.step(window: win(0.0), isSpeech: false) else {
            return XCTFail("expected segment")
        }
        // pre(2) + onset(1) + silence(2) = 5 windows
        XCTAssertEqual(s.count, 5 * W)
        XCTAssertEqual(Array(s.prefix(W)), win(0.1))               // first pre-speech window
        XCTAssertEqual(Array(s[W..<2*W]), win(0.2))               // second pre-speech window
        XCTAssertEqual(Array(s[2*W..<3*W]), win(0.9))             // onset window
    }

    func testShortBlipIsDiscarded() {
        // minSpeech requires 3 windows so a single-window blip is rejected.
        var c = cfg(); c.minSpeechMs = 96   // 3 windows
        let s = VADSegmenter(config: c)
        _ = s.step(window: win(0.5), isSpeech: true)   // 1 speech window only
        _ = s.step(window: win(0.0), isSpeech: false)  // silence 1
        // silence 2 closes, but speech (1) < minSpeech (3) -> discard
        XCTAssertEqual(s.step(window: win(0.0), isSpeech: false), .buffering)
    }

    func testInternalPauseDoesNotSplit() {
        let seg = VADSegmenter(config: cfg())   // minSilence = 2 windows
        _ = seg.step(window: win(0.5), isSpeech: true)    // onset
        _ = seg.step(window: win(0.0), isSpeech: false)   // 1 silence (< 2, no split)
        _ = seg.step(window: win(0.5), isSpeech: true)    // speech resumes
        _ = seg.step(window: win(0.0), isSpeech: false)   // silence 1
        guard case .segment(let s) = seg.step(window: win(0.0), isSpeech: false) else {
            return XCTFail("expected single segment")
        }
        XCTAssertEqual(s.count, 5 * W)   // onset + silence + speech + 2 silence
    }

    func testMaxSegmentForceCut() {
        let seg = VADSegmenter(config: cfg())   // maxSegment = 10 windows
        var event: SegmenterEvent = .buffering
        for _ in 0..<10 {
            event = seg.step(window: win(0.5), isSpeech: true)
        }
        guard case .segment(let s) = event else {
            return XCTFail("expected force-cut segment at 10 windows")
        }
        XCTAssertEqual(s.count, 10 * W)
    }

    func testFlushReturnsOpenSegmentThenNil() {
        let seg = VADSegmenter(config: cfg())
        _ = seg.step(window: win(0.5), isSpeech: true)   // onset
        _ = seg.step(window: win(0.5), isSpeech: true)   // 2nd speech, no endpoint
        let flushed = seg.flush()
        XCTAssertEqual(flushed?.count, 2 * W)
        XCTAssertNil(seg.flush())                        // already drained
    }

    func testFlushDiscardsTooShortSegment() {
        var c = cfg(); c.minSpeechMs = 96   // 3 windows
        let seg = VADSegmenter(config: c)
        _ = seg.step(window: win(0.5), isSpeech: true)   // 1 speech window
        XCTAssertNil(seg.flush())                        // < minSpeech -> nil
    }

    func testResetClearsState() {
        let seg = VADSegmenter(config: cfg())
        _ = seg.step(window: win(0.5), isSpeech: true)
        seg.reset()
        XCTAssertNil(seg.flush())
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/VADSegmenterTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `cannot find 'VADSegmenter' in scope` / `cannot find 'SegmenterEvent' in scope`.

- [ ] **Step 3: Commit the tests**

```bash
git add NemoNoiseTests/VADSegmenterTests.swift
git commit -m "test(vad): VADSegmenter state-machine tests (red)"
```

---

## Task 3: `VADSegmenter` — implement to green

**Files:**
- Create: `NemoNoise/Services/Audio/VAD/VADSegmenter.swift`

- [ ] **Step 1: Implement the segmenter**

Create `NemoNoise/Services/Audio/VAD/VADSegmenter.swift`:

```swift
import Foundation

/// One segmentation decision per fixed-size window.
enum SegmenterEvent: Equatable {
    /// Still accumulating the current utterance (or idle in silence).
    case buffering
    /// A completed segment's samples (pre-speech prefix + speech + trailing
    /// hangover silence), ready to decode.
    case segment([Float])
}

/// Pure, IO-free speech segmentation state machine. Given a stream of
/// fixed-size windows tagged speech/non-speech, it accumulates the current
/// utterance and emits a completed segment when an endpoint is reached:
/// sustained silence (`minSilenceMs` hangover) or a `maxSegmentMs` force-cut.
/// Runs shorter than `minSpeechMs` are treated as noise and discarded.
///
/// Durations are counted in *windows*, never wall-clock, so the machine is
/// fully deterministic and unit-testable. Mirrors `VADGate`'s pre-speech
/// onset recovery (96 ms ring buffer) so the leading consonant isn't clipped.
final class VADSegmenter {
    private let windowSize: Int
    private let preSpeechCount: Int
    private let minSilenceWindows: Int
    private let minSpeechWindows: Int
    private let maxSegmentWindows: Int

    private var inSpeech = false
    private var current: [Float] = []
    private var preBuffer: [[Float]] = []
    private var silenceRun = 0
    private var speechWindows = 0
    private var segmentWindows = 0

    init(config: VADConfig = .default) {
        self.windowSize = config.windowSize
        self.preSpeechCount = config.preSpeechWindows
        let windowMs = Double(config.windowSize) / 16000.0 * 1000.0
        func windows(_ ms: Int) -> Int { max(1, Int((Double(ms) / windowMs).rounded(.up))) }
        self.minSilenceWindows = windows(config.minSilenceMs)
        self.minSpeechWindows = windows(config.minSpeechMs)
        self.maxSegmentWindows = windows(config.maxSegmentMs)
    }

    func step(window: [Float], isSpeech: Bool) -> SegmenterEvent {
        if !inSpeech {
            if isSpeech {
                // Onset: open a segment, prepend the pre-speech ring buffer.
                inSpeech = true
                current = preBuffer.flatMap { $0 } + window
                preBuffer.removeAll(keepingCapacity: true)
                silenceRun = 0
                speechWindows = 1
                segmentWindows = current.count / windowSize
                return .buffering
            }
            preBuffer.append(window)
            if preBuffer.count > preSpeechCount {
                preBuffer.removeFirst(preBuffer.count - preSpeechCount)
            }
            return .buffering
        }

        // In speech: always accumulate (keeps trailing offset audio intact).
        current.append(contentsOf: window)
        segmentWindows += 1
        if isSpeech {
            silenceRun = 0
            speechWindows += 1
        } else {
            silenceRun += 1
        }

        if segmentWindows >= maxSegmentWindows { return closeSegment() }
        if silenceRun >= minSilenceWindows { return closeSegment() }
        return .buffering
    }

    /// Flush an in-progress segment at end of recording. Returns nil when no
    /// segment is open or it never had enough speech.
    func flush() -> [Float]? {
        defer { resetSegmentState() }
        guard inSpeech, speechWindows >= minSpeechWindows else { return nil }
        return current
    }

    func reset() {
        resetSegmentState()
        preBuffer.removeAll(keepingCapacity: true)
    }

    private func closeSegment() -> SegmenterEvent {
        defer { resetSegmentState() }
        if speechWindows >= minSpeechWindows { return .segment(current) }
        return .buffering   // noise blip — discard
    }

    private func resetSegmentState() {
        inSpeech = false
        current.removeAll(keepingCapacity: true)
        silenceRun = 0
        speechWindows = 0
        segmentWindows = 0
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/VADSegmenterTests 2>&1 | tail -20`
Expected: all `VADSegmenterTests` PASS.

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/Services/Audio/VAD/VADSegmenter.swift
git commit -m "feat(vad): pure VADSegmenter state machine (onset + endpoint + force-cut)"
```

---

## Task 4: `VADSegmentingEngine` — failing tests first

**Files:**
- Create: `NemoNoiseTests/VADSegmentingEngineTests.swift`

This test file defines two local doubles: `ScriptedDetector` (returns a queued sequence of speech decisions) and `OfflineDecodeSpy` (records fed segments + returns scripted `finish()` text). It uses the same small `VADConfig` window-count math as Task 2.

- [ ] **Step 1: Write the failing tests**

Create `NemoNoiseTests/VADSegmentingEngineTests.swift`:

```swift
import XCTest
@testable import NemoNoise

/// Returns a scripted sequence of speech/non-speech decisions, one per window.
/// After the script is exhausted it returns false (silence).
private final class ScriptedDetector: VADSpeechDetector {
    let windowSize = 512
    var decisions: [Bool]
    private var i = 0
    init(_ decisions: [Bool]) { self.decisions = decisions }
    func isSpeech(_ window: [Float]) -> Bool {
        defer { i += 1 }
        return i < decisions.count ? decisions[i] : false
    }
    func reset() { /* keep index across reset; tests don't rely on it */ }
}

/// Stands in for an offline inner engine. Records each segment fed via
/// `feedChunk` and returns scripted text from `finish()` (FIFO).
private final class OfflineDecodeSpy: ASREngine, @unchecked Sendable {
    let isStreaming = false
    private(set) var resetCount = 0
    private(set) var fedSegments: [[Float]] = []
    var finishTexts: [String] = []
    var finishError: Error?

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        fedSegments.append(samples)
        return TranscriptionResult(text: "", isFinal: false, emotion: nil)
    }
    func finish() async throws -> TranscriptionResult {
        if let e = finishError { throw e }
        let t = finishTexts.isEmpty ? "" : finishTexts.removeFirst()
        return TranscriptionResult(text: t, isFinal: true, emotion: nil)
    }
    func reset() { resetCount += 1 }
}

private struct DummyError: Error {}

final class VADSegmentingEngineTests: XCTestCase {
    private let W = 512

    /// minSilence = 2 windows, minSpeech = 1 window, no pre-speech for clean counts.
    private func cfg() -> VADConfig {
        var c = VADConfig()
        c.windowSize = 512
        c.preSpeechWindows = 0
        c.minSilenceMs = 64      // 2 windows
        c.minSpeechMs = 32       // 1 window
        c.maxSegmentMs = 3200    // 100 windows
        return c
    }

    /// n consecutive 512-sample windows (sample values are irrelevant — the
    /// detector is scripted, not analyzing audio).
    private func samples(_ n: Int) -> [Float] { [Float](repeating: 0.5, count: n * 512) }

    func testIsStreamingReportsTrue() {
        // Reports true so the overlay shows the progressive text it now emits,
        // even though the inner engine is offline.
        let engine = VADSegmentingEngine(
            inner: OfflineDecodeSpy(),
            detector: ScriptedDetector([]),
            config: cfg()
        )
        XCTAssertTrue(engine.isStreaming)
    }

    func testBufferingReturnsEmptyPartialAndNoDecode() async throws {
        let spy = OfflineDecodeSpy()
        let engine = VADSegmentingEngine(inner: spy, detector: ScriptedDetector([false]), config: cfg())
        let r = try await engine.feedChunk(samples(1), sampleRate: 16000)
        XCTAssertEqual(r.text, "")
        XCTAssertFalse(r.isFinal)
        XCTAssertEqual(spy.fedSegments.count, 0)
    }

    func testSegmentCommitDecodesAndEmitsFinal() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["你好"]
        // speech, silence, silence -> closes one segment (3 windows)
        let detector = ScriptedDetector([true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r.text, "你好")
        XCTAssertTrue(r.isFinal)
        XCTAssertEqual(spy.resetCount, 1)
        XCTAssertEqual(spy.fedSegments.count, 1)
        XCTAssertEqual(spy.fedSegments[0].count, 3 * W)   // onset + 2 silence, no pre-speech
    }

    func testTwoSegmentsAcrossChunksEmitProgressively() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["A", "B"]
        let detector = ScriptedDetector([true, false, false, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r1 = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r1.text, "A")
        XCTAssertTrue(r1.isFinal)

        let r2 = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r2.text, "B")
        XCTAssertTrue(r2.isFinal)
        XCTAssertEqual(spy.fedSegments.count, 2)
    }

    func testMultipleSegmentsInOneChunkAreJoined() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["A", "B"]
        let detector = ScriptedDetector([true, false, false, true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let r = try await engine.feedChunk(samples(6), sampleRate: 16000)
        XCTAssertEqual(r.text, "A B")
        XCTAssertTrue(r.isFinal)
    }

    func testFinishFlushesTrailingSegment() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishTexts = ["tail"]
        let detector = ScriptedDetector([true, true])   // open segment, no endpoint
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        let partial = try await engine.feedChunk(samples(2), sampleRate: 16000)
        XCTAssertEqual(partial.text, "")        // still buffering
        let final = try await engine.finish()
        XCTAssertEqual(final.text, "tail")
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(spy.fedSegments.count, 1)
        XCTAssertEqual(spy.fedSegments[0].count, 2 * W)
    }

    func testSegmentDecodeFailureIsSwallowed() async throws {
        let spy = OfflineDecodeSpy()
        spy.finishError = DummyError()
        let detector = ScriptedDetector([true, false, false])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())

        // Must NOT throw; the bad segment yields no text, session continues.
        let r = try await engine.feedChunk(samples(3), sampleRate: 16000)
        XCTAssertEqual(r.text, "")
        XCTAssertFalse(r.isFinal)
    }

    func testResetClearsSegmenterAndInner() async throws {
        let spy = OfflineDecodeSpy()
        let detector = ScriptedDetector([true, true])
        let engine = VADSegmentingEngine(inner: spy, detector: detector, config: cfg())
        _ = try await engine.feedChunk(samples(2), sampleRate: 16000)   // open segment

        engine.reset()
        // After reset, finish() finds no open segment -> empty final.
        let final = try await engine.finish()
        XCTAssertEqual(final.text, "")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/VADSegmentingEngineTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `cannot find 'VADSegmentingEngine' in scope`.

- [ ] **Step 3: Commit the tests**

```bash
git add NemoNoiseTests/VADSegmentingEngineTests.swift
git commit -m "test(asr): VADSegmentingEngine decode-per-segment tests (red)"
```

---

## Task 5: `VADSegmentingEngine` — implement to green

**Files:**
- Create: `NemoNoise/Services/ASR/VADSegmentingEngine.swift`

- [ ] **Step 1: Implement the decorator**

Create `NemoNoise/Services/ASR/VADSegmentingEngine.swift`:

```swift
import Foundation

/// `ASREngine` decorator that turns a non-streaming offline engine
/// (Qwen3 / SenseVoice) into a progressively-emitting one. It slices the audio
/// stream into 512-sample windows, asks the Silero detector whether each is
/// speech, runs `VADSegmenter`, and decodes each completed segment through the
/// wrapped `inner` engine. Each decoded segment is returned as an `isFinal`
/// result — the same contract a streaming engine uses at an endpoint — so the
/// existing `OverlayProgressSink` / `confirmedSegments` machinery accumulates
/// it, and `RecordingController` injects the joined segments unchanged.
///
/// Reports `isStreaming == true` so `OverlayView.shouldShowTranscript` displays
/// the progressive text, even though `inner` is offline.
///
/// `@unchecked Sendable`: all mutable state is touched only from the single
/// pump task that drives `feedChunk` inside `TranscriptionPipeline` (same
/// contract as `VADGatedSource`); `feedChunk` is never called concurrently.
/// Per-segment decodes are therefore naturally serialized — the pipeline
/// awaits each `feedChunk` before pulling the next chunk, while `MicAudioSource`
/// keeps buffering incoming audio into its `AsyncStream` so nothing is lost.
final class VADSegmentingEngine: ASREngine, @unchecked Sendable {
    private let inner: any ASREngine
    private let detector: any VADSpeechDetector
    private let segmenter: VADSegmenter
    private let windowSize: Int
    private var leftover: [Float] = []

    let isStreaming = true

    init(inner: any ASREngine, detector: any VADSpeechDetector, config: VADConfig = .default) {
        self.inner = inner
        self.detector = detector
        self.segmenter = VADSegmenter(config: config)
        self.windowSize = config.windowSize
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        leftover.append(contentsOf: samples)
        var pieces: [String] = []
        while leftover.count >= windowSize {
            let window = Array(leftover.prefix(windowSize))
            leftover.removeFirst(windowSize)
            let isSpeech = detector.isSpeech(window)
            if case .segment(let seg) = segmenter.step(window: window, isSpeech: isSpeech) {
                let text = await decodeSegment(seg)
                if !text.isEmpty { pieces.append(text) }
            }
        }
        guard !pieces.isEmpty else {
            return TranscriptionResult(text: "", isFinal: false, emotion: nil)
        }
        return TranscriptionResult(text: pieces.joined(separator: " "), isFinal: true, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        defer { reset() }
        if let seg = segmenter.flush() {
            let text = await decodeSegment(seg)
            return TranscriptionResult(text: text, isFinal: true, emotion: nil)
        }
        return TranscriptionResult(text: "", isFinal: true, emotion: nil)
    }

    func reset() {
        leftover.removeAll(keepingCapacity: true)
        segmenter.reset()
        detector.reset()
        inner.reset()
    }

    /// Decode one segment through the inner offline engine via the standard
    /// ASREngine contract. A failed decode is logged and skipped (returns "")
    /// so one bad segment never ends the session.
    private func decodeSegment(_ samples: [Float]) async -> String {
        inner.reset()
        _ = try? await inner.feedChunk(samples, sampleRate: 16000)
        do {
            return try await inner.finish().text
        } catch {
            LogService.warn("Segment decode failed: \(error)", category: "VADSegmentingEngine")
            return ""
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/VADSegmentingEngineTests 2>&1 | tail -20`
Expected: all `VADSegmentingEngineTests` PASS.

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/Services/ASR/VADSegmentingEngine.swift
git commit -m "feat(asr): VADSegmentingEngine — progressive decode of VAD-cut segments"
```

---

## Task 6: Wire offline engines through `VADSegmentingEngine` in `PipelineProvider`

**Files:**
- Modify: `NemoNoise/App/PipelineProvider.swift:95-126` (the `applyDictation` success branch)
- Modify: `NemoNoise/App/PipelineProvider.swift:167-188` (replace `makeGatedMicSource` with `makeDetector` + `makeMicSource`)

- [ ] **Step 1: Split `makeGatedMicSource` into `makeDetector` + `makeMicSource`**

In `NemoNoise/App/PipelineProvider.swift`, replace the entire `// MARK: - Gated mic source` section (the `makeGatedMicSource()` method, currently lines 167-188) with:

```swift
    // MARK: - Dictation source pieces

    /// Builds the VAD detector: Silero when its model is downloaded, otherwise
    /// the energy fallback (still better than no VAD), logging the degradation.
    /// A fresh detector per pipeline build — Silero state is per-session.
    private func makeDetector() -> any VADSpeechDetector {
        if let dir = modelManager.modelPath(for: .sileroVad),
           let silero = SileroSpeechDetector(modelPath: dir.appendingPathComponent("silero_vad.onnx").path) {
            LogService.info("Dictation VAD: Silero", category: "PipelineProvider")
            return silero
        }
        LogService.warn("Silero VAD model unavailable; using energy gate", category: "PipelineProvider")
        return EnergySpeechDetector()
    }

    /// The raw mic source with the audio-interruption hook wired to the
    /// recording controller.
    private func makeMicSource() -> MicAudioSource {
        MicAudioSource(onInterruption: { [weak recordingController] reason in
            Task { @MainActor in
                recordingController?.handleAudioInterruption(reason)
            }
        })
    }
```

- [ ] **Step 2: Branch the dictation wiring by engine type**

In the `applyDictation(...)` method, inside `case .success(let build):` and `if let recordingController {`, the current code constructs the pipeline like this (lines ~96-107):

```swift
            if let recordingController {
                let postProcessors: [any PostProcessor] = punctuator.map {
                    [PunctuationProcessor(punctuator: $0)]
                } ?? []
                let pipeline = TranscriptionPipeline(
                    source: makeGatedMicSource(),
                    engine: build.engine,
                    postProcessors: postProcessors,
                    sink: OverlayProgressSink(target: recordingController),
                    fallback: fallback
                )
                recordingController.bind(pipeline: pipeline, mutex: mutex)
```

Replace that block (down to and including the `bind` call) with:

```swift
            if let recordingController {
                let postProcessors: [any PostProcessor] = punctuator.map {
                    [PunctuationProcessor(punctuator: $0)]
                } ?? []

                // Offline engines (Qwen3 / SenseVoice) decode in one shot at
                // finish(), so they get the segmenting decorator that cuts at
                // pauses and decodes each short segment progressively. Streaming
                // engines (Paraformer / Apple) keep the Phase-1 gated source —
                // its silence-injection preserves their own endpoint detection.
                let source: any AudioSource
                let engine: any ASREngine
                if build.engine.isStreaming {
                    source = VADGatedSource(inner: makeMicSource(), detector: makeDetector())
                    engine = build.engine
                } else {
                    source = makeMicSource()
                    engine = VADSegmentingEngine(inner: build.engine, detector: makeDetector())
                }

                let pipeline = TranscriptionPipeline(
                    source: source,
                    engine: engine,
                    postProcessors: postProcessors,
                    sink: OverlayProgressSink(target: recordingController),
                    fallback: fallback
                )
                recordingController.bind(pipeline: pipeline, mutex: mutex)
```

- [ ] **Step 3: Build and run the full suite to confirm no regression**

Run: `xcodebuild test -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -40`
Expected: `** TEST SUCCEEDED **`. Pay attention to `PipelineProviderTests` and the existing VAD tests (`VADGateTests`, `VADGatedSourceTests`) — they must still pass. The `makeGatedMicSource` removal compiles because no test referenced the private method.

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/App/PipelineProvider.swift
git commit -m "feat(pipeline): route offline dictation engines through VADSegmentingEngine"
```

---

## Task 7: Manual device QA

No automated test can verify real-audio behavior. With the Qwen3 model selected in Settings, verify on a real Mac:

- [ ] **Step 1: Progressive output** — Hold the dictation hotkey and speak 3–4 sentences with natural pauses. Confirm text appears in the overlay **at each pause** (not only after release). The wait after releasing the key is only the last segment's decode.
- [ ] **Step 2: Accuracy on long speech** — Dictate a multi-sentence paragraph. Confirm common-character garbling is markedly reduced versus the pre-change single-shot decode (each segment now stays within the model's short-audio window).
- [ ] **Step 3: First syllable not clipped** — Start speaking immediately on key-down; confirm the leading consonant survives (pre-speech buffer).
- [ ] **Step 4: No long-recording stutter / memory growth** — Dictate continuously for 60+ seconds; confirm it stays responsive (the `maxSegmentMs` force-cut bounds any single decode).
- [ ] **Step 5: Streaming path unchanged** — Switch to Paraformer and to Apple; confirm their live behavior and "speak-then-auto-finalize" are unchanged (they still use `VADGatedSource`).
- [ ] **Step 6: No-model degradation** — (Optional) With the Silero model absent, confirm offline dictation still works via the energy detector and doesn't crash.

- [ ] **Step 7: Final commit (if any QA-driven tuning was needed)**

If QA reveals a timing default needs adjustment (e.g. `minSilenceMs` too long/short), change only the default in `VADConfig` and commit:

```bash
git add NemoNoise/Services/Audio/VAD/VADSpeechDetector.swift
git commit -m "tune(vad): adjust segmentation timing after device QA"
```

---

## Self-Review (completed during planning)

**Spec coverage:**
- §2 `VADSegmenter` → Tasks 2–3. ✅
- §2 `VADSegmentingEngine` (decode-per-segment, serialized, swallow failures) → Tasks 4–5. ✅
- §2 `VADConfig` new fields → Task 1. ✅
- §3 wiring branch by engine type, offline drops `VADGatedSource`, append-committed output → Task 6 (per-segment `isFinal` → `confirmedSegments`). ✅
- §3 progressive display → `isStreaming = true` (Task 5) so `OverlayView.shouldShowTranscript` shows it. ✅
- §4 minSilence/minSpeech/maxSegment/pre-speech defaults + per-segment failure skip → Tasks 1, 3, 5. ✅
- §6 testing (pure segmenter tests, decorator tests with mock inner + scripted detector, manual QA) → Tasks 2, 4, 7. ✅
- §8 fp16 lever — out of scope, documented follow-up only. ✅

**Placeholder scan:** none — every code/test step contains full code and exact commands.

**Type consistency:** `SegmenterEvent` (`.buffering` / `.segment([Float])`), `VADSegmenter.step/flush/reset`, `VADSegmentingEngine.init(inner:detector:config:)`, `VADConfig.{minSilenceMs,minSpeechMs,maxSegmentMs}`, and the `decodeSegment` `reset → feedChunk → finish` contract are used identically across all tasks and tests.
