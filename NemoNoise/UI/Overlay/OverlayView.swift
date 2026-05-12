import SwiftUI

struct OverlayView: View {
    @Environment(RecordingController.self) private var controller
    @AppStorage("showEmotionTags") private var showEmotionTags = true
    
    @State private var isPulsing = false
    @State private var showFallbackToast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            if shouldShowTranscript {
                Divider().opacity(0.3)
                transcriptArea
            }
        }
        .frame(minWidth: 360, maxWidth: 520)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThickMaterial)
                .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        }
        .overlay(alignment: .bottom) {
            if showFallbackToast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.caption)
                    Text(controller.toastMessage)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.7), in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 8)
            }
        }
        .onChange(of: controller.showToast) { _, newValue in
            withAnimation(.easeOut(duration: 0.3)) {
                showFallbackToast = newValue
            }
        }
        .padding(12)
        .alert("Accessibility Permission Required", isPresented: Binding(
            get: { controller.showAccessibilityGuide },
            set: { controller.showAccessibilityGuide = $0 }
        )) {
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("NemoNoise needs Accessibility permission to inject text into other apps.\n\nGo to System Settings → Privacy & Security → Accessibility, then enable NemoNoise.")
        }
        .alert("Error", isPresented: Binding(
            get: { controller.showErrorAlert },
            set: { controller.showErrorAlert = $0 }
        )) {
            Button("OK") { controller.showErrorAlert = false }
        } message: {
            Text(controller.errorMessage)
        }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                        HStack(alignment: .lastTextBaseline, spacing: 8) {
                            Text(segment.text)
                                .font(.system(size: 19, weight: .medium, design: .rounded))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            if showEmotionTags, let emotion = segment.emotion {
                                emotionTag(emotion)
                            }
                        }
                        .transition(.asymmetric(insertion: .push(from: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                }
            }

            // Partial Text
            if !controller.partialText.isEmpty {
                Text(controller.partialText)
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .italic()
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: controller.confirmedSegments.count)
    }

    private func emotionTag(_ emotion: String) -> some View {
        Text(emotion)
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.blue.opacity(0.15), in: Capsule())
            .foregroundStyle(.blue)
    }
}
