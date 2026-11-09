import SwiftUI

/// Live meeting transcript panel: scrolling Me/Them history, per-track live
/// partials, duration, and per-track audio level dots.
struct MeetingPanelView: View {
    @Environment(MeetingController.self) private var controller
    @State private var isPulsing = false
    /// Scroll-follow state (muesli pattern): auto-scroll only while the user
    /// is at the bottom; scrolled-up pauses updates behind a "new messages"
    /// button instead of yanking the viewport.
    @State private var isAtBottom = true
    @State private var hasNewWhileScrolledUp = false

    private let cornerRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            transcriptList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        .clipShape(.rect(cornerRadius: cornerRadius))
        .padding(12)
        .animation(.smooth(duration: 0.24), value: controller.meetingState)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.meetingState == .recording ? .red : .secondary)
                .frame(width: 8, height: 8)
                .opacity(controller.meetingState == .recording && isPulsing ? 0.42 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }
                .accessibilityHidden(true)

            Text(controller.meetingState == .finishing ? "Saving…" : "Meeting")
                .font(.caption.weight(.semibold))

            Spacer()

            SpectrumBarsView(
                spectrum: controller.meSpectrum,
                isActive: controller.meetingState == .recording,
                barCount: 7,
                barColor: .blue,
                barSpacing: 2,
                barWidth: 2.5,
                maxHeight: 16,
                minHeight: 2
            )
            .help("Microphone (Me)")

            SpectrumBarsView(
                spectrum: controller.themSpectrum,
                isActive: controller.meetingState == .recording,
                barCount: 7,
                barColor: .green,
                barSpacing: 2,
                barWidth: 2.5,
                maxHeight: 16,
                minHeight: 2
            )
            .help("System audio (Them)")

            Text(controller.durationText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                controller.showFullTranscript()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Full transcript")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Transcript

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.meetingLines) { line in
                        lineView(line)
                            .id(line.id)
                    }
                    if !controller.meetingPartialMe.isEmpty {
                        partialView(text: controller.meetingPartialMe, track: .me)
                            .id("partial-me")
                    }
                    if !controller.meetingPartialThem.isEmpty {
                        partialView(text: controller.meetingPartialThem, track: .them)
                            .id("partial-them")
                    }
                    Color.clear.frame(height: 1).id("bottom-anchor")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
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

    private func lineView(_ line: MeetingLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.track.label)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(line.track == .me ? Color.blue.opacity(0.22) : Color.green.opacity(0.22))
                )
                .foregroundStyle(line.track == .me ? .blue : .green)
            Text(line.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func partialView(text: String, track: MeetingLine.Track) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(track.label)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(track == .me ? Color.blue.opacity(0.22) : Color.green.opacity(0.22))
                )
                .foregroundStyle(track == .me ? .blue : .green)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
        }
        .opacity(0.7)
    }
}

/// Reports whether the enclosing scroll view is at (or within ~24pt of) its
/// bottom. Uses NSClipView bounds-change notifications — muesli notes that
/// SwiftUI preference keys are unreliable for this on macOS.
struct ScrollBottomTracker: NSViewRepresentable {
    @Binding var isAtBottom: Bool

    final class TrackerView: NSView {
        var onBottomChange: ((Bool) -> Void)?
        private var observer: (any NSObjectProtocol)? = nil

        override func viewDidMoveToWindow() {
            install()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { remove() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func install() {
            remove()
            guard let clipView = enclosingScrollView?.contentView else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                self?.evaluate()
            }
            clipView.postsBoundsChangedNotifications = true
            evaluate()
        }

        private func remove() {
            if let token = observer {
                NotificationCenter.default.removeObserver(token)
                observer = nil
            }
        }

        private func evaluate() {
            guard let clipView = enclosingScrollView?.contentView else { return }
            let documentHeight = clipView.documentView?.fittingSize.height ?? 0
            let bottomEdge = clipView.bounds.maxY
            let atBottom = documentHeight - bottomEdge < 24
            onBottomChange?(atBottom)
        }

    }

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onBottomChange = { newValue in
            Task { @MainActor in
                isAtBottom = newValue
            }
        }
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {}
}
