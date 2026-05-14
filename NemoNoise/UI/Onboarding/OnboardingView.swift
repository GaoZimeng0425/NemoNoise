import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @AppStorage(AppDefaults.Keys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppDefaults.Keys.engineType) private var engineType = AppDefaults.Defaults.engineType
    @State private var currentStep = 0
    @State private var micPermissionGranted = false

    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
            stepContent
            stepFooter
        }
        .frame(width: 480, height: 360)
        .background(.ultraThickMaterial)
    }

    // MARK: - Step indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.3), value: currentStep)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0: micPermissionStep
        case 1: engineSelectionStep
        case 2: hotkeyStep
        default: EmptyView()
        }
    }

    // MARK: Step 1 — Microphone permission

    private var micPermissionStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Microphone Access")
                .font(.title2.bold())
            Text("NemoNoise needs microphone access to transcribe your voice.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if micPermissionGranted {
                Label("Microphone enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.bold())
            } else {
                Button("Enable Microphone") {
                    requestMicPermission()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Spacer()
        }
    }

    // MARK: Step 2 — Engine selection

    private var engineSelectionStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "cpu")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Choose Speech Engine")
                .font(.title2.bold())
            Text("Select the engine for speech recognition.")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                engineCard(tag: "paraformer", icon: "waveform", title: "Paraformer (streaming)", subtitle: "Real-time Chinese ASR with partial results. ~50 MB download.")
                engineCard(tag: "apple", icon: "apple.logo", title: "Apple Speech", subtitle: "Uses Apple's built-in recognition. No download needed.")
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }

    private func engineCard(tag: String, icon: String, title: String, subtitle: String) -> some View {
        Button {
            engineType = tag
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(engineType == tag ? Color.accentColor : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if engineType == tag {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(engineType == tag ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engineType == tag ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 3 — Hotkey

    private var hotkeyStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "keyboard")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Push to Talk")
                .font(.title2.bold())

            HStack(spacing: 24) {
                keyCap("⌥ Option")
                Text("or")
                    .foregroundStyle(.secondary)
                keyCap("⌘ Right Cmd")
            }

            Text("Hold the key to record your voice.\nRelease to transcribe and inject text.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func keyCap(_ text: String) -> some View {
        Text(text)
            .font(.system(.title3, design: .rounded, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
            )
    }

    // MARK: - Footer

    private var stepFooter: some View {
        HStack {
            if currentStep > 0 {
                Button("Back") {
                    withAnimation { currentStep -= 1 }
                }
            }

            Spacer()

            if currentStep < 2 {
                Button("Skip") { completeOnboarding() }
                    .foregroundStyle(.secondary)
                Button("Next") {
                    withAnimation { currentStep += 1 }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Get Started") {
                    completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
    }

    // MARK: - Actions

    private func requestMicPermission() {
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            await MainActor.run {
                micPermissionGranted = granted
            }
        }
    }

    private func completeOnboarding() {
        hasCompletedOnboarding = true
        onComplete()
    }
}
