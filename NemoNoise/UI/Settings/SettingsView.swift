import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Environment(RecordingController.self) private var controller
    @AppStorage("engineType") private var engineType = "paraformer"
    @State private var cloudAPIKey: String = ""
    @State private var showExportAlert = false
    @State private var exportedLogPath = ""

    var body: some View {
        TabView {
            engineTab
                .tabItem { Label("Engine", systemImage: "cpu") }

            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .onAppear {
            cloudAPIKey = KeychainService.load(key: KeychainService.Keys.cloudAPIKey) ?? ""
        }
    }

    // MARK: - Engine tab

    private var engineTab: some View {
        Form {
            cloudAPIKeySection
            engineSection
            if engineType == "paraformer" {
                modelSection(for: .paraformer)
            }
            privacySection
            aboutSection
        }
        .alert("Logs Exported", isPresented: $showExportAlert) {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(exportedLogPath, inFileViewerRootedAtPath: "")
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Sanitized logs saved to:\n\(exportedLogPath)")
        }
    }

    // MARK: - Shortcuts tab

    private var shortcutsTab: some View {
        Form {
            shortcutsSection
        }
    }

    // MARK: Engine picker

    private var engineSection: some View {
        Section("Speech Engine") {
            Picker("Engine", selection: $engineType) {
                Label("Paraformer (streaming)", systemImage: "waveform").tag("paraformer")
                if !cloudAPIKey.isEmpty {
                    Label("Cloud Paraformer", systemImage: "cloud").tag("cloud")
                }
                Label("Apple Speech", systemImage: "apple.logo").tag("apple")
            }
            .pickerStyle(.radioGroup)

            switch engineType {
            case "paraformer":
                Text("Streaming Chinese ASR with real-time partial results. Requires ~50 MB download.")
                    .font(.caption).foregroundStyle(.secondary)
            case "cloud":
                Text("Cloud-based Paraformer for higher accuracy. Requires internet connection and API key.")
                    .font(.caption).foregroundStyle(.secondary)
            case "apple":
                Text("Uses Apple's on-device/cloud recognition. No download required.")
                    .font(.caption).foregroundStyle(.secondary)
            default: EmptyView()
            }
        }
    }

    private var cloudAPIKeySection: some View {
        Section("Cloud Engine") {
            SecureField("DashScope API Key", text: $cloudAPIKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: cloudAPIKey) { _, newValue in
                    if newValue.isEmpty {
                        KeychainService.delete(key: KeychainService.Keys.cloudAPIKey)
                        if engineType == "cloud" {
                            engineType = "paraformer"
                        }
                    } else {
                        try? KeychainService.save(key: KeychainService.Keys.cloudAPIKey, value: newValue)
                    }
                }
            Text("Enter a DashScope API key to enable cloud-based Paraformer transcription.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        Section("Shortcuts") {
            KeyboardShortcuts.Recorder("Activation Key:", name: .toggleRecording) { _ in
                NotificationCenter.default.post(name: .recordingShortcutDidChange, object: nil)
            }

            Picker("Mode", selection: Binding(
                get: { controller.recordingMode },
                set: { controller.recordingMode = $0 }
            )) {
                ForEach(RecordingMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            if !AXIsProcessTrusted() {
                Label("Accessibility permission required for global hotkey", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .font(.caption)
            }
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section("Privacy") {
            Toggle("Enable Crash Reporting", isOn: Binding(
                get: { SentryService.isEnabled },
                set: { SentryService.isEnabled = $0 }
            ))
            Text("Send anonymous crash reports to help improve NemoNoise.")
                .font(.caption).foregroundStyle(.secondary)
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
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
            LabeledContent(
                "Active engine",
                value: activeEngineLabel
            )
            Button("Export Logs…") {
                if let path = LogService.exportLogs() {
                    exportedLogPath = path
                    showExportAlert = true
                }
            }
        }
    }

    private var activeEngineLabel: String {
        switch engineType {
        case "paraformer":
            return controller.modelManager.state(for: .paraformer) == .downloaded
                ? "Paraformer (streaming)" : "Apple Speech (model not downloaded)"
        case "cloud":
            return cloudAPIKey.isEmpty
                ? "Apple Speech (API key not set)" : "Cloud Paraformer"
        default:
            return "Apple Speech"
        }
    }
}
