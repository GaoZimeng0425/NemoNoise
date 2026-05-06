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
        .recordingErrorAlert()
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
        Text(controller.recordingState == .processing ? "Processing…" : "Listening…")
            .font(.caption)
            .foregroundStyle(.secondary)
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
