import AppKit
import SwiftUI

/// Resizable, activatable window showing the ENTIRE meeting transcript live
/// (the floating panel keeps only a recent slice visible). Opened from the
/// panel's expand button; text is selectable and copyable.
@MainActor
final class FullTranscriptWindowController {
    private var panel: NSPanel?

    func show(controller: MeetingController) {
        if panel == nil {
            let hosting = NSHostingView(
                rootView: FullTranscriptView(controller: controller)
            )
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            p.title = "Meeting Transcript"
            p.isReleasedWhenClosed = false
            p.level = .floating
            p.setFrameAutosaveName("FullTranscriptWindow")
            p.contentView = hosting
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.orderOut(nil)
    }
}

private struct FullTranscriptView: View {
    let controller: MeetingController
    @State private var isAtBottom = true
    @State private var hasNewWhileScrolledUp = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(controller.meetingLines.count) lines · \(controller.durationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy All") {
                    let text = controller.meetingLines
                        .map { "[\(Self.timestamp($0))] \($0.track.label): \($0.text)" }
                        .joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(controller.meetingLines) { line in
                            lineRow(line)
                                .id(line.id)
                        }
                        if controller.meetingLines.isEmpty {
                            Text("Listening…")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 20)
                        }
                        Color.clear.frame(height: 1).id("bottom-anchor")
                    }
                    .padding(12)
                    .background(ScrollBottomTracker(isAtBottom: $isAtBottom))
                }
                .overlay(alignment: .bottom) {
                    if hasNewWhileScrolledUp {
                        Button {
                            hasNewWhileScrolledUp = false
                            withAnimation(.smooth(duration: 0.2)) {
                                proxy.scrollTo("bottom-anchor", anchor: .bottom)
                            }
                        } label: {
                            Label("New messages", systemImage: "arrow.down")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(.thinMaterial))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                    }
                }
                // Scrolling back down by hand clears the pill too, not only a tap.
                .onChange(of: isAtBottom) { _, atBottom in
                    if atBottom { hasNewWhileScrolledUp = false }
                }
                .onChange(of: controller.meetingLines.count) { _, _ in
                    if isAtBottom {
                        withAnimation(.smooth(duration: 0.2)) {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
                    } else {
                        hasNewWhileScrolledUp = true
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func lineRow(_ line: MeetingLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timestamp(line))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(line.track.label)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(line.track == .me ? Color.blue.opacity(0.18) : Color.green.opacity(0.18))
                )
                .foregroundStyle(line.track == .me ? .blue : .green)
            Text(line.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func timestamp(_ line: MeetingLine) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: line.timestamp)
    }
}
