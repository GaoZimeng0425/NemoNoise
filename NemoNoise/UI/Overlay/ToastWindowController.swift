import AppKit
import SwiftUI

enum ToastStyle {
    case info
    case success
    case warning
    case error

    var icon: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

final class ToastWindowController {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(_ message: String, style: ToastStyle = .info, duration: TimeInterval = 3.5) {
        dismissTask?.cancel()

        removePanel()

        let hostingView = NSHostingView(rootView: ToastCapsule(message: message, style: style))
        hostingView.sizingOptions = .preferredContentSize
        let fittingSize = hostingView.fittingSize

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: fittingSize.width, height: fittingSize.height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = hostingView

        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        let x = screenRect.midX - fittingSize.width / 2
        let targetY = screenRect.minY + 24
        let startFrame = NSRect(x: x, y: targetY - 40, width: fittingSize.width, height: fittingSize.height)
        let endFrame = NSRect(x: x, y: targetY, width: fittingSize.width, height: fittingSize.height)

        p.setFrame(startFrame, display: false)
        p.makeKeyAndOrderFront(nil)
        panel = p

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(endFrame, display: true)
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    static func dismiss() {
        guard let p = panel else { return }
        let frame = p.frame
        let slideOut = NSRect(x: frame.origin.x, y: frame.origin.y - 40, width: frame.width, height: frame.height)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(slideOut, display: true)
            p.animator().alphaValue = 0
        }, completionHandler: {
            removePanel()
        })
    }

    private static func removePanel() {
        panel?.close()
        panel = nil
    }
}

private struct ToastCapsule: View {
    let message: String
    let style: ToastStyle

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(style.color)

            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}
