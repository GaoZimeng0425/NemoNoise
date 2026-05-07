import Speech
import AVFoundation

final class AppleSpeechASREngine: ASRService, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private var accumulated: [Float] = []

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
        accumulated.append(contentsOf: samples)
        return TranscriptionResult(text: "", isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        defer { accumulated.removeAll() }
        guard !accumulated.isEmpty else {
            return TranscriptionResult(text: "", isFinal: true, emotion: nil)
        }
        guard await requestPermission() else {
            throw ASRError.audioCaptureFailed("Speech recognition permission denied")
        }
        guard recognizer.isAvailable else {
            throw ASRError.audioCaptureFailed("Speech recognizer not available")
        }
        guard let buffer = makePCMBuffer(from: accumulated, sampleRate: 16000) else {
            return TranscriptionResult(text: "", isFinal: true, emotion: nil)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                resumed = true
                continuation.resume(returning: TranscriptionResult(
                    text: result.bestTranscription.formattedString,
                    isFinal: true,
                    emotion: nil
                ))
            }
        }
    }

    func reset() {
        accumulated.removeAll()
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
