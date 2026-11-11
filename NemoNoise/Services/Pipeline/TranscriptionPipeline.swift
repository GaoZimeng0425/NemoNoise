import Foundation
import os

/// Composes audio source + ASR engine + optional post-processors + sink into a
/// runnable transcription session.
///
/// Single-session: create a fresh instance per recording (the expensive parts
/// — ONNX engines — live in the provider's pool and are shared; only this
/// cheap shell plus the audio source are per-session). A used instance is
/// discarded after `finalize()`/`stop()`, so a late callback from a finished
/// session can never touch a newer one.
@MainActor
final class TranscriptionPipeline {
    private let source: any AudioSource
    private let primaryEngine: any ASREngine
    private let postProcessors: [any PostProcessor]
    private let sink: any Sink
    private let fallback: (any ASREngine)?
    private let engineBox: EngineBox
    /// Session audio clock; the pump task and `finalize()` touch it in turn.
    private let clock = OSAllocatedUnfairLock(initialState: UtteranceClock())
    private let now: @Sendable () -> Date

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
        fallback: (any ASREngine)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.primaryEngine = engine
        self.postProcessors = postProcessors
        self.sink = sink
        self.fallback = fallback
        self.engineBox = EngineBox(engine: engine)
        self.now = now
    }

    var isStreaming: Bool { engineBox.engine.isStreaming }

    /// Begin the session. Call once per instance.
    func start() -> AsyncThrowingStream<PipelineEvent, Error> {
        engineBox.engine = primaryEngine
        return AsyncThrowingStream<PipelineEvent, Error> { continuation in
            // If the consumer goes away (its task is cancelled or the stream
            // is dropped), stop the audio source so no microphone stays live.
            // No session token needed: this instance belongs to exactly one
            // session, and it is discarded afterwards.
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                let source = self.source
                Task { @MainActor in
                    source.stop()
                }
            }

            // Capture everything needed for the inner loop as nonisolated copies.
            let source = self.source
            let sink = self.sink
            let postProcessors = self.postProcessors
            let fallbackEngine = self.fallback
            let engineBox = self.engineBox
            let clock = self.clock
            let now = self.now
            let originalEngineName = String(describing: type(of: self.primaryEngine))

            self.primaryEngine.reset()

            let task = Task.detached {
                do {
                    let audioStream = try await source.start()
                    var usingFallback = false

                    for await chunk in audioStream {
                        let engine = engineBox.engine
                        let chunkStart = clock.withLock { $0.beginChunk(sampleCount: chunk.samples.count, now: now()) }
                        do {
                            var result = try await engine.feedChunk(chunk.samples, sampleRate: 16000)
                            let engineStart = result.audioStart
                            let enginePause = result.pauseBefore
                            for proc in postProcessors {
                                if let next = try await proc.process(result, isFinal: result.isFinal) {
                                    result = next
                                }
                            }
                            let processed = result
                            result = clock.withLock {
                                $0.stamp(processed, engineStart: engineStart, chunkStart: chunkStart,
                                         pauseBefore: enginePause)
                            }
                            await sink.deliver(result, isFinal: result.isFinal)
                            if result.text.isEmpty {
                                continuation.yield(.level(rms: chunk.rmsLevel, spectrum: chunk.spectrum))
                            } else if result.isFinal {
                                continuation.yield(.final(result))
                            } else {
                                continuation.yield(.partial(result, rms: chunk.rmsLevel, spectrum: chunk.spectrum))
                            }
                        } catch where !usingFallback && fallbackEngine != nil {
                            // The failing chunk is dropped; subsequent chunks go through the fallback.
                            usingFallback = true
                            engineBox.engine = fallbackEngine!
                            await engineBox.engine.reset()
                            continuation.yield(.engineFallback(from: originalEngineName))
                        } catch {
                            continuation.finish(throwing: PipelineError.engineFailedFatally(underlying: error))
                            return
                        }
                    }
                    // Do NOT finish the continuation here — finalize() is responsible for
                    // yielding .final and closing the stream after engine.finish().
                } catch {
                    continuation.finish(throwing: PipelineError.sourceUnavailable(underlying: error))
                }
            }
            self.state = .running(continuation: continuation, task: task)
        }
    }

    /// End the session, draining tail audio and returning the final result.
    func finalize() async throws -> TranscriptionResult {
        let runningInfo: (AsyncThrowingStream<PipelineEvent, Error>.Continuation, Task<Void, Never>)?
        switch state {
        case .running(let cont, let task):
            runningInfo = (cont, task)
        case .idle, .finalizing:
            runningInfo = nil
        }

        state = .finalizing

        source.stop()
        await runningInfo?.1.value

        let engine = currentEngine()
        do {
            var result = try await engine.finish()
            let engineStart = result.audioStart
            let enginePause = result.pauseBefore
            for proc in postProcessors {
                if let next = try await proc.process(result, isFinal: true) {
                    result = next
                }
            }
            let processed = result
            result = clock.withLock {
                $0.stamp(processed, engineStart: engineStart, chunkStart: $0.fedSeconds,
                         pauseBefore: enginePause)
            }
            await sink.deliver(result, isFinal: true)
            runningInfo?.0.yield(.final(result))
            runningInfo?.0.finish()
            state = .idle
            return result
        } catch {
            // Close the event stream normally so the pipelineTask's for-await
            // exits cleanly. The caller of finalize() is the single place that
            // surfaces this failure to the user — finishing the stream with a
            // throw here would fire handlePipelineError twice.
            runningInfo?.0.finish()
            state = .idle
            throw PipelineError.finalizeFailed(underlying: error)
        }
    }

    /// Abort without finalizing. Async because the pump task may still be
    /// mid-`feedChunk` when cancelled; waiting for it to drain guarantees a
    /// rapid stop→start cycle on the same (reused) pipeline can't feed stale
    /// chunks into the freshly reset engine.
    func stop() async {
        switch state {
        case .running(let cont, let task):
            source.stop()
            task.cancel()
            cont.finish()
            await task.value
        case .idle, .finalizing:
            break
        }
        state = .idle
    }

    private func currentEngine() -> any ASREngine { engineBox.engine }
}

