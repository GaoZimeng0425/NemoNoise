import SwiftUI

// MARK: - Menu Bar Popover

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

            Text("Hold **⌥ Option** to record")
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
        case .idle: .green
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
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(RecordingController.self) private var controller
    @AppStorage("engineType") private var engineType = "apple"

    var body: some View {
        Form {
            engineSection
            if engineType == "sensevoice" {
                modelSection(for: .senseVoice)
            } else if engineType == "paraformer" {
                modelSection(for: .paraformer)
            }
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .navigationTitle("NemoNoise")
    }

    // MARK: Engine picker

    private var engineSection: some View {
        Section("Speech Engine") {
            Picker("Engine", selection: $engineType) {
                Label("Apple Speech", systemImage: "apple.logo").tag("apple")
                Label("SenseVoice (offline)", systemImage: "cpu").tag("sensevoice")
                Label("Paraformer (streaming)", systemImage: "waveform").tag("paraformer")
            }
            .pickerStyle(.radioGroup)

            switch engineType {
            case "apple":
                Text("Uses Apple's on-device/cloud recognition. No download required.")
                    .font(.caption).foregroundStyle(.secondary)
            case "sensevoice":
                Text("SenseVoice — fully offline. Chinese + 5 languages. Emotion detection. Requires ~60 MB download.")
                    .font(.caption).foregroundStyle(.secondary)
            case "paraformer":
                Text("Paraformer — streaming Chinese ASR with real-time partial results. Requires ~50 MB download.")
                    .font(.caption).foregroundStyle(.secondary)
            default: EmptyView()
            }
        }
    }

    // MARK: Model download

    private func modelSection(for descriptor: ModelDescriptor) -> some View {
        Section("\(descriptor.displayName) Model") {
            let mm = controller.modelManager

            switch mm.state(for: descriptor) {
            case .notDownloaded:
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.displayName).font(.subheadline)
                        Text("\(descriptor.downloadSize) · \(descriptor.detail)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Download") { mm.startDownload(descriptor) }
                        .buttonStyle(.borderedProminent)
                }
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Downloading…").font(.subheadline)
                        Spacer()
                        Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
                        Button("Cancel") { mm.cancelDownload(descriptor) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    ProgressView(value: progress)
                }
            case .downloaded:
                HStack {
                    Label("Model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Delete", role: .destructive) { mm.deleteModel(descriptor) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            case .error(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Download failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { mm.startDownload(descriptor) }.buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: "0.1.0")
            LabeledContent(
                "Active engine",
                value: activeEngineLabel
            )
        }
    }

    private var activeEngineLabel: String {
        switch engineType {
        case "sensevoice":
            return controller.modelManager.state(for: .senseVoice) == .downloaded
                ? "SenseVoice (local)" : "Apple Speech (model not downloaded)"
        case "paraformer":
            return controller.modelManager.state(for: .paraformer) == .downloaded
                ? "Paraformer (streaming)" : "Apple Speech (model not downloaded)"
        default:
            return "Apple Speech"
        }
    }
}
