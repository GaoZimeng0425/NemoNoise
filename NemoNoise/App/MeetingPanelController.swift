import AppKit
import SwiftUI

/// Non-activating floating panel showing the live meeting transcript. Unlike
/// the subtitle overlay it accepts mouse events: the user can scroll the
/// history and drag the panel out of the way.
final class MeetingPanelController {
    private var panel: NSPanel?
    private let controller: MeetingController

    init(controller: MeetingController) {
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
            // AppKit runs animation completion handlers on the main thread.
            MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let hostingView = NSHostingView(rootView:
            MeetingPanelView()
                .environment(controller)
        )
        // The WINDOW drives the size (positionOnActiveScreen sets an explicit
        // frame); SwiftUI fills it. `preferredContentSize` collapses to ~0
        // here on macOS 26 — MeetingPanelView roots at maxWidth/maxHeight
        // .infinity + glassEffect whose preferred size is empty (same family
        // as the toast 0×0 bug) — leaving a 380×560 shell with invisible
        // content.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = false
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
        let targetWidth = min(screenFrame.width * 0.28, 380)
        let targetHeight = min(screenFrame.height * 0.6, 560)
        let x = screenFrame.maxX - targetWidth - 24
        let y = screenFrame.midY - targetHeight / 2
        panel.setFrame(NSRect(x: x, y: y, width: targetWidth, height: targetHeight), display: true)
    }
}
