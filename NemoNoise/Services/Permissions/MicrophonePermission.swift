import AVFoundation

/// The mic-permission gate shared by the dictation/meeting controllers and
/// the mic audio source — the one place that maps
/// `AVCaptureDevice.authorizationStatus`, so status handling can't drift
/// between callers.
nonisolated enum MicrophonePermission {
    enum Gate: Equatable {
        /// Already authorized — proceed without prompting.
        case ready
        /// `.notDetermined` — the system prompt (`prompt()`) is the next step.
        case needsPrompt
        /// Denied or restricted — the caller surfaces its blocked-state UX.
        case denied
    }

    /// Current state without prompting.
    static func preflight() -> Gate {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .ready
        case .notDetermined: return .needsPrompt
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Runs the system permission prompt; true when mic access is granted
    /// afterwards.
    static func prompt() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
