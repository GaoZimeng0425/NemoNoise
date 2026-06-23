import AVFoundation
import os
import QuartzCore

struct AudioChunk: Sendable {
    let samples: [Float]
    let rmsLevel: Float
    let spectrum: [Float]
}

final class MicAudioSource: AudioSource, Sendable {
    /// Built fresh per `start()`, released in `stopEngine()`. A long-lived
    /// engine keeps the input device open after stop; for Bluetooth headsets
    /// that pins them in the HFP call profile (mono, muffled, AGC-loud output)
    /// until the app quits. Releasing the engine each session lets the device
    /// close so e.g. AirPods switch back to A2DP immediately after recording.
    private let engineBox = OSAllocatedUnfairLock<AVAudioEngine?>(initialState: nil)
    /// Rebuilt whenever the input format changes (e.g. the A2DP→HFP switch).
    /// `processTap` reads it under the lock so format changes can't desync it.
    private let resamplerBox = OSAllocatedUnfairLock<AudioResampler?>(initialState: nil)
    private let continuation: ContinuationBox = ContinuationBox()
    private let targetSampleRate: Double = 16000
    private let bufferSize: AVAudioFrameCount = 4096
    private let analyzer = SpectrumAnalyzer(binCount: 16, sampleRate: 16000)
    private let isCapturing = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let firstChunkLogged = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Grace period after `start()` during which a configuration change is
    /// treated as the self-inflicted input-route switch (reconfigure & keep
    /// recording) rather than a user device change (abort).
    private let configSettlingWindow: CFTimeInterval = 1.5
    private let captureStartedAt = OSAllocatedUnfairLock<CFTimeInterval>(initialState: 0)
    private let settlingReconfigured = OSAllocatedUnfairLock<Bool>(initialState: false)

    private let onInterruption: (@Sendable (AudioInterruptionReason) -> Void)?
    private let stallThreshold: CFTimeInterval = 2.0
    private let stallCheckInterval: CFTimeInterval = 0.5
    private let watchdog: OSAllocatedUnfairLock<AudioStallWatchdog>
    private let interruptionFired = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let stallTimer = OSAllocatedUnfairLock<DispatchSourceTimer?>(initialState: nil)
    private let configObserver = OSAllocatedUnfairLock<NSObjectProtocol?>(initialState: nil)

    init(onInterruption: (@Sendable (AudioInterruptionReason) -> Void)? = nil) {
        self.onInterruption = onInterruption
        self.watchdog = OSAllocatedUnfairLock(initialState: AudioStallWatchdog(threshold: stallThreshold, now: 0))
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        try await requestMicrophoneAccess()

        firstChunkLogged.withLock { $0 = false }
        settlingReconfigured.withLock { $0 = false }

        let engine = AVAudioEngine()
        engineBox.withLock { $0 = engine }

        let inputNode = engine.inputNode
        applyPreferredInputDevice(to: inputNode)
        applyEchoCancellation(to: inputNode)
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0 else {
            engineBox.withLock { $0 = nil }
            throw ASRError.audioCaptureFailed("No audio input device available")
        }

        LogService.info("Audio device: sampleRate=\(hardwareFormat.sampleRate), channels=\(hardwareFormat.channelCount), bufferSize=\(bufferSize)", category: "AudioCapture")

        // Pass the full hardwareFormat (not just sampleRate) so AVAudioConverter
        // also handles channel downmixing — VPIO/AEC exposes multi-channel input
        // (e.g. 9 channels) that a mono-only converter rejects with .error.
        guard let resampler = AudioResampler(sourceFormat: hardwareFormat, targetRate: targetSampleRate) else {
            engineBox.withLock { $0 = nil }
            throw ASRError.audioCaptureFailed("Failed to create sample rate converter")
        }
        resamplerBox.withLock { $0 = resampler }

        let stream = AsyncStream<AudioChunk> { [continuation] c in
            continuation.value = c
            c.onTermination = { [weak self] _ in self?.stopEngine() }
        }

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            engineBox.withLock { $0 = nil }
            resamplerBox.withLock { $0 = nil }
            throw error
        }
        interruptionFired.withLock { $0 = false }
        watchdog.withLock { $0 = AudioStallWatchdog(threshold: stallThreshold, now: CACurrentMediaTime()) }
        captureStartedAt.withLock { $0 = CACurrentMediaTime() }
        isCapturing.withLock { $0 = true }
        startStallTimer()
        observeConfigurationChanges(on: engine)
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
        stallTimer.withLock { timer in
            timer?.cancel()
            timer = nil
        }
        configObserver.withLock { token in
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
        // Pull the engine out of the box and drop our reference. Once the last
        // strong ref dies the engine deallocates and fully releases the input
        // device, so Bluetooth headsets switch back from HFP to A2DP right
        // away. `setVoiceProcessingEnabled(false)` first tears down VPIO
        // deterministically rather than relying on dealloc timing.
        let engine = engineBox.withLock { box -> AVAudioEngine? in
            let current = box
            box = nil
            return current
        }
        resamplerBox.withLock { $0 = nil }
        guard let engine else {
            LogService.info("Capture stopped (engine already released)", category: "AudioCapture")
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if engine.inputNode.isVoiceProcessingEnabled {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(false)
                LogService.info("Voice processing disabled", category: "AudioCapture")
            } catch {
                LogService.warn("setVoiceProcessingEnabled(false) failed: \(error.localizedDescription)", category: "AudioCapture")
            }
        }
        LogService.info("Capture stopped", category: "AudioCapture")
    }

