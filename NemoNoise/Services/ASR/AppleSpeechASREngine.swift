import Speech
import AVFoundation
import os

final class AppleSpeechASREngine: ASRService, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private struct State {
        var partialText: String = ""
        var finalResult: TranscriptionResult?
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
            if #available(macOS 14, *) {
                req.addsPunctuation = true
            }
            request = req

            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    let cont = self.stateLock.withLock { state -> CheckedContinuation<TranscriptionResult, Error>? in
                        state.pendingError = error
                        let cont = state.finishContinuation
                        state.finishContinuation = nil
                        return cont
                    }
                    cont?.resume(throwing: error)
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
                            state.finalResult = transcription
                            let cont = state.finishContinuation
                            state.finishContinuation = nil
                            return cont
                        }
                        cont?.resume(returning: transcription)
                    } else {
                        self.stateLock.withLock { $0.partialText = result.bestTranscription.formattedString }
                    }
                }
            }
        }

        if let buffer = makePCMBuffer(from: samples, sampleRate: sampleRate) {
            request?.append(buffer)
        }

        let partial = stateLock.withLock { $0.partialText }
        return TranscriptionResult(text: partial, isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        request?.endAudio()

        let snapshot = stateLock.withLock { state -> (TranscriptionResult?, Error?) in
            (state.finalResult, state.pendingError)
        }
        if let error = snapshot.1 {
            LogService.error("Recognition failed: \(error.localizedDescription)", category: "AppleSpeechASREngine")
            throw error
        }
        if let final = snapshot.0 {
            stateLock.withLock { $0.finalResult = nil }
            LogService.info("Recognition complete, length: \(final.text.count) chars", category: "AppleSpeechASREngine")
            return final
        }

        if task != nil {
            return try await withCheckedThrowingContinuation { continuation in
                let resolved = self.stateLock.withLock { state -> (TranscriptionResult?, Error?) in
                    if let error = state.pendingError {
                        state.pendingError = nil
                        return (nil, error)
                    }
                    if let final = state.finalResult {
                        state.finalResult = nil
                        return (final, nil)
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
