import SwiftUI
import KeyboardShortcuts
import ApplicationServices

struct SettingsView: View {
    @Environment(RecordingController.self) private var controller
    @AppStorage(AppDefaults.Keys.engineType) private var engineType = AppDefaults.Defaults.engineType
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
            // LSUIElement apps default to .accessory policy which suppresses
            // activation. Briefly switch to .regular so the Settings window
            // can come to the front; .onDisappear flips it back.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
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
            if engineType == "qwen3" {
                modelSection(for: .qwen3)
            }
            modelSection(for: .punctuation)
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

    private var engineOptions: [EngineOption] {
        let mm = controller.modelManager
        return [
            EngineOption(
                id: "apple",
                icon: "apple.logo",
                title: "Apple Speech",
                summary: "Uses Apple's on-device/cloud recognition. No download required.",
                status: .ready
            ),
            EngineOption(
                id: "paraformer",
                icon: "waveform",
                title: "Paraformer (streaming)",
                summary: "Streaming Chinese + English ASR with real-time partial results.",
                status: mm.state(for: .paraformer) == .downloaded ? .ready : .needsDownload("~240 MB")
            ),
            EngineOption(
                id: "qwen3",
                icon: "brain",
                title: "Qwen3-ASR 0.6B",
                summary: "Offline multilingual ASR. High quality but non-streaming.",
                status: mm.state(for: .qwen3) == .downloaded ? .ready : .needsDownload("~940 MB")
            ),
            EngineOption(
                id: "cloud",
                icon: "cloud",
                title: "Cloud Paraformer",
                summary: "Cloud ASR for higher accuracy. Requires internet connection.",
                status: cloudAPIKey.isEmpty ? .needsAPIKey : .ready
            ),
        ]
    }

    private var engineSection: some View {
        Section("Speech Engine") {
            VStack(spacing: 8) {
                ForEach(engineOptions, id: \.id) { option in
                    EngineCard(option: option, isSelected: engineType == option.id) {
                        engineType = option.id
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var cloudAPIKeySection: some View {
        Section("Cloud Engine") {
            SecureField("DashScope API Key", text: $cloudAPIKey)
                .textFieldStyle(.roundedBorder)
                .task(id: cloudAPIKey) {
                    // Debounce so we only touch Keychain after the user pauses typing.
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    if cloudAPIKey.isEmpty {
                        KeychainService.delete(key: KeychainService.Keys.cloudAPIKey)
                        if engineType == "cloud" { engineType = "paraformer" }
                    } else {
                        try? KeychainService.save(key: KeychainService.Keys.cloudAPIKey, value: cloudAPIKey)
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

            KeyboardShortcuts.Recorder("Translation Key:", name: .translationMode)
            Text("Toggle real-time translation mode. Captures system audio and displays bilingual subtitles.")
                .font(.caption).foregroundStyle(.secondary)

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

            if !CGPreflightScreenCaptureAccess() {
                Label("Screen recording permission required for translation mode", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
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
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(mm.modelDir(for: descriptor))
                    }
                    .buttonStyle(.bordered).controlSize(.small)
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
        case "qwen3":
            return controller.modelManager.state(for: .qwen3) == .downloaded
                ? "Qwen3-ASR 0.6B" : "Apple Speech (model not installed)"
        case "cloud":
            return cloudAPIKey.isEmpty
                ? "Apple Speech (API key not set)" : "Cloud Paraformer"
        default:
            return "Apple Speech"
        }
    }
}

// MARK: - Engine card

private struct EngineOption: Identifiable {
    let id: String
    let icon: String
    let title: String
    let summary: String
    let status: Status

    enum Status {
        case ready
        case needsDownload(String)  // size hint, e.g. "~240 MB"
        case needsAPIKey

        var badge: (text: String, color: Color)? {
            switch self {
            case .ready: return nil
            case .needsDownload(let size): return ("Download required · \(size)", .orange)
            case .needsAPIKey: return ("API key required", .orange)
            }
        }
    }
}

private struct EngineCard: View {
    let option: EngineOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : option.icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(option.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let badge = option.status.badge {
                        Label(badge.text, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(badge.color)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
