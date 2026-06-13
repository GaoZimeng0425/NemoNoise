import SwiftUI
import Translation

struct SubtitleOverlayView: View {
    @Environment(TranslationController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false
    @Namespace private var glassNS
    private let subtitleWidth: CGFloat = 560

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if showTextCapsule {
                    textGroup
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        .glassEffectID("subtitle-text", in: glassNS)
                        .transition(.opacity)
                }

                headerBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("subtitle-status", in: glassNS)
            }
        }
        .frame(width: subtitleWidth + 40)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(20)
        .animation(.smooth(duration: 0.4), value: controller.translationState)
        .animation(.smooth(duration: 0.24), value: subtitleText)
        .translationTask(.init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))) { session in
            controller.translationService.setSession(session)
        }
    }

    private var showTextCapsule: Bool {
        controller.translationState == .capturing
            || !controller.englishText.isEmpty
            || !controller.partialText.isEmpty
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            statusIndicator

            Spacer()

            SpectrumBarsView(
                spectrum: controller.spectrum,
                isActive: controller.translationState == .capturing,
                barCount: 16
            )

            Label("Translate", systemImage: "captions.bubble")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize()
        }
        .frame(width: subtitleWidth, alignment: .leading)
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .opacity(controller.translationState == .capturing && isPulsing ? 0.42 : 1.0)
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
        switch controller.translationState {
        case .idle: return .secondary
        case .capturing: return .red
        case .error: return .orange
        }
    }

    private var statusText: String {
        switch controller.translationState {
        case .idle: return "Ready"
        case .capturing: return controller.isTranslating ? "Translating" : "Listening"
        case .error: return "Error"
        }
    }

    private var statusPulseAnimation: Animation? {
        guard controller.translationState == .capturing, !reduceMotion else { return .default }
        return .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
    }

    private var textGroup: some View {
        Text(subtitleText)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(controller.chineseText.isEmpty ? .secondary : .primary)
            .multilineTextAlignment(.center)
            .lineLimit(1...20)
            .truncationMode(.tail)
            .frame(width: subtitleWidth, alignment: .center)
            .frame(minHeight: 24, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
    }

    private var subtitleText: String {
        if !controller.chineseText.isEmpty {
            return controller.chineseText
        }
        if controller.isTranslating {
            return "翻译中…"
        }
        return displayEnglishText
    }

    private var displayEnglishText: String {
        if !controller.partialText.isEmpty {
            return controller.partialText
        }
        if !controller.englishText.isEmpty {
            return controller.englishText
        }
        return "Listening..."
    }
}
