import ApplicationServices
import Sparkle
import SwiftUI

@main
struct NemoNoiseApp: App {
    @MainActor
    private static func makePunctuator(modelManager: ModelManager) -> SherpaOfflinePunctuator? {
        guard let dir = modelManager.modelPath(for: .punctuation) else { return nil }
        let path = dir.appendingPathComponent("model.onnx").path
        guard let punctuator = SherpaOfflinePunctuator(modelPath: path) else {
            LogService.warn("Failed to load punctuation model at \(path)", category: "NemoNoiseApp")
            return nil
        }
        LogService.info("Punctuation processor enabled", category: "NemoNoiseApp")
        return punctuator
    }


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
                        let punctuator = Self.makePunctuator(modelManager: controller.modelManager)
                        let postProcessors: [any PostProcessor] = punctuator.map { [PunctuationProcessor(punctuator: $0)] } ?? []

                        // Dictation pipeline: the only sink wired here is the
                        // overlay (real-time partial display). Final delivery
                        // (clipboard, history, AX injection, toast) is handled
                        // by RecordingController via OutputDispatcher — see
                        // OutputDispatcher.swift for why the previous
                        // sink-based fan-out was unreliable.
                        let dictationSink: any Sink = OverlayProgressSink(target: controller)
                        let buildDictation: @MainActor () -> Void = {
                            guard let primary = try? factory.makeUserPreferred() else { return }
                            let fallback = factory.makeFallback()
                            let dictationPipeline = TranscriptionPipeline(
                                source: MicAudioSource(),
                                engine: primary,
                                postProcessors: postProcessors,
                                sink: dictationSink,
                                fallback: fallback
                            )
                            controller.bind(pipeline: dictationPipeline, mutex: mutex)
                        }
                        buildDictation()
                        controller.pipelineRebuildHandler = buildDictation

                        // Translation pipeline
                        if let engine = try? factory.makeForTranslation() {
                            let translationPipeline = TranscriptionPipeline(
                                source: SystemAudioSource(),
                                engine: engine,
                                postProcessors: postProcessors,
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
