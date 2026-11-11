import AppKit
import AVFoundation
import os
import QuartzCore

/// AVAudioEngine teardown can block on internal IOUnit queues, and its
/// deallocation may overlap the next engine's start — two IOUnits briefly
/// holding the HAL input is what wedges the input into all-zeros after a
/// fast stop→start. Retired engines therefore die on this dedicated serial
/// queue, and a new engine waits for the queue to drain before it is built
/// (FluidVoice's AudioEngineRetirementDrain pattern).
nonisolated final class EngineRetirementDrain: Sendable {
    nonisolated(unsafe) static let shared = EngineRetirementDrain()
    private let queue = DispatchQueue(label: "nemo.engine-retirement")
    private init() {}

    /// Hand over the engine's last strong reference; it deallocates on the
    /// serial queue.
    func retire(_ engine: AVAudioEngine?) {
        guard let engine else { return }
        queue.async { _ = engine }
    }

    /// Resume when every earlier retirement has finished deallocating
    /// (serial-queue barrier), or after `timeout` at the latest.
    func waitDrained(timeout: TimeInterval = 3) async {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [queue] in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    queue.async { cont.resume() }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            _ = await group.next()
            group.cancelAll()
        }
    }
}

/// Process-wide hot-start slot (FluidVoice's standby pattern). `MicAudioSource`
/// instances are per-session objects, so the engine parked by one recording is
/// handed to the next recording through this singleton: a `start()` within the
/// standby window skips engine construction and the retirement-drain wait —
/// together the bulk of the first-sound loss after a stop→start cycle.
///
/// The engine is parked fully configured (tap removed, engine stopped, VPIO
/// left as-is); the system-wake observer drops a parked engine because HAL
/// state after sleep is undefined (VoiceInk invalidates on wake).
@MainActor
final class MicStandbyPool {
    nonisolated(unsafe) static let shared = MicStandbyPool()

    private struct Slot {
        let engine: AVAudioEngine
        let format: AVAudioFormat
    }
    private var slot: Slot?
    private var discardTimer: DispatchSourceTimer?
    private var wakeObserver: (any NSObjectProtocol)?
    /// Standby window in seconds; injectable so tests can use a short one.
    let window: Double
    /// Full teardown of a departing engine (VPIO off + retirement queue).
    /// Injectable because touching `inputNode` on an engine that never ran
    /// sends the TEST process into a HAL proxy retry loop — tests stub this.
    private let retireEngine: @MainActor (AVAudioEngine) -> Void

    nonisolated init(window: Double = 8,
                     retireEngine: @escaping @MainActor (AVAudioEngine) -> Void = { MicAudioSource.teardownAndRetire($0) }) {
        self.window = window
        self.retireEngine = retireEngine
    }

    /// Park an engine for a later `withdraw()`. Replaces (and retires) any
    /// engine already parked — the mutex serializes recordings, so this is a
    /// defensive path only.
    func deposit(engine: AVAudioEngine, format: AVAudioFormat) {
        if let old = slot {
            retireEngine(old.engine)
        }
        slot = Slot(engine: engine, format: format)
        scheduleDiscard()
        registerWakeObserverIfNeeded()
    }

    /// Take the parked engine for a hot start, if one is still in the window.
    func withdraw() -> (engine: AVAudioEngine, format: AVAudioFormat)? {
        discardTimer?.cancel()
        discardTimer = nil
        guard let current = slot else { return nil }
        slot = nil
        return (current.engine, current.format)
    }

    /// Full teardown of the parked engine: VPIO off deterministically, then
    /// the reference moves to the retirement queue so its dealloc can never
    /// overlap the next engine's start.
    func discard() {
        discardTimer?.cancel()
        discardTimer = nil
        guard let current = slot else { return }
        slot = nil
        retireEngine(current.engine)
        LogService.info("Standby engine retired (window expired)", category: "AudioCapture")
    }

