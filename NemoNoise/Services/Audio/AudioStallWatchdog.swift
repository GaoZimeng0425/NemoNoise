import Foundation

/// Why an in-progress recording was interrupted. Both reasons map to the same
/// "stop-and-notify" response; only the toast copy differs.
enum AudioInterruptionReason: Sendable {
    /// Input-device configuration changed mid-recording (device switched,
    /// pinned device disconnected, route changed).
    case deviceConfigurationChanged
    /// No raw audio buffers arrived for longer than the stall threshold —
    /// the capture device went silent at the hardware level.
    case audioStalled
}

/// Pure stall-detection logic: no timers, no audio, clock injected by the
/// caller. `MicAudioSource` serializes access behind a lock, so this type is
/// intentionally not thread-safe on its own.
struct AudioStallWatchdog {
    let threshold: CFTimeInterval
    private(set) var lastActivity: CFTimeInterval

    init(threshold: CFTimeInterval, now: CFTimeInterval) {
        self.threshold = threshold
        self.lastActivity = now
    }

    mutating func recordActivity(at now: CFTimeInterval) {
        lastActivity = now
    }

    func isStalled(at now: CFTimeInterval) -> Bool {
        now - lastActivity > threshold
    }
}
