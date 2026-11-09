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
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        var fittingSize = hostingView.fittingSize

        // On this OS `GlassEffectContainer` reports no intrinsic size to
        // NSHostingView — every toast in the logs measured 0×0, which clips
        // the capsule down to just the icon. Measure the capsule contents
        // (icon + text + paddings) as a floor.
        if fittingSize.width <= 1 || fittingSize.height <= 1 {
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            ]
            let textSize = (message as NSString).size(withAttributes: textAttributes)
            let maxWidth: CGFloat = 420  // matches ToastCapsule's frame(maxWidth:)
            let iconAndSpacing: CGFloat = 30  // icon ~20 + HStack spacing 10
            let horizontalPaddings: CGFloat = 76  // 18×2 capsule + 20×2 outer
            let width = ceil(min(textSize.width + iconAndSpacing + horizontalPaddings, maxWidth + horizontalPaddings))
            let height = ceil(max(textSize.height, 20) + 64)  // 12×2 capsule + 20×2 outer, 2-line headroom
            fittingSize = NSSize(width: width, height: height)
        }

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

        // Anchor on the screen under the mouse so multi-display setups land
        // the toast where the user is looking — `NSScreen.main` follows the
        // key window which may be on a different display.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let screenRect = screen.visibleFrame

        let panelWidth = fittingSize.width
        let panelHeight = fittingSize.height
        // Horizontally centered on the active screen.
        let x = screenRect.midX - panelWidth / 2

        // Vertically: centered at 30% of the visible-frame height up from the
        // bottom — sits in the lower third of the screen, near the user's
        // focus without crowding the very bottom edge.
        let targetY = screenRect.minY + (screenRect.height * 0.30) - panelHeight / 2

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
            // AppKit runs animation completion handlers on the main thread.
            MainActor.assumeIsolated { removePanel() }
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
    @Namespace private var glassNS

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: style.icon)
                    .font(.callout.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(style.color)

                Text(message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 420, alignment: .center)
            .glassEffect(.regular, in: .capsule)
            .glassEffectID("toast", in: glassNS)
        }
        .padding(20)
    }
}
