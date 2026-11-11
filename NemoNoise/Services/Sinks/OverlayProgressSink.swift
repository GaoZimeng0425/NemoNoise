import Foundation

@MainActor
protocol OverlayWriter: AnyObject {
    var partialText: String { get set }
    /// Commit `text` as a finalised segment. Called for every `isFinal` result:
    /// the engine's isFinal is the segment boundary (see `OverlayProgressSink`).
    func appendConfirmedSegment(_ text: String)
    /// Segment commit with the seam pause into the previous segment (nil when
    /// the engine doesn't measure it). A requirement so writers that keep the
    /// pause for join-time punctuation are dynamically dispatched; the default
    /// below just drops it.
    func appendConfirmedSegment(_ text: String, pauseBefore: TimeInterval?)
}

extension OverlayWriter {
    func appendConfirmedSegment(_ text: String, pauseBefore: TimeInterval?) {
        appendConfirmedSegment(text)
    }
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
                target.appendConfirmedSegment(result.text, pauseBefore: result.pauseBefore)
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
