import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Observation

@MainActor
@Observable
final class PermissionService {
    var isAXTrusted: Bool
    var hasScreenRecording: Bool
    var micStatus: AVAuthorizationStatus

    private var timer: Timer?

    init() {
        self.isAXTrusted = AXIsProcessTrusted()
        self.hasScreenRecording = CGPreflightScreenCaptureAccess()
        self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        startPolling()
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        if ax != isAXTrusted { isAXTrusted = ax }
        let sr = CGPreflightScreenCaptureAccess()
        if sr != hasScreenRecording { hasScreenRecording = sr }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != micStatus { micStatus = mic }
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }
}
