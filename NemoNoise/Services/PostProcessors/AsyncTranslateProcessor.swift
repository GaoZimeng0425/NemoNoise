import Foundation

/// Fire-and-forget translation. Returns the source English synchronously
/// so the sink can render it immediately; spawns a detached Task that
/// translates and back-fills Chinese via `writer.applyTranslation`.
/// See `docs/superpowers/specs/2026-05-17-streaming-translation-realtime-design.md`.
@MainActor
final class AsyncTranslateProcessor: PostProcessor {
    private let service: any TranslationService
    private weak var writer: (any SubtitleWriter)?
    private var inflightCount: Int = 0

    init(service: any TranslationService, writer: any SubtitleWriter) {
        self.service = service
        self.writer = writer
    }

    // The PostProcessor protocol's `process` is non-isolated. Because the
    // class is `@MainActor`, awaiting `processOnMain` from this nonisolated
    // entry point hops to MainActor automatically — no MainActor.run needed.
    nonisolated func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        return await processOnMain(result, isFinal: isFinal)
    }

    private func processOnMain(_ result: TranscriptionResult, isFinal: Bool) async -> TranscriptionResult? {
        guard isFinal, !result.text.isEmpty, let seq = result.sequence else {
            return nil   // partial or seq-less (dictation) → passthrough
        }
        let source = result.text
        beginTranslating()
        Task.detached { [service, weak writer, weak self] in
            var translated: String? = nil
            do {
                translated = try await service.translate(source)
            } catch {
                LogService.warn(
                    "Translation failed: \(error.localizedDescription)",
                    category: "AsyncTranslate"
                )
            }
            await MainActor.run {
                if let t = translated, let w = writer {
                    w.applyTranslation(seq: seq, chinese: t)
                }
                self?.endTranslating()
            }
        }
        return TranscriptionResult(
            text: source, isFinal: true,
            emotion: result.emotion, originalText: nil, sequence: seq
        )
    }

    private func beginTranslating() {
        inflightCount += 1
        writer?.isTranslating = inflightCount > 0
    }

    private func endTranslating() {
        inflightCount = max(0, inflightCount - 1)
        writer?.isTranslating = inflightCount > 0
    }

    /// Reset inflight tracking for a new session. Call from the controller when
    /// starting a fresh translation session — old in-flight tasks may still
    /// complete later but their endTranslating() will be a no-op floor below 0.
    func resetInflight() {
        inflightCount = 0
        writer?.isTranslating = false
    }
}
