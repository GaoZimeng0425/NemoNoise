import AVFoundation
import os

struct AudioChunk: Sendable {
    let samples: [Float]
    let rmsLevel: Float
}

final class MicAudioSource: Sendable {
    private let engine = AVAudioEngine()
    private let continuation: ContinuationBox = ContinuationBox()
    private let targetSampleRate: Double = 16000
    private let bufferSize: AVAudioFrameCount = 4096

    func start() async throws -> AsyncStream<AudioChunk> {
        try await requestMicrophoneAccess()

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0 else {
            throw ASRError.audioCaptureFailed("No audio input device available")
        }

        LogService.info("Audio device: sampleRate=\(hardwareFormat.sampleRate), channels=\(hardwareFormat.channelCount), bufferSize=\(bufferSize)", category: "AudioCapture")

        guard let resampler = AudioResampler(sourceRate: hardwareFormat.sampleRate, targetRate: targetSampleRate) else {
            throw ASRError.audioCaptureFailed("Failed to create sample rate converter")
        }

        let stream = AsyncStream<AudioChunk> { [continuation] c in
            continuation.value = c
            c.onTermination = { [weak self] _ in self?.stopEngine() }
        }

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer, resampler: resampler)
        }

        try engine.start()
        LogService.info("Capture started, converting \(hardwareFormat.sampleRate)Hz -> \(targetSampleRate)Hz", category: "AudioCapture")
        return stream
    }

    func stop() {
        continuation.value?.finish()
        continuation.value = nil
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        LogService.info("Capture stopped", category: "AudioCapture")
    }

    nonisolated private func processTap(buffer: AVAudioPCMBuffer, resampler: AudioResampler) {
        guard let samples = resampler.resample(buffer: buffer) else { return }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        continuation.value?.yield(AudioChunk(samples: samples, rmsLevel: rms))
    }

    private func requestMicrophoneAccess() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw ASRError.audioCaptureFailed("Microphone access denied") }
        case .denied, .restricted:
            throw ASRError.audioCaptureFailed("Microphone access denied — enable in System Settings → Privacy → Microphone")
        @unknown default:
            throw ASRError.audioCaptureFailed("Unknown microphone authorization status")
        }
    }
}
