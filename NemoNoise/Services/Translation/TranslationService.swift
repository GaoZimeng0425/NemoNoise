import Foundation
import Translation

protocol TranslationService {
    func translate(_ text: String) async throws -> String
}

final class AppleTranslationService: TranslationService {
    private var session: TranslationSession?

    func setSession(_ session: TranslationSession) {
        self.session = session
    }

    func translate(_ text: String) async throws -> String {
        guard let session else {
            throw TranslationError.translationUnavailable
        }
        let response = try await session.translate(text)
        return response.targetText
    }
}
