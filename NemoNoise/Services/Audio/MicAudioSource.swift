import AVFoundation
import os

struct AudioChunk: Sendable {
    let samples: [Float]
    let rmsLevel: Float
    let spectrum: [Float]
}

final class MicAudioSource: AudioSource, Sendable {
    private let engine = AVAudioEngine()
    private let continuation: ContinuationBox = ContinuationBox()
    private let targetSampleRate: Double = 16000
    private let bufferSize: AVAudioFrameCount = 4096
    private let analyzer = SpectrumAnalyzer(binCount: 16, sampleRate: 16000)

    func start() async throws -> AsyncStream<AudioChunk> {
        try await requestMicrophoneAccess()

        let inputNode = engine.inputNode
        applyPreferredInputDevice(to: inputNode)
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
        let spectrum = analyzer.analyze(samples)
        continuation.value?.yield(AudioChunk(samples: samples, rmsLevel: rms, spectrum: spectrum))
    }

    /// Reads `AppDefaults.Keys.preferredMicUID` and pins the input audio unit
    /// to that device if it resolves. Any failure falls back silently to the
    /// system default — recording must always work.
    private func applyPreferredInputDevice(to inputNode: AVAudioInputNode) {
        let uid = UserDefaults.standard.string(forKey: AppDefaults.Keys.preferredMicUID) ?? ""
        guard !uid.isEmpty else { return }
        guard let deviceID = AudioInputDeviceCatalog.deviceID(forUID: uid) else {
            LogService.info("Preferred mic UID=\(uid) not connected; using system default", category: "AudioCapture")
            return
        }
        guard let audioUnit = inputNode.audioUnit else {
            LogService.warn("Input node audioUnit unavailable; cannot set preferred mic", category: "AudioCapture")
            return
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            LogService.info("Mic input set to UID=\(uid)", category: "AudioCapture")
        } else {
            LogService.warn("AudioUnitSetProperty failed (status=\(status)); using system default", category: "AudioCapture")
        }
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
