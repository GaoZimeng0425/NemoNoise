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
    private let isCapturing = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let firstChunkLogged = OSAllocatedUnfairLock<Bool>(initialState: false)

    func start() async throws -> AsyncStream<AudioChunk> {
        try await requestMicrophoneAccess()

        firstChunkLogged.withLock { $0 = false }

        let inputNode = engine.inputNode
        applyPreferredInputDevice(to: inputNode)
        applyEchoCancellation(to: inputNode)
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0 else {
            throw ASRError.audioCaptureFailed("No audio input device available")
        }

        LogService.info("Audio device: sampleRate=\(hardwareFormat.sampleRate), channels=\(hardwareFormat.channelCount), bufferSize=\(bufferSize)", category: "AudioCapture")

        // Pass the full hardwareFormat (not just sampleRate) so AVAudioConverter
        // also handles channel downmixing — VPIO/AEC exposes multi-channel input
        // (e.g. 9 channels) that a mono-only converter rejects with .error.
        guard let resampler = AudioResampler(sourceFormat: hardwareFormat, targetRate: targetSampleRate) else {
            throw ASRError.audioCaptureFailed("Failed to create sample rate converter")
        }

        let stream = AsyncStream<AudioChunk> { [continuation] c in
            continuation.value = c
            c.onTermination = { [weak self] _ in self?.stopEngine() }
        }

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer, resampler: resampler)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
        isCapturing.withLock { $0 = true }
        LogService.info("Capture started, converting \(hardwareFormat.sampleRate)Hz -> \(targetSampleRate)Hz", category: "AudioCapture")
        return stream
    }

    func stop() {
        continuation.value?.finish()
        continuation.value = nil
        stopEngine()
    }

    deinit {
        stopEngine()
    }

    /// Idempotent: only the first call after a successful `start()` actually
    /// touches the engine. Safe to invoke from `stop()` directly *and* from
    /// `AsyncStream.onTermination` — whichever fires first wins.
    private func stopEngine() {
        let wasCapturing = isCapturing.withLock { running -> Bool in
            let was = running
            running = false
            return was
        }
        guard wasCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        LogService.info("Capture stopped", category: "AudioCapture")
    }

    nonisolated private func processTap(buffer: AVAudioPCMBuffer, resampler: AudioResampler) {
        let isFirst = firstChunkLogged.withLock { current -> Bool in
            let was = current
            current = true
            return !was
        }
        if isFirst {
            LogService.info("processTap first chunk: frames=\(buffer.frameLength) bufFormat=\(buffer.format.sampleRate)Hz/\(buffer.format.channelCount)ch consumer=\(continuation.value != nil)", category: "AudioCapture")
        }
        guard let samples = resampler.resample(buffer: buffer) else {
            if isFirst {
                LogService.warn("processTap first chunk: resampler returned nil (format mismatch?)", category: "AudioCapture")
            }
            return
        }
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

    /// Apple's voice processing I/O (AEC + noise suppression + AGC). A fresh
    /// AVAudioEngine starts in non-VPIO state, so we only call the API when
    /// enabling — calling it with `false` would reinstantiate the audio unit
    /// for no reason, producing a visible mic-indicator close/reopen cycle on
    /// every record.
    private func applyEchoCancellation(to inputNode: AVAudioInputNode) {
        guard UserDefaults.standard.bool(forKey: AppDefaults.Keys.echoCancellation) else { return }
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            LogService.info("Voice processing enabled", category: "AudioCapture")
        } catch {
            LogService.warn("setVoiceProcessingEnabled(true) failed: \(error.localizedDescription)", category: "AudioCapture")
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
