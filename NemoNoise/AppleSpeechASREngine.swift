import Speech
import AVFoundation
import os

final class AppleSpeechASREngine: ASRService, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishContinuation: CheckedContinuation<TranscriptionResult, Error>?
    private let partialLock = OSAllocatedUnfairLock(initialState: "")
    private var finalResult: TranscriptionResult?

    init() throws {
        let pref = LanguagePreference.current
        let resolved: SFSpeechRecognizer?

        if let localeId = pref.localeIdentifier {
            resolved = SFSpeechRecognizer(locale: Locale(identifier: localeId))
                ?? SFSpeechRecognizer(locale: .current)
                ?? SFSpeechRecognizer()
        } else {
            resolved = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
                ?? SFSpeechRecognizer(locale: .current)
                ?? SFSpeechRecognizer()
        }

        guard let resolved else {
            throw ASRError.engineUnavailable
        }
        recognizer = resolved
        LogService.info("locale: \(recognizer.locale.identifier)", category: "AppleSpeechASREngine")
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
            request = req

            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    if let cont = self.finishContinuation {
                        self.finishContinuation = nil
                        cont.resume(throwing: error)
                    }
                    return
                }
                if let result {
                    if result.isFinal {
                        let transcription = TranscriptionResult(
                            text: result.bestTranscription.formattedString,
                            isFinal: true,
                            emotion: nil
                        )
                        self.finalResult = transcription
                        if let cont = self.finishContinuation {
                            self.finishContinuation = nil
                            cont.resume(returning: transcription)
                        }
                    } else {
                        self.partialLock.withLock { partial in
                            partial = result.bestTranscription.formattedString
                        }
                    }
                }
            }
        }

        if let buffer = makePCMBuffer(from: samples, sampleRate: sampleRate) {
            request?.append(buffer)
        }

        let partial = partialLock.withLock { $0 }
        return TranscriptionResult(text: partial, isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        if let final = finalResult {
            finalResult = nil
            return final
        }

        request?.endAudio()

        if task != nil {
            return try await withCheckedThrowingContinuation { continuation in
                self.finishContinuation = continuation
            }
        }

        return TranscriptionResult(text: "", isFinal: true, emotion: nil)
    }

    func reset() {
        task?.cancel()
        task = nil
        request = nil
        finishContinuation = nil
        finalResult = nil
        partialLock.withLock { $0 = "" }
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
