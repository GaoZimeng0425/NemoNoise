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
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = hostingView

        // Anchor on the screen under the mouse so multi-display setups land
        // the toast where the user is looking — `NSScreen.main` follows the
        // key window which may be on a different display.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let screenRect = screen.visibleFrame

        // Force a fixed panel width so positioning is deterministic regardless
        // of what NSHostingView.fittingSize reports.
        let panelWidth: CGFloat = 420
        let panelHeight = fittingSize.height
        let x = screenRect.midX - panelWidth / 2

        // Vertically: 30% from the top of the visible frame — well above the
        // bottom HUD and clearly in the user's natural reading area, but not
        // so high it crowds the menubar.
        let targetY = screenRect.maxY - (screenRect.height * 0.30) - panelHeight / 2

        LogService.info(
            "Toast position — screen=\(screenRect) panelWidth=\(panelWidth) panelHeight=\(panelHeight) x=\(x) y=\(targetY)",
            category: "Toast"
        )

        let startFrame = NSRect(x: x, y: targetY - 40, width: panelWidth, height: panelHeight)
        let endFrame = NSRect(x: x, y: targetY, width: panelWidth, height: panelHeight)

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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: style.icon)
                .font(.callout.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(style.color)

            Text(message)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: 420, alignment: .leading)
        .glassEffect(.regular, in: .capsule)
    }
}
