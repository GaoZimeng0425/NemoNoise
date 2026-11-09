import SwiftUI
import AVFoundation
import KeyboardShortcuts
import ServiceManagement
import Speech

/// System-Settings-style window: sidebar tabs (`.sidebarAdaptable`), one pane
/// per concern. General / Models / Permissions / Shortcuts / Corrections /
/// Vocabulary / History.
struct SettingsView: View {
    @Environment(RecordingController.self) private var controller
    @Environment(PermissionService.self) private var permissions
    @AppStorage(AppDefaults.Keys.engineType) private var engineType = AppDefaults.Defaults.engineType
    @AppStorage(AppDefaults.Keys.preferredMicUID) private var preferredMicUID = ""
    @AppStorage(AppDefaults.Keys.echoCancellation) private var echoCancellation = false
    @State private var availableMics: [AudioInputDevice] = []
    @State private var showExportAlert = false
    @State private var exportedLogPath = ""

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { generalTab }

            Tab("Models", systemImage: "arrow.down.circle") { modelsTab }

            Tab("Permissions", systemImage: "lock.shield") { permissionsTab }

            Tab("Shortcuts", systemImage: "keyboard") { shortcutsTab }

            Tab("Corrections", systemImage: "textformat.abc") { correctionsTab }

            Tab("Vocabulary", systemImage: "character.book.closed") { vocabularyTab }

