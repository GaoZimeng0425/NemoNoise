import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Observation
import Speech

@MainActor
@Observable
final class PermissionService {
    var isAXTrusted: Bool
    var hasScreenRecording: Bool
    var micStatus: AVAuthorizationStatus
    var speechStatus: SFSpeechRecognizerAuthorizationStatus

    private var timer: Timer?

    init() {
        self.isAXTrusted = AXIsProcessTrusted()
        self.hasScreenRecording = CGPreflightScreenCaptureAccess()
        self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.speechStatus = SFSpeechRecognizer.authorizationStatus()
        startPolling()
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        if ax != isAXTrusted { isAXTrusted = ax }
        let sr = CGPreflightScreenCaptureAccess()
        if sr != hasScreenRecording { hasScreenRecording = sr }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != micStatus { micStatus = mic }
        let speech = SFSpeechRecognizer.authorizationStatus()
        if speech != speechStatus { speechStatus = speech }
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    // MARK: - System Settings deep links

    /// The Privacy & Security panes NemoNoise cares about. System Audio
    /// Recording (macOS 15+) has no direct anchor — it lands on the Privacy
    /// list, where the row is a short scroll away.
    enum PrivacyPane {
        case microphone
        case speechRecognition
        case accessibility
        case screenRecording
        /// Privacy & Security list (used for System Audio Recording, which has
        /// no dedicated anchor).
        case privacyList

        var anchor: String {
            switch self {
            case .microphone:         return "Privacy_Microphone"
            case .speechRecognition:  return "Privacy_SpeechRecognition"
            case .accessibility:      return "Privacy_Accessibility"
            case .screenRecording:    return "Privacy_ScreenCapture"
            case .privacyList:        return "Privacy"
            }
        }
    }

    static func openPrivacySettings(_ pane: PrivacyPane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.anchor)")!
        NSWorkspace.shared.open(url)
    }
}
