import AVFoundation
import CoreAudio
import os

/// System-audio capture via a Core Audio process tap: taps every other
/// process's output, mixed to mono at the hardware rate, and delivers the same
/// 16 kHz mono Float32 `AudioChunk` contract as the other sources. Runs under
/// TCC's audio-only "System Audio Recording" consent, so meeting mode never
/// needs the Screen Recording permission (or its periodic re-authorization).
///
/// If the tap cannot be created (Core Audio error, host oddity), `start()`
/// transparently falls back to the ScreenCaptureKit-based `SystemAudioSource`:
/// capture keeps working, just with the heavier permission ask.
///
/// TCC reality: creating a tap while unauthorized *succeeds* and delivers exact
/// digital zeros — no error, no status API. Real audio flow is the only proof
/// of a grant, so a session that never saw a non-zero sample warns once after
/// `silenceWarningSeconds` (unless an earlier session already proved the tap).
final class ProcessTapAudioSource: AudioSource, @unchecked Sendable {

    enum TapError: LocalizedError {
        case coreAudio(stage: String, status: OSStatus)
        case setupFailed(stage: String)

        var errorDescription: String? {
            switch self {
            case .coreAudio(let stage, let status):
                return "Process tap \(stage) failed (OSStatus \(status))"
            case .setupFailed(let stage):
                return "Process tap \(stage) setup failed"
            }
        }
    }

    /// `nonisolated` so the IO-queue path can read these constants.
    private nonisolated enum Constants {
        static let targetSampleRate: Double = 16000
        /// How long a session of pure digital silence takes before we suspect
        /// the System Audio Recording permission was denied.
        static let silenceWarningSeconds: Double = 15
        static let tapFormatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private let continuationBox = ContinuationBox()
    private let analyzer = SpectrumAnalyzer(binCount: 16, sampleRate: 16000)

    /// SCK fallback, used when tap creation fails.
    private let screenCaptureFallback = SystemAudioSource()
    private var usingFallback = false

    /// Tap resources. Created on the main actor in `startTapStream`, torn down
    /// on the main actor in `stopTap`. The IO callback and format listener only
    /// touch the lock-protected boxes below — never these directly (except
    /// `tapIDBox`, which they read through the lock).
    private let tapIDBox = OSAllocatedUnfairLock<AudioObjectID>(initialState: AudioObjectID(kAudioObjectUnknown))
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var formatListener: AudioObjectPropertyListenerBlock?

    /// IO callbacks and the format listener share `ioQueue`, so the converter
    /// pair is never rebuilt mid-buffer; the boxes add the safety Swift can't
    /// see from queue confinement alone.
    private let ioQueue = DispatchQueue(label: "com.nemonoise.process-tap.io", qos: .userInteractive)
    private let tapFormatBox = OSAllocatedUnfairLock<AVAudioFormat?>(initialState: nil)
    private let resamplerBox = OSAllocatedUnfairLock<AudioResampler?>(initialState: nil)

    /// Zero-silence watch for the denied-permission case.
    private let sawRealAudio = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let silenceWarned = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let zeroSeconds = OSAllocatedUnfairLock<Double>(initialState: 0)

    // MARK: - AudioSource

    func start() async throws -> AsyncStream<AudioChunk> {
        do {
            let stream = try startTapStream()
            usingFallback = false
            return stream
        } catch {
            LogService.warn("Process tap unavailable (\(error.localizedDescription)) — falling back to ScreenCaptureKit capture",
                            category: "ProcessTap")
            usingFallback = true
            return try await screenCaptureFallback.start()
        }
    }

    func stop() {
        if usingFallback {
            screenCaptureFallback.stop()
        } else {
            continuationBox.value?.finish()
            stopTap()
        }
    }

    isolated deinit {
        stopTap()
    }

    /// Creating (and immediately destroying) a tap is the only way to trigger
    /// macOS's one "System Audio Recording" consent prompt. The answer cannot
    /// be read back; real audio flow is the only proof of a grant.
    static func fireAuthorizationPrompt() {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "NemoNoise System Audio"
        description.isPrivate = true
        var probeTapID = AudioObjectID(kAudioObjectUnknown)
        if AudioHardwareCreateProcessTap(description, &probeTapID) == noErr,
           probeTapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(probeTapID)
        }
    }