            Tab("History", systemImage: "clock.arrow.circlepath") { historyTab }
        }
        .tabViewStyle(.sidebarAdaptable)
        .formStyle(.grouped)
        .frame(minWidth: 640, minHeight: 460)
        .onAppear {
            availableMics = AudioInputDeviceCatalog.availableInputDevices()
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

    // MARK: - General tab

    private var generalTab: some View {
        Form {
            engineSection
            audioInputSection
            transcriptSection
            startupSection
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

    // MARK: - Models tab

    /// All models, always visible — independent of the selected engine, so a
    /// missing model (failed download, manual cleanup) can be re-fetched
    /// without switching engines first.
    private var modelsTab: some View {
        Form {
            Section {
                Text("Models download to ~/Library/Application Support/NemoNoise/models. Downloads install atomically — a failed download never touches an existing model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(ModelManager.allDescriptors, id: \.id) { descriptor in
                modelSection(for: descriptor)
            }
        }
    }

    // MARK: - Permissions tab

    private var permissionsTab: some View {
        Form {
            Section("Required for dictation") {
                permissionRow(
                    icon: "mic.fill",
                    name: "Microphone",
                    detail: "Dictation and the meeting Me track",
                    status: micStatus
                ) { PermissionService.openPrivacySettings(.microphone) }

                permissionRow(
                    icon: "waveform.bubble",
                    name: "Speech Recognition",
                    detail: "Apple Speech engine (system and on-device)",
                    status: speechStatus
                ) { PermissionService.openPrivacySettings(.speechRecognition) }
            }

            Section("Feature permissions") {
                permissionRow(
                    icon: "cursorarrow.click.badge.clock",
                    name: "Accessibility",
                    detail: "Global hotkey and inserting text into the focused app",
                    granted: permissions.isAXTrusted
                ) { PermissionService.openPrivacySettings(.accessibility) }

                permissionRow(
                    icon: "display.trianglebadge.exclamationmark",
                    name: "Screen Recording",
                    detail: "Translation mode and the meeting fallback capture",
                    granted: permissions.hasScreenRecording
                ) { PermissionService.openPrivacySettings(.screenRecording) }

                // System Audio Recording (macOS 15+) has no status or preflight
                // API — the one-time prompt fires on the first meeting, and a
                // declined tap just delivers silence.
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System Audio Recording").font(.subheadline)
                        Text("Meeting Them track (process tap). The consent prompt appears on the first meeting start; if it was denied, re-enable it in the Privacy list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open Settings…") {
                        PermissionService.openPrivacySettings(.privacyList)
                    }
                    .controlSize(.small)
                }
            }

            Section {
                Text("Permission changes made in System Settings take a moment to be reflected here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var micStatus: PermissionStatus {
        switch permissions.micStatus {
        case .authorized: return .granted
        case .notDetermined: return .notRequested
        case .denied, .restricted: return .denied
        @unknown default: return .notRequested
        }
    }

    private var speechStatus: PermissionStatus {
        switch permissions.speechStatus {
        case .authorized: return .granted
        case .notDetermined: return .notRequested
        case .denied, .restricted: return .denied
        @unknown default: return .notRequested
        }
    }

    private enum PermissionStatus {
        case granted
        case notRequested
        case denied

        var label: String {
            switch self {
            case .granted: return "Authorized"
            case .notRequested: return "Not requested"
            case .denied: return "Denied"
            }
        }

        var color: Color {
            switch self {
            case .granted: return .green
            case .notRequested: return .secondary
            case .denied: return .red
            }
        }
    }

    private func permissionRow(icon: String,
                               name: String,
                               detail: String,
                               status: PermissionStatus,
                               open: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Label(status.label, systemImage: status == .granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(status.color)
                .labelStyle(.titleAndIcon)
            Button("Open Settings…", action: open)
                .controlSize(.small)
        }
    }

    private func permissionRow(icon: String,
                               name: String,
                               detail: String,
                               granted: Bool,
                               open: @escaping () -> Void) -> some View {
        permissionRow(icon: icon,
                      name: name,
                      detail: detail,
                      status: granted ? .granted : .denied,
                      open: open)
    }

    // MARK: - Shortcuts tab

    private var shortcutsTab: some View {
        Form {
            shortcutsSection
        }
    }

    // MARK: - Corrections tab

    private var correctionsTab: some View {
        CorrectionsView()
    }

    // MARK: - Vocabulary tab

    private var vocabularyTab: some View {
        VocabularyView()
    }

    // MARK: - History tab

    private var historyTab: some View {
        TranscriptHistoryView(store: controller.historyStore)
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
                id: "sensevoice",
                icon: "globe",
                title: "SenseVoice",
                summary: "Offline zh/en/ja/ko/yue ASR with emotion detection. Non-streaming.",
                status: mm.state(for: .senseVoice) == .downloaded ? .ready : .needsDownload("~230 MB")
            ),
            EngineOption(
                id: "qwen3",
                icon: "brain",
                title: "Qwen3-ASR 0.6B",
                summary: "Offline multilingual ASR. High quality but non-streaming.",
                status: mm.state(for: .qwen3) == .downloaded ? .ready : .needsDownload("~940 MB")
            ),
        ]
    }

    private var audioInputSection: some View {
        Section("Audio Input") {
            Picker("Microphone", selection: $preferredMicUID) {
                Text("System Default").tag("")
                ForEach(availableMics) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            Text("Used for voice input only. Translation mode always captures system audio.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Echo cancellation", isOn: $echoCancellation)
            Text("Suppresses speaker audio leaking into the built-in mic. Enables Apple's voice processing (AEC + noise suppression + AGC) — tuned for speech, may slightly affect non-voice audio. Takes effect on the next recording.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
        .onChange(of: engineType) { _, _ in
            controller.requestPipelineRebuild()
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        Section("Shortcuts") {
            LabeledContent("Activation Key:") {
                ShortcutRecorderField(name: .toggleRecording) { _ in
                    NotificationCenter.default.post(name: .recordingShortcutDidChange, object: nil)
                }
                .frame(width: 180)
            }

            LabeledContent("Translation Key:") {
                ShortcutRecorderField(name: .translationMode)
                    .frame(width: 180)
            }
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

            if !permissions.isAXTrusted {
                Label("Accessibility permission required for global hotkey — see Permissions", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    // MARK: Transcript cleanup

    @AppStorage(AppDefaults.Keys.llmTranscriptCleanup) private var llmTranscriptCleanup = false

    private var transcriptSection: some View {
        Section("Transcript") {
            Toggle("Clean Up Transcripts (Apple Intelligence)", isOn: $llmTranscriptCleanup)
            Text("Removes filler words and fixes obvious recognition errors before inserting text. History keeps the original transcript. If Apple Intelligence is unavailable or a result looks unreliable, the original text is inserted.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Startup

    @State private var loginItemApproved = true

    private var startupSection: some View {
        Section("Startup") {
            // Bound to the SYSTEM's registration state (SMAppService), not a
            // local preference — the two can drift when the user toggles it
            // in System Settings (FluidVoice's "prefers macOS state" rule).
            Toggle("Launch at Login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        ToastWindowController.show("Login item change failed: \(error.localizedDescription)", style: .error)
                    }
                    loginItemApproved = SMAppService.mainApp.status != .requiresApproval
                }
            ))
            if !loginItemApproved {
                Label("Needs approval in System Settings → General → Login Items", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear {
            loginItemApproved = SMAppService.mainApp.status != .requiresApproval
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
        case "sensevoice":
            return controller.modelManager.state(for: .senseVoice) == .downloaded
                ? "SenseVoice" : "Apple Speech (model not installed)"
        case "qwen3":
            return controller.modelManager.state(for: .qwen3) == .downloaded
                ? "Qwen3-ASR 0.6B" : "Apple Speech (model not installed)"
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

        var badge: (text: String, color: Color)? {
            switch self {
            case .ready: return nil
            case .needsDownload(let size): return ("Download required · \(size)", .orange)
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
