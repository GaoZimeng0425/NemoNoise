import AppKit
import AVFoundation

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
