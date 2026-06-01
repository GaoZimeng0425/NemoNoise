import Foundation

/// Composes audio source + ASR engine + optional post-processors + sink into a
/// runnable transcription session. Reusable: a single pipeline instance can be
/// `start`ed and `finalize`d (or `stop`ped) multiple times.
@MainActor
final class TranscriptionPipeline {
    private let source: any AudioSource
    private let primaryEngine: any ASREngine
    private let postProcessors: [any PostProcessor]
    private let sink: any Sink
    private let fallback: (any ASREngine)?
    private let engineBox: EngineBox

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
        self.engineBox = EngineBox(engine: engine)
    }

    var isStreaming: Bool { engineBox.engine.isStreaming }

    /// Begin a new session.
    func start() -> AsyncThrowingStream<PipelineEvent, Error> {
        engineBox.engine = primaryEngine
        return AsyncThrowingStream<PipelineEvent, Error> { continuation in
            // Capture everything needed for the inner loop as nonisolated copies.
            let source = self.source
            let sink = self.sink
            let postProcessors = self.postProcessors
            let fallbackEngine = self.fallback
            let engineBox = self.engineBox
            let originalEngineName = String(describing: type(of: self.primaryEngine))

            self.primaryEngine.reset()

            let task = Task.detached {
                do {
                    let audioStream = try await source.start()
                    var usingFallback = false

                    for await chunk in audioStream {
                        let engine = engineBox.engine
                        do {
                            var result = try await engine.feedChunk(chunk.samples, sampleRate: 16000)
                            for proc in postProcessors {
                                if let next = try await proc.process(result, isFinal: result.isFinal) {
                                    result = next
                                }
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
                            engineBox.engine.reset()
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

    /// Abort without finalizing.
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

    private func currentEngine() -> any ASREngine { engineBox.engine }
}

/// Sendable box to allow engine swapping inside a detached Task.
private final class EngineBox: @unchecked Sendable {
    var engine: any ASREngine
    init(engine: any ASREngine) { self.engine = engine }
}

enum PipelineError: Error {
    case sourceUnavailable(underlying: Error)
    case engineFailedFatally(underlying: Error)
    case finalizeFailed(underlying: Error)
}
