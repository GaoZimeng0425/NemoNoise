import AVFoundation
import os

struct AudioChunk: Sendable {
    let samples: [Float]
    let rmsLevel: Float
}

final class AudioCapture: Sendable {
    private let engine = AVAudioEngine()
    private let continuation: ContinuationBox = ContinuationBox()
    private let targetSampleRate: Double = 16000

    func start() async throws -> AsyncStream<AudioChunk> {
        try await requestMicrophoneAccess()

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0 else {
            throw ASRError.audioCaptureFailed("No audio input device available")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ASRError.audioCaptureFailed("Failed to create target audio format")
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw ASRError.audioCaptureFailed("Failed to create sample rate converter")
        }

        let stream = AsyncStream<AudioChunk> { [continuation] c in
            continuation.value = c
            c.onTermination = { [weak self] _ in self?.stopEngine() }
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }

        try engine.start()
        LogService.info("Engine started, sample rate: \(hardwareFormat.sampleRate)", category: "AudioCapture")
        return stream
    }

    func stop() {
        continuation.value?.finish()
        continuation.value = nil
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        LogService.info("Engine stopped", category: "AudioCapture")
    }

    nonisolated private func processTap(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let inputFrameCount = buffer.frameLength
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputFrameCount) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

        var inputConsumed = false
        let status = converter.convert(to: outputBuffer, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let channelData = outputBuffer.floatChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(frameLength))

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

// AsyncStream.Continuation is not Sendable, wrap it to cross isolation boundaries safely
final class ContinuationBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<AsyncStream<AudioChunk>.Continuation?>(initialState: nil)
    var value: AsyncStream<AudioChunk>.Continuation? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
