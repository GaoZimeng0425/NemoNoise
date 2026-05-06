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
                modelSection
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
                Label("Apple Speech (online)", systemImage: "apple.logo").tag("apple")
                Label("SenseVoice (local, offline)", systemImage: "cpu").tag("sensevoice")
            }
            .pickerStyle(.radioGroup)

            if engineType == "apple" {
                Text("Uses Apple's on-device/cloud recognition. No download required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Uses SenseVoice via sherpa-onnx. Runs fully offline. Requires model download (~60 MB).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Model download

    private var modelSection: some View {
        Section("SenseVoice Model") {
            let mm = controller.modelManager

            switch mm.downloadState {
            case .notDownloaded:
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SenseVoiceSmall (int8)")
                            .font(.subheadline)
                        Text("~60 MB · Chinese, English, Japanese, Korean")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Download") { mm.startDownload() }
                        .buttonStyle(.borderedProminent)
                }

            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Downloading…")
                            .font(.subheadline)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Cancel") { mm.cancelDownload() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    ProgressView(value: progress)
                }

            case .downloaded:
                HStack {
                    Label("Model ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Delete", role: .destructive) { mm.deleteModel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

            case .error(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { mm.startDownload() }
                        .buttonStyle(.bordered)
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
        if engineType == "sensevoice" {
            return controller.modelManager.downloadState == .downloaded
                ? "SenseVoice (local)"
                : "Apple Speech (model not downloaded)"
        }
        return "Apple Speech"
    }
}
