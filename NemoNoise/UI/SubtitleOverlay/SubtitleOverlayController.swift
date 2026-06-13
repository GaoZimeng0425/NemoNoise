import AppKit
import SwiftUI

final class SubtitleOverlayController {
    private var panel: NSPanel?
    private let controller: TranslationController

    init(controller: TranslationController) {
        self.controller = controller
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
            SubtitleOverlayView()
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
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
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
        let screenFrame = screen.visibleFrame
        let targetWidth = min(screenFrame.width - 80, 640)
        let targetHeight = min(screenFrame.height * 0.55, 620)
        let x = screenFrame.midX - targetWidth / 2
        let y = screenFrame.minY + 80
        panel.setFrame(NSRect(x: x, y: y, width: targetWidth, height: targetHeight), display: true)
    }
}
