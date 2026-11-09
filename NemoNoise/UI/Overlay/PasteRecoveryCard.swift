import AppKit
import SwiftUI

/// Shown when text injection failed: the transcript is safe on the clipboard,
/// but the user gets a one-click "Insert again" affordance instead of having
/// to remember what happened (FluidVoice's paste-recovery pattern).
@MainActor
enum PasteRecoveryCard {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(text: String, injector: any TextInjecting) {
        dismiss()

        let hosting = NSHostingView(
            rootView: PasteRecoveryCardView(
                text: text,
                onRetry: {
                    dismiss()
                    Task { @MainActor in
                        _ = await injector.inject(text)
                    }
                },
                onDismiss: { dismiss() }
            )
        )
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = hosting

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - size.width / 2
        let y = visible.minY + visible.height * 0.24 - size.height / 2
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        p.orderFrontRegardless()
        panel = p

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    static func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct PasteRecoveryCardView: View {
    let text: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not inserted — text is on the clipboard")
                    .font(.callout.weight(.medium))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Button("Insert again", action: onRetry)
                .controlSize(.small)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(16)
    }
}