    private func scheduleDiscard() {
        discardTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + window)
        // `@Sendable` is load-bearing: without it the closure inherits
        // MainActor isolation and asserts when the timer fires off-main.
        timer.setEventHandler { @Sendable [weak self] in
            Task { @MainActor [weak self] in self?.discard() }
        }
        timer.resume()
        discardTimer = timer
    }

    private func registerWakeObserverIfNeeded() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.slot != nil else { return }
                LogService.info("System woke — dropping standby engine", category: "AudioCapture")
                self.discard()
            }
        }
    }
}

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
    /// Registered and removed on the main actor only.
    private var configObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)? = nil

    // MARK: - Render-thread offload (VoiceInk pattern)
    //
    // The tap callback runs on the audio render thread, where allocating,
    // locking for long, or blocking can glitch the IO cycle. It therefore
    // only memcpy's samples into a staging array under a short lock; the
    // expensive work (resampling, FFT, zero-scan, yield) runs on a serial
    // processing queue.

    private let processQueue = DispatchQueue(label: "nemo.mic-processing", qos: .userInitiated)
    private let stagedSamples = OSAllocatedUnfairLock(initialState: [Float]())
    /// Hardware rate of the current engine's input — the drain side needs it
    /// to interpret staged samples.
    private let sourceRate = OSAllocatedUnfairLock(initialState: 0.0)

    /// Raw-input zero tracking for the self-heal below. Real mic silence
    /// still carries ADC noise floor; an all-exact-zero stream means the
    /// input channel is wedged — at session start OR mid-session (muesli's
    /// MeetingMicHealthTracker watches the whole session).
    private struct ZeroInputState {
        var sawAudio = false
        var zeroRunSeconds: CFTimeInterval = 0
        var healed = false
    }
    private let zeroState = OSAllocatedUnfairLock<ZeroInputState>(initialState: ZeroInputState())

    init(onInterruption: (@Sendable (AudioInterruptionReason) -> Void)? = nil) {
        self.onInterruption = onInterruption
        self.watchdog = OSAllocatedUnfairLock(initialState: AudioStallWatchdog(threshold: stallThreshold, now: 0))
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        try await requestMicrophoneAccess()

        firstChunkLogged.withLock { $0 = false }
        settlingReconfigured.withLock { $0 = false }
        zeroState.withLock { $0 = ZeroInputState() }

        let stream = AsyncStream<AudioChunk> { [continuation] c in
            continuation.value = c
            c.onTermination = { [weak self] _ in self?.stopEngineOnMain() }
        }

        // Hot start: a session that ended within the standby window parked its
        // engine — reuse it and only reinstall the tap. Skips both the engine
        // construction and the retirement-drain wait.
        if tryResumeFromStandby() {
            return stream
        }

        // Never build a new engine while a retired one is still deallocating
        // on the retirement queue — that overlap is the all-zeros wedge.
        await EngineRetirementDrain.shared.waitDrained()

        do {
            try launchEngine(freshSession: true)
        } catch {
            continuation.value = nil
            throw error
        }
        return stream
    }

    /// FluidVoice hot-start: resume a parked engine when the input still
    /// matches. Any mismatch or failure retires the parked engine and falls
    /// back to the cold path (whose `waitDrained` then covers its dealloc).
    private func tryResumeFromStandby() -> Bool {
        guard let parked = MicStandbyPool.shared.withdraw() else { return false }
        let engine = parked.engine

        // The preferred-mic setting may have changed while parked — re-pin
        // before comparing formats.
        applyPreferredInputDevice(to: engine.inputNode)

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              format.sampleRate == parked.format.sampleRate,
              format.channelCount == parked.format.channelCount else {
            LogService.info("Standby engine format mismatch (\(parked.format.sampleRate)Hz → \(format.sampleRate)Hz) — cold start", category: "AudioCapture")
            Self.teardownAndRetire(engine)
            return false
        }

        guard let resampler = AudioResampler(sourceFormat: format, targetRate: targetSampleRate) else {
            Self.teardownAndRetire(engine)
            return false
        }
        resamplerBox.withLock { $0 = resampler }
        sourceRate.withLock { $0 = format.sampleRate }
        engineBox.withLock { $0 = engine }

        guard safeInstallTap(on: engine.inputNode, format: format) else {
            abandonResumedEngine(engine)
            return false
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            LogService.warn("Standby engine restart failed: \(error.localizedDescription) — cold start", category: "AudioCapture")
            abandonResumedEngine(engine)
            return false
        }

        interruptionFired.withLock { $0 = false }
        watchdog.withLock { $0 = AudioStallWatchdog(threshold: stallThreshold, now: CACurrentMediaTime()) }
        captureStartedAt.withLock { $0 = CACurrentMediaTime() }
        isCapturing.withLock { $0 = true }
        startStallTimer()
        observeConfigurationChanges(on: engine)
        registerWakeObserver()
        LogService.info("Capture hot-started from standby @ \(format.sampleRate)Hz", category: "AudioCapture")
        return true
    }

    /// Undo a half-resumed standby engine: clear the boxes, remove the tap if
    /// it got installed, and retire the engine so the cold path starts clean.
    private func abandonResumedEngine(_ engine: AVAudioEngine) {
        engineBox.withLock { $0 = nil }
        resamplerBox.withLock { $0 = nil }
        sourceRate.withLock { $0 = 0 }
        stopEngineAndRemoveTap(engine)
        Self.teardownAndRetire(engine)
    }

    /// Engine bring-up shared by `start()` and the zero-input self-heal.
    /// `freshSession == false` (rebuild) keeps the current session token so
    /// in-flight guards stay valid.
    private func launchEngine(freshSession: Bool) throws {
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
        sourceRate.withLock { $0 = hardwareFormat.sampleRate }

        guard safeInstallTap(on: inputNode, format: hardwareFormat) else {
            engineBox.withLock { $0 = nil }
            resamplerBox.withLock { $0 = nil }
            throw ASRError.audioCaptureFailed("Failed to install audio tap")
        }

        do {
            try engine.start()
        } catch {
            stopEngineAndRemoveTap(engine)
            engineBox.withLock { $0 = nil }
            resamplerBox.withLock { $0 = nil }
            sourceRate.withLock { $0 = 0 }
            throw error
        }
        firstChunkLogged.withLock { $0 = false }
        interruptionFired.withLock { $0 = false }
        watchdog.withLock { $0 = AudioStallWatchdog(threshold: stallThreshold, now: CACurrentMediaTime()) }
        if freshSession {
            captureStartedAt.withLock { $0 = CACurrentMediaTime() }
        }
        isCapturing.withLock { $0 = true }
        startStallTimer()
        observeConfigurationChanges(on: engine)
        registerWakeObserver()
        LogService.info("Capture started, converting \(hardwareFormat.sampleRate)Hz -> \(targetSampleRate)Hz", category: "AudioCapture")
    }

    func stop() {
        // Tear down first: its barrier on the processing queue still yields
        // the audio captured before stop into the live stream. Finishing the
        // stream first dropped that tail (the end of the last word).
        standbyOrStopEngine()
        continuation.value?.finish()
        continuation.value = nil
    }

    isolated deinit {
        stopEngine()
    }

    /// Idempotent teardown head shared by `stopEngine()` and
    /// `standbyOrStopEngine()`: flips the capture flag, drains in-flight
    /// render copies (tail audio), stops timers/observers, and extracts the
    /// engine. Only the first call after a successful `start()` does work.
    private enum TeardownPrep {
        case idle
        case engineless
        case engine(AVAudioEngine)
    }

    private func prepareTeardown() -> TeardownPrep {
        let wasCapturing = isCapturing.withLock { running -> Bool in
            let was = running
            running = false
            return was
        }
        guard wasCapturing else { return .idle }
        // Let in-flight render copies finish processing (tail audio) before
        // the resampler goes away — a barrier on the serial processing queue.
        processQueue.sync { }
        stallTimer.withLock { timer in
            timer?.cancel()
            timer = nil
        }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        let engine = engineBox.withLock { box -> AVAudioEngine? in
            let current = box
            box = nil
            return current
        }
        resamplerBox.withLock { $0 = nil }
        sourceRate.withLock { $0 = 0 }
        guard let engine else {
            LogService.info("Capture stopped (engine already released)", category: "AudioCapture")
            return .engineless
        }
        return .engine(engine)
    }

    /// Hard teardown — interruptions, wedged engines, dealloc. The engine is
    /// fully released: VPIO off, then the last strong reference moves to the
    /// retirement queue so its dealloc can never overlap the next engine's
    /// start.
    private func stopEngine() {
        guard case .engine(let engine) = prepareTeardown() else { return }
        stopEngineAndRemoveTap(engine)
        Self.teardownAndRetire(engine)
        LogService.info("Capture stopped", category: "AudioCapture")
    }

    /// Normal-stop path: park the configured engine in the standby pool so a
    /// session starting within the window hot-starts, instead of paying
    /// engine construction + retirement-drain wait (most of the first-sound
    /// loss in a stop→start cycle). Bluetooth inputs never park — holding the
    /// input open pins the headset in the HFP call profile.
    private func standbyOrStopEngine() {
        guard case .engine(let engine) = prepareTeardown() else { return }
        stopEngineAndRemoveTap(engine)
        if Self.isBluetoothInputDevice(engine) {
            Self.teardownAndRetire(engine)
            LogService.info("Capture stopped (Bluetooth input — no standby)", category: "AudioCapture")
            return
        }
        // A session that only ever saw exact zeros may be on a wedged HAL
        // input. Short taps never reach the 1.5 s self-heal, so parking it
        // would hand the wedge to every following hot start.
        guard zeroState.withLock({ $0.sawAudio }) else {
            Self.teardownAndRetire(engine)
            LogService.info("Capture stopped (no real audio seen — no standby)", category: "AudioCapture")
            return
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        MicStandbyPool.shared.deposit(engine: engine, format: format)
        LogService.info("Capture parked for hot start (\(MicStandbyPool.shared.window)s window)", category: "AudioCapture")
    }

    /// `setVoiceProcessingEnabled(false)` tears down VPIO deterministically
    /// (rather than relying on dealloc timing) so the device leaves
    /// voice-communication mode, then the engine dies on the retirement
    /// queue. Called on the main actor, like every AVAudioEngine mutation.
    fileprivate static func teardownAndRetire(_ engine: AVAudioEngine) {
        if engine.inputNode.isVoiceProcessingEnabled {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(false)
                LogService.info("Voice processing disabled", category: "AudioCapture")
            } catch {
                LogService.warn("setVoiceProcessingEnabled(false) failed: \(error.localizedDescription)", category: "AudioCapture")
            }
        }
        EngineRetirementDrain.shared.retire(engine)
    }

    /// True when the engine's current input device is Bluetooth (classic or
    /// LE). Used only to decide standby eligibility — failures read as
    /// "not Bluetooth", i.e. standby stays allowed.
    private static func isBluetoothInputDevice(_ engine: AVAudioEngine) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit else { return false }
        var deviceID = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &deviceSize
        )
        guard status == noErr else { return false }
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &transportSize, &transport)
        guard status == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// HAL state after a system sleep is undefined (VoiceInk invalidates its
    /// prepared unit on wake); rebuild the engine if a session is live. A
    /// parked engine is handled separately by the standby pool's own wake
    /// observer.
    private func registerWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.rebuildEngineOnMain()
        }
    }

    /// Muesli pattern: removing a tap from a running engine can deadlock (or
    /// raise an Obj-C exception Swift can't catch) during a route rebind. If
    /// cleanup fails, the graph is in an uncertain state — drop it wholesale;
    /// the retirement-queue dealloc fully tears down the HAL session anyway.
    private func stopEngineAndRemoveTap(_ engine: AVAudioEngine) {
        do {
            try catchingObjCException {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        } catch {
            LogService.warn("stopEngine/removeTap raised: \((error as NSError).localizedDescription) — abandoning graph", category: "AudioCapture")
        }
    }

    /// Render-thread half: memcpy only. Everything else happens on
    /// `processQueue` via `drainStagedAudio`. The channel pointer crosses the
    /// closure as a bit pattern — VoiceInk's trick for keeping the render
    /// callback free of non-Sendable captures.
    nonisolated private func processTap(buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let channelBits = UInt(bitPattern: channel)
        stagedSamples.withLock { staging in
            guard let ptr = UnsafeMutablePointer<Float>(bitPattern: channelBits) else { return }
            if staging.isEmpty { staging.reserveCapacity(16_384) }
            staging.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
        }
        processQueue.async { [weak self] in
            self?.drainStagedAudio()
        }
    }

    /// Processing-queue half. Serial, so `resampler`/`analyzer` keep their
    /// single-consumer contract the render thread used to provide.
    nonisolated private func drainStagedAudio() {
        while true {
            let batch = stagedSamples.withLock { staging -> [Float] in
                guard !staging.isEmpty else { return [] }
                let taken = staging
                staging = []
                staging.reserveCapacity(16_384)
                return taken
            }
            guard !batch.isEmpty else { return }
            processSampleBatch(batch)
        }
    }

    nonisolated private func processSampleBatch(_ samples: [Float]) {
        let rate = sourceRate.withLock { $0 }
        guard rate > 0 else { return }

        watchdog.withLock { $0.recordActivity(at: CACurrentMediaTime()) }
        trackZeroInput(samples, sampleRate: rate)

        let isFirst = firstChunkLogged.withLock { current -> Bool in
            let was = current
            current = true
            return !was
        }
        if isFirst {
            LogService.info("processTap first chunk: frames=\(samples.count) source=\(rate)Hz consumer=\(continuation.value != nil)", category: "AudioCapture")
        }

        guard let resampler = resamplerBox.withLock({ $0 }) else { return }
        guard let converted = resampler.resample(samples) else {
            if isFirst {
                LogService.warn("processTap first chunk: resampler returned nil (format mismatch?)", category: "AudioCapture")
            }
            return
        }
        let rms = sqrt(converted.reduce(0) { $0 + $1 * $1 } / Float(converted.count))
        SessionAudioRecorder.shared.append(converted)
        let spectrum = analyzer.analyze(converted)
        continuation.value?.yield(AudioChunk(samples: converted, rmsLevel: rms, spectrum: spectrum))
    }

    /// Raw (pre-resample) zero tracking, for the whole session. Exact-zero
    /// samples mean the input channel is wedged — real silence still carries
    /// ADC noise, so this is a safe discriminator.
    nonisolated private func trackZeroInput(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        let hasAudio = samples.contains { abs($0) > Float(1e-5) }
        let duration = CFTimeInterval(samples.count) / sampleRate
        let audioDetected = hasAudio
        zeroState.withLock { state in
            if audioDetected {
                state.sawAudio = true
                state.zeroRunSeconds = 0
            } else {
                state.zeroRunSeconds += duration
            }
        }
    }

    /// Installs the processing tap, catching the Obj-C `NSException` that
    /// `installTap` raises for an invalid/transitional format — which happens
    /// while a Bluetooth device switches the A2DP↔HFP profile — so it degrades
    /// gracefully instead of aborting the process. Returns false if the format
    /// is unusable or the install raised.
    private func safeInstallTap(on inputNode: AVAudioInputNode, format: AVAudioFormat) -> Bool {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            LogService.warn("installTap skipped — invalid format \(format.sampleRate)Hz/\(format.channelCount)ch", category: "AudioCapture")
            return false
        }
        do {
            try catchingObjCException {
                // `@Sendable` is load-bearing: the tap block is NS_SWIFT_NONSENDABLE,
                // so without it the closure inherits main-actor isolation and
                // Swift 6 traps the first time the render thread calls it.
                inputNode.installTap(onBus: 0, bufferSize: self.bufferSize, format: format) { @Sendable [weak self] buffer, _ in
                    self?.processTap(buffer: buffer)
                }
            }
            return true
        } catch {
            LogService.warn("installTap raised: \((error as NSError).localizedDescription) — skipping tap install", category: "AudioCapture")
            return false
        }
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
        // Runs on a global queue: only the lock-protected check happens here;
        // the teardown hops to the main actor (see `fireInterruptionOnMain`).
        timer.setEventHandler { @Sendable [weak self] in
            guard let self else { return }
            let stalled = self.watchdog.withLock { $0.isStalled(at: CACurrentMediaTime()) }
            if stalled {
                LogService.warn("Audio stall detected (no raw tap for >\(self.stallThreshold)s)", category: "AudioCapture")
                self.fireInterruptionOnMain(.audioStalled)
                return
            }
            // Self-heal: the raw input has been exact zeros for a sustained
            // stretch — the channel is wedged. Watched for the WHOLE session
            // (muesli pattern), not just the start; mid-session wedges happen
            // after device hiccups. Faster at session start (no audio ever
            // seen), slower once speech was flowing (distinguish from a pause
            // — real silence still has ADC noise, exact zeros never do).
            let needsHeal = self.zeroState.withLock { state -> Bool in
                let threshold: CFTimeInterval = state.sawAudio ? 3.0 : 1.5
                guard state.zeroRunSeconds >= threshold, !state.healed else { return false }
                state.healed = true
                state.zeroRunSeconds = 0
                return true
            }
            if needsHeal {
                LogService.warn("Input delivering only zeros (>1.5s) — rebuilding audio engine", category: "AudioCapture")
                self.rebuildEngineOnMain()
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
            // Posted on an internal CoreAudio queue, where the engine must not
            // be torn down (AVAudioEngine.h: it can deadlock). Note when it
            // fired, then handle it on the main actor with every other
            // AVAudioEngine mutation.
            self?.handleConfigurationChangeOnMain(postedAt: CACurrentMediaTime())
        }
        configObserver = token
    }

    /// Main-actor half of the configuration-change observer. Dropped if the
    /// session it was posted for has already ended or been replaced.
    nonisolated private func handleConfigurationChangeOnMain(postedAt: CFTimeInterval) {
        let session = captureStartedAt.withLock { $0 }
        Task { @MainActor in
            guard self.isCapturing.withLock({ $0 }),
                  self.captureStartedAt.withLock({ $0 }) == session else { return }

            if postedAt - session < self.configSettlingWindow {
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
    }

    /// Rebuild the tap and resampler for the input's new hardware format after
    /// a route settle (e.g. A2DP→HFP), restarting the engine if the change
    /// stopped it. Keeps recording alive through the switch instead of aborting.
    private func reconfigureForRouteChange() {
        guard let engine = engineBox.withLock({ $0 }) else { return }
        let inputNode = engine.inputNode
        do {
            try catchingObjCException {
                inputNode.removeTap(onBus: 0)
            }
        } catch {
            // Graph state is uncertain after a failed remove — abort rather
            // than reinstall a tap on it (muesli abandons the graph here too).
            LogService.warn("Reconfigure removeTap raised — finalizing session", category: "AudioCapture")
            fireInterruptionOnce(.deviceConfigurationChanged)
            return
        }

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              let resampler = AudioResampler(sourceFormat: format, targetRate: targetSampleRate) else {
            LogService.warn("Reconfigure failed to rebuild resampler for new input format", category: "AudioCapture")
            return
        }
        resamplerBox.withLock { $0 = resampler }
        sourceRate.withLock { $0 = format.sampleRate }
        guard safeInstallTap(on: inputNode, format: format) else {
            // The transitional Bluetooth format made installTap raise (or the
            // format was unusable). Rather than crash, abort this session via
            // the normal interruption path so it finalizes cleanly.
            LogService.warn("Reconfigure installTap failed (Bluetooth route transition?) — finalizing session", category: "AudioCapture")
            fireInterruptionOnce(.deviceConfigurationChanged)
            return
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

    /// Interruption detected off the main actor (the stall timer): tear down on
    /// the main actor, unless its session has already ended or been replaced.
    nonisolated private func fireInterruptionOnMain(_ reason: AudioInterruptionReason) {
        let session = captureStartedAt.withLock { $0 }
        Task { @MainActor in
            guard self.isCapturing.withLock({ $0 }),
                  self.captureStartedAt.withLock({ $0 }) == session else { return }
            self.fireInterruptionOnce(reason)
        }
    }

    /// `AsyncStream.onTermination` can fire on the consumer's thread; run the
    /// teardown on the main actor unless a newer session has started since.
    nonisolated private func stopEngineOnMain() {
        let session = captureStartedAt.withLock { $0 }
        Task { @MainActor in
            guard self.captureStartedAt.withLock({ $0 }) == session else { return }
            self.stopEngine()
        }
    }

    /// Zero-input self-heal: tear down the wedged engine and bring up a
    /// fresh one into the SAME session (stream keeps flowing; the gap is a
    /// few hundred ms of silence). Skipped if the session already ended.
    nonisolated private func rebuildEngineOnMain() {
        let session = captureStartedAt.withLock { $0 }
        Task { @MainActor in
            guard self.isCapturing.withLock({ $0 }),
                  self.captureStartedAt.withLock({ $0 }) == session else { return }
            self.stopEngine()
            await EngineRetirementDrain.shared.waitDrained()
            // The wait can take seconds: if the session was stopped (stream
            // gone) or replaced meanwhile, launching would leave a listener-
            // less engine holding the mic — or a second engine on the input.
            guard self.continuation.value != nil,
                  self.captureStartedAt.withLock({ $0 }) == session else { return }
            do {
                try self.launchEngine(freshSession: false)
                LogService.info("Audio engine rebuilt", category: "AudioCapture")
            } catch {
                LogService.error("Audio engine rebuild failed: \(error.localizedDescription)", category: "AudioCapture")
                // Otherwise the session stays open but silent forever (stall
                // timer already cancelled): end it so the UI recovers.
                self.interruptionFired.withLock { $0 = false }
                self.fireInterruptionOnce(.audioStalled)
            }
        }
    }

    private func requestMicrophoneAccess() async throws {
        switch MicrophonePermission.preflight() {
        case .ready:
            return
        case .needsPrompt:
            guard await MicrophonePermission.prompt() else {
                throw ASRError.audioCaptureFailed("Microphone access denied")
            }
        case .denied:
            throw ASRError.audioCaptureFailed("Microphone access denied — enable in System Settings → Privacy → Microphone")
        }
    }
}
