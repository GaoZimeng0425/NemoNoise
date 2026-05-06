import SwiftUI

struct OverlayView: View {
    @Environment(RecordingController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            transcriptArea
        }
        .frame(minWidth: 320, maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
        .shadow(radius: 8, y: 4)
        .padding(12)
        .alert("Accessibility Permission Required", isPresented: Binding(
            get: { controller.showAccessibilityGuide },
            set: { controller.showAccessibilityGuide = $0 }
        )) {
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("NemoNoise needs Accessibility permission to inject text into other apps.\n\nGo to System Settings → Privacy & Security → Accessibility, then enable NemoNoise.")
        }
        .alert("Error", isPresented: Binding(
            get: { controller.showErrorAlert },
            set: { controller.showErrorAlert = $0 }
        )) {
            Button("OK") { controller.showErrorAlert = false }
        } message: {
            Text(controller.errorMessage)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            recordingIndicator
            timerLabel
            Spacer()
            micLevelView
            closeButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var recordingIndicator: some View {
        Circle()
            .fill(controller.recordingState == .recording ? Color.red : Color.gray)
            .frame(width: 8, height: 8)
            .opacity(controller.recordingState == .recording ? 1 : 0.4)
    }

    private var timerLabel: some View {
        Text(timerText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private var timerText: String {
        switch controller.recordingState {
        case .recording:
            let minutes = Int(controller.recordingDuration) / 60
            let seconds = Int(controller.recordingDuration) % 60
            return String(format: "%d:%02d", minutes, seconds)
        case .processing:
            return "Processing…"
        case .idle:
            return "Ready"
        }
    }

    private var micLevelView: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(index: i))
                    .frame(width: 3, height: barHeight(index: i))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.05), value: controller.micLevel)
    }

    private var closeButton: some View {
        Button {
            // Cancel and hide via controller — actual hide happens when state resets
        } label: {
            Image(systemName: "xmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(controller.confirmedSegments) { segment in
                HStack(alignment: .top, spacing: 4) {
                    Text(segment.text)
                        .font(.system(size: 20))
                        .foregroundStyle(.primary)
                    if let emotion = segment.emotion {
                        Text(emotion)
                            .font(.system(size: 18))
                    }
                }
            }

            if !controller.partialText.isEmpty {
                Text(controller.partialText)
                    .font(.system(size: 18))
                    .italic()
                    .foregroundStyle(.secondary)
            }

            if controller.isListeningSilence && controller.confirmedSegments.isEmpty && controller.partialText.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "ear")
                        .foregroundStyle(.secondary)
                    Text("Listening… speak now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            if controller.showCopyButton {
                Button("Copy to Clipboard") {
                    controller.copyToClipboard()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func barHeight(index: Int) -> CGFloat {
        let level = CGFloat(controller.micLevel)
        let threshold = CGFloat(index) / 5.0
        return level > threshold ? (8 + CGFloat(index) * 2) : 4
    }

    private func barColor(index: Int) -> Color {
        let level = CGFloat(controller.micLevel)
        let threshold = CGFloat(index) / 5.0
        return level > threshold ? .green : Color.secondary.opacity(0.3)
    }
}

struct MenuBarLabel: View {
    @Environment(RecordingController.self) private var controller

    var body: some View {
        Image(systemName: controller.recordingState == .recording ? "mic.fill" : "mic")
            .symbolEffect(.pulse, isActive: controller.recordingState == .recording)
    }
}
