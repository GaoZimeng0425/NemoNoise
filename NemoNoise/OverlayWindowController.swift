import AppKit
import SwiftUI

final class OverlayWindowController: NSObject {
    private var panel: NSPanel?
    private let controller: RecordingController

    init(controller: RecordingController) {
        self.controller = controller
        super.init()
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        positionOnActiveScreen()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let hostingView = NSHostingView(rootView:
            OverlayView()
                .environment(controller)
                .environment(controller.recordingError)
        )
        hostingView.sizingOptions = .preferredContentSize

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView = hostingView
        return panel
    }

    private func positionOnActiveScreen() {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        panel.layoutIfNeeded()
        let size = panel.frame.size
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.minY + 48
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
