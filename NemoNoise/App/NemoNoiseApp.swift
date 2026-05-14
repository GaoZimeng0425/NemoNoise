import ApplicationServices
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
                        let mutex = RecordingMutex()
                        let factory = ASREngineFactory(modelManager: controller.modelManager)

                        // Dictation pipeline
                        if let primary = try? factory.makeUserPreferred() {
                            let fallback = try? factory.makeFallback()
                            let dictationSink = BroadcastSink([
                                OverlayProgressSink(target: controller),
                                TextInjectorSink(
                                    injector: controller.injector,
                                    clipboardFallback: ClipboardSink(),
                                    onInjectionFailed: {
                                        Task { @MainActor in
                                            if !AXIsProcessTrusted() {
                                                AccessibilityAlert.present()
                                            }
                                            ToastWindowController.show("Copied to clipboard", style: .success)
                                        }
                                    }
                                )
                            ])
                            let dictationPipeline = TranscriptionPipeline(
                                source: MicAudioSource(),
                                engine: primary,
                                postProcessors: [],
                                sink: dictationSink,
                                fallback: fallback
                            )
                            controller.bind(pipeline: dictationPipeline, mutex: mutex)
                        }

                        // Translation pipeline
                        if let engine = try? factory.makeForTranslation() {
                            let translationPipeline = TranscriptionPipeline(
                                source: SystemAudioSource(),
                                engine: engine,
                                postProcessors: [],
                                sink: SubtitleOverlaySink(target: translationController),
                                fallback: nil
                            )
                            translationController.bind(pipeline: translationPipeline, mutex: mutex)
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