    // MARK: - Tap lifecycle

    private func startTapStream() throws -> AsyncStream<AudioChunk> {
        // Leave our own process out of the global mono mixdown — the app's own
        // output (toasts, synthesized audio) must not loop back into the track.
        var excluded: [AudioObjectID] = []
        if let own = Self.currentProcessObjectID() { excluded = [own] }

        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.name = "NemoNoise System Audio"
        description.isPrivate = true
        // The user must keep hearing their meeting while we listen in.
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.coreAudio(stage: "creation", status: status)
        }
        let createdTapID = newTapID
        tapIDBox.withLock { $0 = createdTapID }

        do {
            // The tap delivers in the output device's format (typically 48 kHz
            // mono Float32); the resampler brings it to 16 kHz.
            let format = try readTapFormat()
            try installConverter(for: format)

            // A private aggregate device whose only member is the tap gives the
            // IOProc a clock to run against; it never shows in Audio MIDI Setup.
            // Tap auto-start stays off: with it, IO idles until some app starts
            // playing and then joins that app's output late.
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "NemoNoise System Audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: description.uuid.uuidString,
                     kAudioSubTapDriftCompensationKey: true]
                ]
            ]
            status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
            guard status == noErr, aggregateID != kAudioObjectUnknown else {
                throw TapError.coreAudio(stage: "aggregate device", status: status)
            }

            status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { @Sendable [weak self] _, inInputData, _, _, _ in
                self?.deliver(inInputData)
            }
            guard status == noErr, ioProcID != nil else {
                throw TapError.coreAudio(stage: "IO proc", status: status)
            }

            status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else {
                throw TapError.coreAudio(stage: "device start", status: status)
            }

            addFormatListener()

            sawRealAudio.withLock { $0 = false }
            silenceWarned.withLock { $0 = false }
            zeroSeconds.withLock { $0 = 0 }

            LogService.info("Process tap started", category: "ProcessTap")
            return AsyncStream<AudioChunk> { [weak self] continuation in
                self?.continuationBox.value = continuation
                continuation.onTermination = { @Sendable [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.stopTap()
                    }
                }
            }
        } catch {
            stopTap()
            throw error
        }
    }

    private func stopTap() {
        if let listener = formatListener {
            var addr = Constants.tapFormatAddress
            AudioObjectRemovePropertyListenerBlock(tapIDBox.withLock { $0 }, &addr, ioQueue, listener)
            formatListener = nil
        }
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        let tapID = tapIDBox.withLock { $0 }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapIDBox.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
        }
        resamplerBox.withLock { $0 = nil }
        tapFormatBox.withLock { $0 = nil }
        LogService.info("Process tap stopped", category: "ProcessTap")
    }

    // MARK: - IO path (ioQueue)

    /// Wraps the raw buffer list, resamples to 16 kHz mono, and yields the
    /// chunk. Runs on the IO queue — never the main actor.
    nonisolated private func deliver(_ bufferList: UnsafePointer<AudioBufferList>) {
        guard let format = tapFormatBox.withLock({ $0 }),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: UnsafeMutablePointer(mutating: bufferList),
                deallocator: nil),
              buffer.frameLength > 0 else { return }

        guard let resampler = resamplerBox.withLock({ $0 }),
              let samples = resampler.resample(buffer: buffer) else { return }

        trackSilence(samples)

        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
        let spectrum = analyzer.analyze(samples)
        continuationBox.value?.yield(AudioChunk(samples: samples, rmsLevel: rms, spectrum: spectrum))
    }

    /// Denied-permission detection: a tap the user declined delivers exact
    /// digital zeros forever. Warn once when a session has seen nothing but
    /// zeros, unless an earlier session already proved real audio flows.
    nonisolated private func trackSilence(_ samples: [Float]) {
        if samples.contains(where: { $0 != 0 }) {
            let firstRealAudio = sawRealAudio.withLock { saw in
                let wasFirst = !saw
                saw = true
                return wasFirst
            }
            if firstRealAudio {
                UserDefaults.standard.set(true, forKey: AppDefaults.Keys.systemAudioTapProven)
            }
            return
        }
        guard !sawRealAudio.withLock({ $0 }),
              !silenceWarned.withLock({ $0 }),
              !UserDefaults.standard.bool(forKey: AppDefaults.Keys.systemAudioTapProven) else { return }

        let seconds = zeroSeconds.withLock { zero in
            zero += Double(samples.count) / Constants.targetSampleRate
            return zero
        }
        guard seconds >= Constants.silenceWarningSeconds else { return }
        silenceWarned.withLock { $0 = true }
        LogService.warn("Process tap delivered only silence for \(Int(seconds))s — System Audio Recording permission may be denied",
                        category: "ProcessTap")
        Task { @MainActor in
            ToastWindowController.show("System audio is silent — check System Settings → Privacy → System Audio Recording",
                                       style: .warning, duration: 6)
        }
    }

    // MARK: - Format handling

    /// Output-device switches (speakers → AirPods) change the tap's rate
    /// mid-session; rebuilding just the converter keeps the stream alive.
    private func addFormatListener() {
        var addr = Constants.tapFormatAddress
        // `@Sendable` is load-bearing on both audio-callback closures (this
        // and the IOProc above): without it they inherit MainActor isolation
        // and trap on CoreAudio's IO thread (same family as the mic tap's
        // installTap block).
        let listener: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            self?.handleFormatChange()
        }
        if AudioObjectAddPropertyListenerBlock(tapIDBox.withLock { $0 }, &addr, ioQueue, listener) == noErr {
            formatListener = listener
        }
    }

    /// Runs on `ioQueue` (the listener's queue), so it can't race `deliver`.
    nonisolated private func handleFormatChange() {
        guard let format = try? readTapFormat() else { return }
        let current = tapFormatBox.withLock { $0 }
        if let current, current.sampleRate == format.sampleRate, current.channelCount == format.channelCount {
            return
        }
        guard let resampler = AudioResampler(sourceFormat: format, targetRate: Constants.targetSampleRate) else {
            LogService.warn("Process tap format change to \(format.sampleRate)Hz — resampler rebuild failed",
                            category: "ProcessTap")
            return
        }
        resamplerBox.withLock { $0 = resampler }
        tapFormatBox.withLock { $0 = format }
        LogService.info("Process tap format changed — now \(format.sampleRate)Hz ×\(format.channelCount)ch",
                        category: "ProcessTap")
    }

    nonisolated private func readTapFormat() throws -> AVAudioFormat {
        var addr = Constants.tapFormatAddress
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapIDBox.withLock { $0 }, &addr, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.coreAudio(stage: "format read", status: status)
        }
        return format
    }

    private func installConverter(for format: AVAudioFormat) throws {
        guard let resampler = AudioResampler(sourceFormat: format, targetRate: Constants.targetSampleRate) else {
            throw TapError.setupFailed(stage: "resampler")
        }
        resamplerBox.withLock { $0 = resampler }
        tapFormatBox.withLock { $0 = format }
    }

    // MARK: - Helpers

    /// The Core Audio process object for our PID, needed for the tap's exclude
    /// list. `nil` simply means no self-exclusion.
    private static func currentProcessObjectID() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = ProcessInfo.processInfo.processIdentifier
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &objectID)
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }
}
