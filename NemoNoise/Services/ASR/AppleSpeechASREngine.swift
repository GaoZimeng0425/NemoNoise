import Speech
import AVFoundation
import os

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

final class AppleSpeechASREngine: ASREngine, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private struct State {
        var partialText: String = ""
        var queue: AppleSpeechFinalQueue = AppleSpeechFinalQueue()
        var finishContinuation: CheckedContinuation<TranscriptionResult, Error>?
        var pendingError: Error?
    }
    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    init(locale: String? = nil) throws {
        let pref = LanguagePreference.current
        let start = ContinuousClock.now
        let resolved: SFSpeechRecognizer?

        if let localeId = locale ?? pref.localeIdentifier {
            resolved = SFSpeechRecognizer(locale: Locale(identifier: localeId))
                ?? SFSpeechRecognizer(locale: .current)
                ?? SFSpeechRecognizer()
        } else {
            resolved = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
                ?? SFSpeechRecognizer(locale: .current)
                ?? SFSpeechRecognizer()
        }

        guard let resolved else {
            LogService.error("SFSpeechRecognizer unavailable for locale: \(pref.localeIdentifier ?? "nil")", category: "ASR")
            throw ASRError.engineUnavailable
        }
        recognizer = resolved
        let elapsed = ContinuousClock.now - start
        LogService.info("locale: \(recognizer.locale.identifier), init duration: \(elapsed.description)", category: "AppleSpeechASREngine")
    }

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
                    // "No speech detected" is normal when the user holds the
                    // hotkey but doesn't talk. Don't surface it as an error —
                    // resolve as an empty final result so the UI just closes.
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

    func reset() {
        task?.cancel()
        task = nil
        request = nil
        stateLock.withLock { state in state = State() }
    }

    private func makePCMBuffer(from samples: [Float], sampleRate: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }
        let count = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        buffer.frameLength = count
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress, let channelData = buffer.floatChannelData else { return }
            channelData[0].update(from: base, count: samples.count)
        }
        return buffer
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
