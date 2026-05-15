import SwiftUI
import Translation

struct SubtitleOverlayView: View {
    @Environment(TranslationController.self) private var controller
    @State private var translationSession: TranslationSession?
    @State private var translationTask: Task<Void, Never>?
    @Namespace private var glassNS

    private var subtitleStatusGlass: Glass {
        GlassTint.forSubtitle(controller.translationState).map { Glass.regular.tint($0) } ?? Glass.regular
    }

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                statusGroup
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(subtitleStatusGlass, in: .capsule)
                    .glassEffectID("subtitle-status", in: glassNS)

                if hasTranscript {
                    textGroup
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("subtitle-text", in: glassNS)
                        .transition(.opacity)
                }
            }
        }
        .frame(minWidth: 220, maxWidth: 900)
        .animation(.smooth(duration: 0.4), value: controller.translationState)
        .translationTask(.init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))) { session in
            translationSession = session
            controller.translationService.setSession(session)
        }
        .onChange(of: controller.englishText) { _, newText in
            translationTask?.cancel()
            guard !newText.isEmpty else { return }
            translationTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }

                controller.isTranslating = true
                do {
                    let result = try await controller.translationService.translate(newText)
                    guard !Task.isCancelled else { return }
                    controller.chineseText = result
                } catch is CancellationError {
                    return
                } catch {
                    LogService.warn("Translation failed: \(error.localizedDescription)", category: "Translation")
                    controller.chineseText = "—"
                }
                controller.isTranslating = false
            }
        }
        .onDisappear { translationTask?.cancel() }
    }

    private var hasTranscript: Bool {
        !controller.englishText.isEmpty || !controller.partialText.isEmpty
    }

    private var statusGroup: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.translationState == .capturing ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(controller.translationState == .capturing ? Color.green : Color.secondary.opacity(0.3))
                        .frame(width: 3, height: waveformBarHeight(index: index))
                }
            }
            .frame(height: 20)
            .animation(.easeOut(duration: 0.1), value: controller.audioLevel)
        }
    }

    private var textGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayEnglishText)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(controller.chineseText.isEmpty ? displayEnglishText : controller.chineseText)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayEnglishText: String {
        if !controller.partialText.isEmpty {
            return controller.partialText
        }
        return controller.englishText
    }

    private func waveformBarHeight(index: Int) -> CGFloat {
        let level = CGFloat(controller.audioLevel)
        let base: CGFloat = 3
        let maxExtra: CGFloat = 17
        let scale = max(0, 1.0 - CGFloat(index) * 0.12)
        let amplified = min(1.0, level * 8)
        return base + amplified * scale * maxExtra
    }
}
