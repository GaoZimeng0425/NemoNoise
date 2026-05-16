import Foundation

@MainActor
protocol OverlayWriter: AnyObject {
    var partialText: String { get set }
    /// Promote the given text into a finalised segment. Called when the engine
    /// has clearly moved on to a new utterance (new partial doesn't extend the
    /// previous one), so the previous partial would otherwise be visually
    /// overwritten and lost.
    func appendConfirmedSegment(_ text: String)
}

final class OverlayProgressSink: Sink {
    private let target: any OverlayWriter

    init(target: any OverlayWriter) {
        self.target = target
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard !isFinal, !result.text.isEmpty else { return }
        await MainActor.run {
            let newPartial = result.text
            let oldPartial = target.partialText
            // If the engine reset (e.g. silence-driven segment boundary in
            // Apple Speech), the new partial won't be a continuation of the
            // old one. Promote the old partial so it stays visible and is
            // included in the final dispatch.
            if !oldPartial.isEmpty, !newPartial.hasPrefix(oldPartial) {
                target.appendConfirmedSegment(oldPartial)
            }
            target.partialText = newPartial
        }
    }
}
