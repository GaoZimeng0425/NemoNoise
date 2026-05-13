import SwiftUI
import Translation
import Combine

struct SubtitleOverlayView: View {
    @Environment(TranslationController.self) private var controller
    @State private var translationSession: TranslationSession?
    @State private var dotOffsets: [CGFloat] = [0, 0, 0]
    private let dotTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(controller.translationState == .capturing ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(controller.englishText.isEmpty ? "Listening…" : controller.englishText)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.gray)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if controller.isTranslating {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(Color.white.opacity(0.6))
                                .frame(width: 5, height: 5)
                                .offset(y: dotOffsets[i])
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear { startDotAnimation() }
                } else {
                    Text(controller.chineseText.isEmpty ? "—" : controller.chineseText)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()
        }
        .padding(12)
        .frame(minWidth: 400, maxWidth: 900)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThickMaterial)
        }
        .translationTask(.init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))) { session in
            translationSession = session
            controller.translationService.setSession(session)
        }
        .onChange(of: controller.englishText) { _, newText in
            guard !newText.isEmpty else { return }
            Task {
                controller.isTranslating = true
                do {
                    let result = try await controller.translationService.translate(newText)
                    controller.chineseText = result
                } catch {
                    LogService.warn("Translation failed: \(error.localizedDescription)", category: "Translation")
                    controller.chineseText = "—"
                }
                controller.isTranslating = false
            }
        }
        .onReceive(dotTimer) { _ in
            guard controller.isTranslating else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                for i in 0..<3 {
                    dotOffsets[i] = dotOffsets[i] == 0 ? -4 : 0
                }
            }
        }
    }

    private func startDotAnimation() {
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) {
                withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) {
                    dotOffsets[i] = -4
                }
            }
        }
    }
}
