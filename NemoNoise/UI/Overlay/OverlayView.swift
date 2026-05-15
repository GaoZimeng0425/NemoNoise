import SwiftUI

struct OverlayView: View {
    @Environment(RecordingController.self) private var controller

    @State private var isPulsing = false
    @Namespace private var glassNS

    private var statusGlass: Glass {
        GlassTint.forHUD(controller.recordingState).map { Glass.regular.tint($0) } ?? Glass.regular
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                headerBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(statusGlass, in: .capsule)
                    .glassEffectID("status", in: glassNS)

                if shouldShowTranscript {
                    transcriptArea
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        .glassEffectID("transcript", in: glassNS)
                        .transition(.opacity)
                }
            }
        }
        .frame(minWidth: 360, maxWidth: 520)
        .animation(.smooth(duration: 0.4), value: controller.recordingState)
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
            
            LiveWaveformView(
                micLevel: controller.micLevel,
                isRecording: controller.recordingState == .recording
            )
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7), value: controller.micLevel)
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(controller.recordingState == .recording ? Color.red : Color.gray)
                .frame(width: 8, height: 8)
                .opacity(isPulsing ? 0.4 : 1.0)
                .animation(controller.recordingState == .recording ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isPulsing)
                .onAppear { isPulsing = true }
            
            Text(statusText)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(controller.recordingState == .recording ? .primary : .secondary)
        }
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
        case .ready: return "READY"
        case .recording: return "RECORDING"
        case .processing: return "THINKING"
        case .failed: return "ERROR"
        }
    }

    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Confirmed Segments
            if !controller.confirmedSegments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.confirmedSegments) { segment in
                        Text(segment.text.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 19, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.asymmetric(insertion: .push(from: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                }
            }

            // Partial Text
            if !controller.partialText.isEmpty {
                Text(controller.partialText.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            // Empty State / Listening Prompt
            if controller.isListeningSilence && controller.confirmedSegments.isEmpty && controller.partialText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "mic.badge.waveform")
                        .foregroundStyle(.blue)
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing)
                    Text("I'm listening...")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: controller.confirmedSegments.count)
    }

}
