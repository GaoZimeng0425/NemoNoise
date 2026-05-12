import SwiftUI

struct MenuBarPopoverView: View {
    @Environment(RecordingController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                Text("NemoNoise")
                    .font(.headline)
                Spacer()
            }

            Divider()

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let warning = engineFallbackWarning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Text(controller.hotkeyDisplayText)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()

            HStack {
                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .font(.subheadline)
        }
        .padding(16)
        .frame(width: 220)
    }

    private var statusColor: Color {
        switch controller.recordingState {
        case .ready: .green
        case .recording: .red
        case .processing: .orange
        }
    }

    private var statusText: String {
        switch controller.recordingState {
        case .idle: "Ready"
        case .recording: "Recording…"
        case .processing: "Processing…"
        }
    }

    private var engineFallbackWarning: String? {
        let choice = UserDefaults.standard.string(forKey: "engineType") ?? "apple"
        switch choice {
        case "sensevoice" where controller.modelManager.state(for: .senseVoice) != .downloaded:
            return "SenseVoice model not downloaded — using Apple Speech"
        case "paraformer" where controller.modelManager.state(for: .paraformer) != .downloaded:
            return "Paraformer model not downloaded — using Apple Speech"
        default:
            return nil
        }
    }
}

struct MenuBarLabel: View {
    @Environment(RecordingController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if controller.recordingState == .recording {
            if reduceMotion {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 1.5) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(.primary)
                            .frame(width: 2.5, height: menuBarHeight(index: i))
                    }
                }
                .frame(height: 16)
                .animation(.easeOut(duration: 0.1), value: controller.micLevel)
            }
        } else {
            Image(systemName: "waveform")
        }
    }

    private func menuBarHeight(index: Int) -> CGFloat {
        let level = CGFloat(controller.micLevel)
        let base: CGFloat = 4
        let maxExtra: CGFloat = 12
        let threshold = CGFloat(index) * 0.3
        let active = max(0, level - threshold) / 0.3
        return base + active * maxExtra
    }
}
