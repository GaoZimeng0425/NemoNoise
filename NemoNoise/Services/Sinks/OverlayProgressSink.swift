import Foundation

@MainActor
protocol OverlayWriter: AnyObject {
    var partialText: String { get set }
}

final class OverlayProgressSink: Sink {
    private let target: any OverlayWriter

    init(target: any OverlayWriter) {
        self.target = target
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard !isFinal, !result.text.isEmpty else { return }
        await MainActor.run {
            target.partialText = result.text
        }
    }
}
