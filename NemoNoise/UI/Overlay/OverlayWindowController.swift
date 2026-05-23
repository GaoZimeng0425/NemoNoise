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
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel?.animator().alphaValue = 1.0
            panel?.orderFrontRegardless()
        })
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel?.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let hostingView = NSHostingView(rootView:
            OverlayView()
                .environment(controller)
        )
        hostingView.sizingOptions = .preferredContentSize
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

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
        panel.alphaValue = 0.0
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
