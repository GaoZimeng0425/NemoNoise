import Foundation

@MainActor
protocol SubtitleWriter: AnyObject {
    var englishText: String { get set }
    var partialText: String { get set }
    var chineseText: String { get set }
}

final class SubtitleOverlaySink: Sink {
    private let target: any SubtitleWriter

    init(target: any SubtitleWriter) {
        self.target = target
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard !result.text.isEmpty else { return }
        await MainActor.run {
            if let original = result.originalText {
                target.englishText = original
                target.chineseText = result.text
                target.partialText = ""
            } else if isFinal {
                target.englishText = result.text
                target.partialText = ""
            } else {
                target.partialText = result.text
            }
        }
    }
}
