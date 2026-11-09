import ApplicationServices
import Sparkle
import SwiftUI

@main
struct NemoNoiseApp: App {
    @State private var controller: RecordingController
    @State private var translationController: TranslationController
    @State private var meetingController: MeetingController
    @State private var pipelineProvider: PipelineProvider
    @State private var permissions = PermissionService()

    private let updaterDelegate = UpdaterFeedProvider()
    private let updaterController: SPUStandardUpdaterController
    private let mutex = RecordingMutex()

    init() {
        let updater = SPUStandardUpdaterController(startingUpdater: true,
                                                   updaterDelegate: updaterDelegate,
                                                   userDriverDelegate: nil)
        self.updaterController = updater
        _ = LogService.shared
        _ = CrashGuard.shared
        SentryService.initialize()

        // Build the assembly graph eagerly. Controllers, mutex, and
        // PipelineProvider are all cheap to construct — only engine init is
        // heavy, and PipelineProvider.bootstrap() pushes that to a background
        // thread.
        let recording = RecordingController()
        let translation = TranslationController()
        let meeting = MeetingController()
        let factory = ASREngineFactory(modelManager: recording.modelManager)
        let provider = PipelineProvider(
            factory: factory,
            modelManager: recording.modelManager,
            mutex: mutex,
            recording: recording,
            translation: translation,
            meeting: meeting
        )
        _controller = State(initialValue: recording)
        _translationController = State(initialValue: translation)
        _meetingController = State(initialValue: meeting)
        _pipelineProvider = State(initialValue: provider)

        // Kick off async engine load. Popover will see .loading briefly on
        // cold start, then .ready.
        provider.bootstrap()
    }

    var body: some Scene {
        MenuBarExtra {
            OnboardingGate(permissions: permissions) {
                MenuBarPopoverView(updater: updaterController.updater)
                    .environment(controller)
                    .environment(translationController)
                    .environment(meetingController)
                    .environment(pipelineProvider)
                    .environment(permissions)
            }
        } label: {
            MenuBarLabel()
                .environment(controller)
        }
        .menuBarExtraStyle(.window)

        // A regular Window (not the Settings scene): the Settings scene hosts
        // its content under a fixed title bar, so the sidebar starts one row
        // BELOW the traffic lights. A Window scene gives the sidebar full
        // height beside the traffic lights — the standard System Settings
        // look.
        Window("Settings", id: "settings") {
            SettingsView()
                .environment(controller)
                .environment(controller.modelManager)
                .environment(translationController)
                .environment(permissions)
        }
        .defaultSize(width: 720, height: 520)
        .commands { SettingsCommands() }
    }
}

/// Restores the standard ⌘,/Settings menu item now that settings live in a
/// `Window` scene instead of the `Settings` scene (which would own that item).
private struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

private struct OnboardingGate<Content: View>: View {
    @AppStorage(AppDefaults.Keys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    let permissions: PermissionService
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .onAppear {
                if !hasCompletedOnboarding {
                    OnboardingWindowController.show(permissions: permissions) {
                        hasCompletedOnboarding = true
                    }
                }
            }
    }
}

final class UpdaterFeedProvider: NSObject, SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        "https://gaozimeng0425.github.io/NemoNoise/appcast.xml"
    }
}
