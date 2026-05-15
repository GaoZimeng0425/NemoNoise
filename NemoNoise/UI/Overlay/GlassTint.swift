import SwiftUI

enum GlassTint {
    static func forHUD(_ state: RecordingState) -> Color? {
        switch state {
        case .ready:      return nil
        case .recording:  return .red.opacity(0.15)
        case .processing: return .blue.opacity(0.12)
        case .failed:     return .orange.opacity(0.18)
        }
    }

    static func forSubtitle(_ state: TranslationState) -> Color? {
        switch state {
        case .capturing:    return .green.opacity(0.12)
        case .idle, .error: return nil
        }
    }
}