/// When each line was spoken, on the session's audio timeline. Pure value
/// type driven by the pump: it counts the audio fed, notes where the current
/// utterance first produced text, and stamps each final with its start — the
/// engine's own value when it knows it (Apple, VAD segments), else the first
/// partial's chunk, else the end of the previous line.
nonisolated struct UtteranceClock {
    private(set) var fedSeconds: TimeInterval = 0
    private var firstAudioAt: Date?
    private var openedAt: TimeInterval?
    private var lastLineEnd: TimeInterval = 0

    /// Account for one chunk arriving at `now`; returns where it starts on
    /// the audio timeline. The first chunk anchors the wall clock (minus its
    /// own duration: it arrives once captured).
    mutating func beginChunk(sampleCount: Int, now: Date) -> TimeInterval {
        let start = fedSeconds
        let duration = Double(sampleCount) / 16000
        if firstAudioAt == nil { firstAudioAt = now.addingTimeInterval(-duration) }
        fedSeconds += duration
        return start
    }

    mutating func stamp(_ result: TranscriptionResult, engineStart: TimeInterval?,
                        chunkStart: TimeInterval, pauseBefore: TimeInterval? = nil) -> TranscriptionResult {
        guard !result.text.isEmpty else { return result }
        guard result.isFinal else {
            if openedAt == nil { openedAt = chunkStart }
            return result
        }
        let start = engineStart ?? openedAt ?? lastLineEnd
        openedAt = nil
        lastLineEnd = fedSeconds
        return result.stamped(audioStart: start, spokenAt: firstAudioAt?.addingTimeInterval(start),
                              pauseBefore: pauseBefore)
    }
}

/// Sendable box to allow engine swapping inside a detached Task. Locked because
/// the pump task swaps in the fallback while the main actor may read it.
nonisolated private final class EngineBox: Sendable {
    private let current: OSAllocatedUnfairLock<any ASREngine>
    init(engine: any ASREngine) { current = OSAllocatedUnfairLock(initialState: engine) }
    var engine: any ASREngine {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}

enum PipelineError: Error {
    case sourceUnavailable(underlying: Error)
    case engineFailedFatally(underlying: Error)
    case finalizeFailed(underlying: Error)
}
