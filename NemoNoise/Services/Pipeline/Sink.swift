import Foundation

/// Delivers transcription results to a user-visible destination (text field,
/// subtitle overlay, clipboard, etc.). Sinks should be tolerant: never throw,
/// never block long. The pipeline awaits `deliver`, so heavy work should be
/// pushed off-actor via Tasks if needed.
protocol Sink: Sendable {
    func deliver(_ result: TranscriptionResult, isFinal: Bool) async
}
