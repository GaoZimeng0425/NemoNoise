import Foundation

/// PostProcessor that translates final transcriptions via a TranslationService.
/// Partial results pass through unchanged (translating every keystroke is
/// expensive and produces unstable text).
///
/// Translation failures do NOT propagate as throws — the original text is
/// returned so that the recording session is never lost to a translation hiccup.
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
            return TranscriptionResult(text: translated, isFinal: true, emotion: result.emotion)
        } catch {
            LogService.warn("Translation failed, returning source: \(error.localizedDescription)", category: "TranslateProcessor")
            return TranscriptionResult(text: result.text, isFinal: true, emotion: result.emotion)
        }
    }
}
