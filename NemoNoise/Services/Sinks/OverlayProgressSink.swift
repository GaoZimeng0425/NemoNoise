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
        guard !result.text.isEmpty else { return }
        await MainActor.run {
            if isFinal {
                // Segment boundary. The engine's text is authoritative —
                // for Paraformer it includes tokens the chunk-based decoder
                // held in lookahead; for Apple Speech (after the engine-side
                // delta normalization in AppleSpeechASREngine) it's the new
                // portion since the last commit.
                target.appendConfirmedSegment(result.text)
                target.partialText = ""
                return
            }
            // Partial: just display state. No segment-boundary heuristics
            // here — that's the engine adapter's job (Apple Speech emits
            // isFinal at boundaries via addsPunctuation=true; Paraformer
            // emits isFinal at endpoint). Inferring boundaries from partial
            // prefix mismatches double-fires with isFinal and causes the
            // "duplicate sentence" bug.
            target.partialText = result.text
        }
    }
}
