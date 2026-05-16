import AppKit

/// Sink that writes final transcriptions to `NSPasteboard.general`.
/// Used standalone (e.g. as a manual export sink) or composed by
/// `TextInjectorSink` as the fallback when AX injection fails.
final class ClipboardSink: Sink {
    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard isFinal, !result.text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.clearContents()
        let wrote = pasteboard.setString(result.text, forType: .string)
        LogService.info("ClipboardSink — changeCount=\(changeCount), setString=\(wrote), len=\(result.text.count)", category: "TextInjection")
    }
}
