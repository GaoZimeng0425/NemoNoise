import Foundation

@MainActor
protocol SubtitleWriter: AnyObject {
    var englishText: String { get set }
    var partialText: String { get set }
    var chineseText: String { get set }
    var isTranslating: Bool { get set }
    var displayedSeq: Int { get set }
    func applyTranslation(seq: Int, chinese: String)
}

final class SubtitleOverlaySink: Sink {
    private let target: any SubtitleWriter

    init(target: any SubtitleWriter) {
        self.target = target
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard !result.text.isEmpty else { return }
        await MainActor.run {
            if isFinal, let seq = result.sequence {
                target.englishText = result.text
                target.partialText = ""
                target.chineseText = ""
                target.displayedSeq = seq
            } else if isFinal {
                target.englishText = result.text
                target.partialText = ""
                // Bilingual legacy path: still honor originalText if set.
                if let original = result.originalText {
                    target.englishText = original
                    target.chineseText = result.text
                }
            } else {
                target.partialText = result.text
            }
        }
    }
}
