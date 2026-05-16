import ApplicationServices
import Sparkle
import SwiftUI

@main
struct NemoNoiseApp: App {
    @State private var controller: RecordingController
    @State private var translationController: TranslationController
    @State private var pipelineProvider: PipelineProvider

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
        let factory = ASREngineFactory(modelManager: recording.modelManager)
        let provider = PipelineProvider(
            factory: factory,
            modelManager: recording.modelManager,
            mutex: mutex,
            recording: recording,
            translation: translation
        )
        _controller = State(initialValue: recording)
        _translationController = State(initialValue: translation)
        _pipelineProvider = State(initialValue: provider)

        // Kick off async engine load. Popover will see .loading briefly on
        // cold start, then .ready.
        provider.bootstrap()
    }

    var body: some Scene {
        MenuBarExtra {
            OnboardingGate {
                MenuBarPopoverView(updater: updaterController.updater)
                    .environment(controller)
                    .environment(translationController)
                    .environment(pipelineProvider)
            }
        } label: {
            MenuBarLabel()
                .environment(controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
                .environment(controller.modelManager)
                .environment(translationController)
        }
    }
}

private struct OnboardingGate<Content: View>: View {
    @AppStorage(AppDefaults.Keys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .onAppear {
                if !hasCompletedOnboarding {
                    OnboardingWindowController.show {
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
