import AppKit

/// Sink that writes final transcriptions to `NSPasteboard.general`.
/// Used standalone (e.g. as a manual export sink) or composed by
/// `TextInjectorSink` as the fallback when AX injection fails.
final class ClipboardSink: Sink {
    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard isFinal, !result.text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.text, forType: .string)
    }
}
