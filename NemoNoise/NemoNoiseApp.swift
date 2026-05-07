import SwiftUI

@main
struct NemoNoiseApp: App {
    @State private var controller = RecordingController()

    init() {
        _ = LogService.shared
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView()
                .environment(controller)
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
