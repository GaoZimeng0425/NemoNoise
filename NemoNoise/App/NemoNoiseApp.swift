import Sparkle
import SwiftUI

@main
struct NemoNoiseApp: App {
    @State private var controller = RecordingController()
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
        }
    }
}

private struct OnboardingGate: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    let content: AnyView

    init(@ViewBuilder content: () -> some View) {
        self.content = AnyView(content())
    }

    var body: some View {
        content
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
