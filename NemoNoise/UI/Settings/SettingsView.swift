import SwiftUI

struct SettingsView: View {
    @Environment(RecordingController.self) private var controller
    @AppStorage("engineType") private var engineType = "apple"
    @AppStorage("showEmotionTags") private var showEmotionTags = true
    @AppStorage("languagePreference") private var languagePreference = "Auto-detect"

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            engineTab
                .tabItem { Label("Engine", systemImage: "cpu") }

            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            displayTab
                .tabItem { Label("Display", systemImage: "paintbrush") }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 380)
    }

    // MARK: - General tab

    private var generalTab: some View {
        Form {
            recordingModeSection
            languageSection
            aboutSection
        }
    }

    // MARK: - Engine tab

    private var engineTab: some View {
        Form {
            engineSection
            if engineType == "sensevoice" {
                modelSection(for: .senseVoice)
            } else if engineType == "paraformer" {
                modelSection(for: .paraformer)
            }
        }
    }

    // MARK: - Shortcuts tab

    private var shortcutsTab: some View {
        Form {
            shortcutsSection
        }
    }

    // MARK: - Display tab

    private var displayTab: some View {
        Form {
            Section("Overlay") {
                Toggle("Show emotion tags", isOn: $showEmotionTags)
                Text("Display emotion indicators from SenseVoice after each sentence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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

    // MARK: Recording mode

    private var recordingModeSection: some View {
        Section("Recording Mode") {
            Picker("Mode", selection: Binding(
                get: { controller.recordingMode },
                set: { controller.recordingMode = $0 }
            )) {
                Text("Push to Talk (hold ⌥)").tag(RecordingMode.pushToTalk)
                Text("Toggle (press ⌥ to start/stop)").tag(RecordingMode.toggle)
            }
            .pickerStyle(.radioGroup)

            Text(controller.recordingMode == .pushToTalk
                 ? "Hold Option key to record. Release to stop."
                 : "Press Option key to start recording. Press again to stop.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        Section("Shortcuts") {
            Picker("Activation Key", selection: Binding(
                get: { controller.hotkeyMonitor.hotkeyOption },
                set: { UserDefaults.standard.set($0.rawValue, forKey: "hotkeyOption") }
            )) {
                ForEach(HotkeyOption.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
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

    // MARK: Language

    private var languageSection: some View {
        Section("Language") {
            Picker("Recognition Language", selection: $languagePreference) {
                ForEach(LanguagePreference.allCases) { lang in
                    Text(lang.rawValue).tag(lang.rawValue)
                }
            }

            Text("Auto-detect works best for mixed Chinese/English content. Select a specific language for faster, more accurate results.")
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
