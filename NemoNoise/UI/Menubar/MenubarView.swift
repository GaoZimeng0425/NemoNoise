import AppKit
import Sparkle
import SwiftUI

struct MenuBarPopoverView: View {
    @Environment(RecordingController.self) private var controller
    @Environment(TranslationController.self) private var translationController
    @Environment(MeetingController.self) private var meetingController
    @Environment(PipelineProvider.self) private var pipelineProvider
    @Environment(\.openWindow) private var openWindow
    let updater: SPUUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(controller.hotkeyDisplayText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let warning = engineFallbackWarning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if pipelineProvider.dictation == .loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Preparing engines…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if case .failed(let msg) = pipelineProvider.dictation {
                Text("Dictation: \(msg)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if case .failed(let msg) = pipelineProvider.translation {
                Text("Translation: \(msg)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(translationController.isActive ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Button(translationController.isActive ? "Stop Translation" : "Start Translation") {
                    translationController.toggle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(translationController.isActive ? .red : .primary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(meetingController.isActive ? Color.purple : Color.gray)
                        .frame(width: 8, height: 8)
                    Button(meetingButtonTitle) {
                        meetingController.toggle()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(meetingController.isActive ? .red : .primary)
                }
                if meetingController.isActive {
                    Text("\(meetingController.durationText) · Me: \(meetingController.meEngineLabel) · Them: \(meetingController.themEngineLabel)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if case .failed(let msg) = pipelineProvider.meeting {
                    Text("Meeting: \(msg)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Divider()

            Button("Check for Updates…") { updater.checkForUpdates() }
                .buttonStyle(.plain)
                .font(.subheadline)

            HStack {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                } label: {
                    Image(systemName: "gearshape")
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power")
                }
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
        case .failed: .red
        }
    }

    private var statusText: String {
        switch controller.recordingState {
        case .ready: "Ready"
        case .recording: "Recording…"
        case .processing: "Processing…"
        case .failed: "Error"
        }
    }

    private var meetingButtonTitle: String {
        switch meetingController.meetingState {
        case .idle: return "Start Meeting"
        case .recording: return "Stop Meeting"
        case .finishing: return "Saving…"
        }
    }

    private var engineFallbackWarning: String? {
        let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType) ?? AppDefaults.Defaults.engineType
        switch choice {
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