    nonisolated private func processTap(buffer: AVAudioPCMBuffer) {
        watchdog.withLock { $0.recordActivity(at: CACurrentMediaTime()) }
        let isFirst = firstChunkLogged.withLock { current -> Bool in
            let was = current
            current = true
            return !was
        }
        if isFirst {
            LogService.info("processTap first chunk: frames=\(buffer.frameLength) bufFormat=\(buffer.format.sampleRate)Hz/\(buffer.format.channelCount)ch consumer=\(continuation.value != nil)", category: "AudioCapture")
        }
        guard let resampler = resamplerBox.withLock({ $0 }) else { return }
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

    /// Apple's voice processing I/O (AEC + noise suppression + AGC). Enabled
    /// here at start; `stopEngine()` disables it before releasing the engine so
    /// the device leaves voice-communication mode deterministically — otherwise
    /// the OS keeps processing system output (headphone music gets loud/muffled)
    /// until dealloc actually happens.
    private func applyEchoCancellation(to inputNode: AVAudioInputNode) {
        guard UserDefaults.standard.bool(forKey: AppDefaults.Keys.echoCancellation) else { return }
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            LogService.info("Voice processing enabled", category: "AudioCapture")
        } catch {
            LogService.warn("setVoiceProcessingEnabled(true) failed: \(error.localizedDescription)", category: "AudioCapture")
        }
    }

    /// Repeating background timer that asks the watchdog whether the raw tap
    /// has stalled. Fires `.audioStalled` at most once per session.
    private func startStallTimer() {
        stallTimer.withLock { timer in
            timer?.cancel()
            timer = nil
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + stallCheckInterval, repeating: stallCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stalled = self.watchdog.withLock { $0.isStalled(at: CACurrentMediaTime()) }
            if stalled {
                LogService.warn("Audio stall detected (no raw tap for >\(self.stallThreshold)s)", category: "AudioCapture")
                self.fireInterruptionOnce(.audioStalled)
            }
        }
        timer.resume()
        stallTimer.withLock { $0 = timer }
    }

    /// Observe engine reconfiguration (device switch, pinned-device disconnect,
    /// route change) while capturing. Scoped to this engine instance.
    ///
    /// Opening certain outputs as an input fires a configuration change as a
    /// *side effect* of `start()` — most notably Bluetooth headsets switching
    /// A2DP→HFP so their mic can be used. Within `configSettlingWindow` that
    /// self-inflicted switch is reconfigured-and-continued; only changes after
    /// the route has settled are treated as a user device change and abort.
    private func observeConfigurationChanges(on engine: AVAudioEngine) {
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            guard self.isCapturing.withLock({ $0 }) else { return }

            let elapsed = CACurrentMediaTime() - self.captureStartedAt.withLock { $0 }
            if elapsed < self.configSettlingWindow {
                let already = self.settlingReconfigured.withLock { done -> Bool in
                    let was = done
                    done = true
                    return was
                }
                guard !already else { return }
                LogService.info("Config change within settling window — input route settled, reconfiguring", category: "AudioCapture")
                self.reconfigureForRouteChange()
                return
            }

            LogService.warn("AVAudioEngine configuration changed mid-capture", category: "AudioCapture")
            self.fireInterruptionOnce(.deviceConfigurationChanged)
        }
        configObserver.withLock { $0 = token }
    }

    /// Rebuild the tap and resampler for the input's new hardware format after
    /// a route settle (e.g. A2DP→HFP), restarting the engine if the change
    /// stopped it. Keeps recording alive through the switch instead of aborting.
    private func reconfigureForRouteChange() {
        guard let engine = engineBox.withLock({ $0 }) else { return }
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              let resampler = AudioResampler(sourceFormat: format, targetRate: targetSampleRate) else {
            LogService.warn("Reconfigure failed to rebuild resampler for new input format", category: "AudioCapture")
            return
        }
        resamplerBox.withLock { $0 = resampler }
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                LogService.warn("Reconfigure engine restart failed: \(error.localizedDescription)", category: "AudioCapture")
            }
        }
        LogService.info("Reconfigured capture after route settle @ \(format.sampleRate)Hz/\(format.channelCount)ch", category: "AudioCapture")
    }

    /// Deliver the interruption to the callback at most once per session, then
    /// stop the engine. Subsequent triggers (e.g. stall fires right after a
    /// config change) are ignored.
    private func fireInterruptionOnce(_ reason: AudioInterruptionReason) {
        let already = interruptionFired.withLock { fired -> Bool in
            let was = fired
            fired = true
            return was
        }
        guard !already else { return }
        onInterruption?(reason)
        stopEngine()
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
