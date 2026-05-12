import AppKit
import SwiftUI

final class OnboardingWindowController {
    private static var activePanel: NSPanel?

    static func show(onComplete: @escaping () -> Void) {
        let hostingView = NSHostingView(rootView:
            OnboardingView(onComplete: {
                onComplete()
                activePanel?.close()
                activePanel = nil
            })
        )
        hostingView.sizingOptions = .preferredContentSize

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
        panel.contentView = hostingView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        activePanel = panel
    }
}
