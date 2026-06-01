import SwiftUI

struct OverlayView: View {
    @Environment(RecordingController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPulsing = false
    @Namespace private var glassNS

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                // Header stays a compact capsule so its edges keep the curved
                // Liquid Glass lensing/highlight even when transcript appears.
                headerBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("header", in: glassNS)

                if shouldShowTranscript {
                    // A separate glass blob; within the container's 8pt spacing
                    // it fluidly merges with the header instead of growing the
                    // header into one big flat (frosted-looking) card.
                    transcriptArea
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        .glassEffectID("transcript", in: glassNS)
                        .transition(.opacity)
                }
            }
        }
        .frame(minWidth: 360, maxWidth: 520)
        // Transparent breathing room so the glass's own soft shadow/highlight
        // renders fully instead of being clipped at the (now shadowless,
        // borderless, clear) window edge.
        .padding(20)
        .animation(.smooth(duration: 0.4), value: controller.recordingState)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: shouldShowTranscript)
    }

    private var shouldShowTranscript: Bool {
        !(controller.recordingState == .recording && !controller.isStreaming)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            statusIndicator

            Text(timerText)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Spacer()

            SpectrumBarsView(
                spectrum: controller.spectrum,
                isActive: controller.recordingState == .recording,
                barCount: 16
            )

            engineNameChip
        }
    }

    private var engineNameChip: some View {
        Label(controller.currentEngineLabel, systemImage: "cpu")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .opacity(controller.recordingState == .recording && isPulsing ? 0.42 : 1.0)
                .animation(statusPulseAnimation, value: isPulsing)
                .onAppear { isPulsing = true }
                .accessibilityHidden(true)
            
            Text(statusText)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
    }

    private var statusColor: Color {
        switch controller.recordingState {
        case .ready: return .secondary
        case .recording: return .red
        case .processing: return .blue
        case .failed: return .orange
        }
    }

    private var statusPulseAnimation: Animation? {
        guard controller.recordingState == .recording, !reduceMotion else { return .default }
        return .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
    }

    private var timerText: String {
        switch controller.recordingState {
        case .recording:
            let minutes = Int(controller.recordingDuration) / 60
            let seconds = Int(controller.recordingDuration) % 60
            return String(format: "%d:%02d", minutes, seconds)
        case .processing:
            return "--:--"
        case .ready:
            return "0:00"
        case .failed:
            return "--:--"
        }
    }
    
    private var statusText: String {
        switch controller.recordingState {
        case .ready: return "Ready"
        case .recording: return "Recording"
        case .processing: return "Processing"
        case .failed: return "Error"
        }
    }

    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.confirmedSegments.isEmpty || !controller.partialText.isEmpty {
                inlineTranscript
                    .transition(.opacity)
            }

            // Empty State / Listening Prompt
            if controller.isListeningSilence && controller.confirmedSegments.isEmpty && controller.partialText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "mic")
                        .foregroundStyle(.secondary)
                    Text("Listening...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: controller.confirmedSegments.count)
    }

    /// All confirmed segments + the in-flight partial concatenated into a
    /// single Text so the whole utterance stays on one line. The partial
    /// preserves its italic / secondary tint via Text composition. Head
    /// truncation keeps the tail (most recent words) visible when overflow.
    private var inlineTranscript: some View {
        let confirmedJoined = controller.confirmedSegments
            .map { $0.text.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: " ")
        let partial = controller.partialText.replacingOccurrences(of: "\n", with: " ")

        let confirmedPart = Text(confirmedJoined)
            .font(.system(size: 19, weight: .medium))
            .foregroundColor(.primary)

        let separator = (confirmedJoined.isEmpty || partial.isEmpty) ? Text("") : Text(" ")

        let partialPart = Text(partial)
            .font(.system(size: 18, weight: .regular))
            .italic()
            .foregroundColor(.secondary)

        return (confirmedPart + separator + partialPart)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}
