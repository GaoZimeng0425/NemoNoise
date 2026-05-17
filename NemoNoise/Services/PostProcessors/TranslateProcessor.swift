import Foundation

/// PostProcessor that translates final transcriptions via a TranslationService.
/// Partial results pass through unchanged (translating every keystroke is
/// expensive and produces unstable text).
///
/// On success, the translated text becomes `result.text` and the source is
/// preserved in `result.originalText` so downstream sinks can render both.
/// On failure, the source is returned as `result.text` and `originalText` is
/// left nil — sinks treat this as un-translated and avoid overwriting any
/// previously-good Chinese.
final class TranslateProcessor: PostProcessor {
    private let service: any TranslationService

    init(service: any TranslationService) {
        self.service = service
    }

    func process(_ result: TranscriptionResult, isFinal: Bool) async throws -> TranscriptionResult? {
        guard isFinal else { return nil }
        guard !result.text.isEmpty else { return nil }

        do {
            let translated = try await service.translate(result.text)
            return TranscriptionResult(
                text: translated,
                isFinal: true,
                emotion: result.emotion,
                originalText: result.text
            )
        } catch {
            LogService.warn("Translation failed, returning source: \(error.localizedDescription)", category: "TranslateProcessor")
            return TranscriptionResult(
                text: result.text,
                isFinal: true,
                emotion: result.emotion,
                originalText: nil
            )
        }
    }
}
