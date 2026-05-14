import Sparkle
import SwiftUI

@main
struct NemoNoiseApp: App {
    @State private var controller = RecordingController()
    @State private var translationController = TranslationController()
    private let updaterDelegate = UpdaterFeedProvider()
    private let updaterController: SPUStandardUpdaterController

    init() {
        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: updaterDelegate, userDriverDelegate: nil)
        self.updaterController = updater
        _ = LogService.shared
        _ = CrashGuard.shared
        SentryService.initialize()
    }

    var body: some Scene {
        MenuBarExtra {
            OnboardingGate {
                MenuBarPopoverView(updater: updaterController.updater)
                    .environment(controller)
                    .environment(translationController)
                    .task {
                        translationController.setRecordingController(controller)
                        // Assemble translation pipeline now that both controllers exist.
                        let factory = ASREngineFactory(modelManager: controller.modelManager)
                        if let engine = try? factory.makeForTranslation() {
                            let pipeline = TranscriptionPipeline(
                                source: SystemAudioSource(),
                                engine: engine,
                                postProcessors: [],
                                sink: SubtitleOverlaySink(target: translationController),
                                fallback: nil
                            )
                            translationController.bind(pipeline: pipeline)
                        }
                        controller.onTranslationActiveCheck = { [translationController] in
                            translationController.isActive
                        }
                        translationController.startHotkeyMonitoring()
                    }
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
