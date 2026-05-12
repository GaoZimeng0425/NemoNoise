import SwiftUI

@main
struct NemoNoiseApp: App {
    @State private var controller = RecordingController()

    init() {
        _ = LogService.shared
    }

    var body: some Scene {
        MenuBarExtra {
            OnboardingGate {
                MenuBarPopoverView()
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
