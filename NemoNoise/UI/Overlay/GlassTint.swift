import SwiftUI

enum GlassTint {
    static func forSubtitle(_ state: TranslationState) -> Color? {
        switch state {
        case .capturing:    return .green.opacity(0.12)
        case .idle, .error: return nil
        }
    }
}
