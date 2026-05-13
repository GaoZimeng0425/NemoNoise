import AppKit
import SwiftUI

final class OnboardingWindowController {
    private static var activePanel: NSPanel?

    static func show(onComplete: @escaping () -> Void) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome to NemoNoise"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let hostingView = NSHostingView(rootView:
            OnboardingView(onComplete: {
                onComplete()
                panel.orderOut(nil)
                panel.close()
            })
        )
        hostingView.sizingOptions = .preferredContentSize

        panel.contentView = hostingView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        activePanel = panel
    }
}
