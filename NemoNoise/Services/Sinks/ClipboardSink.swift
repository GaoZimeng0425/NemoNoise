import AppKit

/// Sink that writes final transcriptions to the clipboard (`NSPasteboard.general`
/// unless another pasteboard is injected). Used standalone (e.g. as a manual
/// export sink) or composed by `TextInjectorSink` as the fallback when AX
/// injection fails.
final class ClipboardSink: Sink {
    private let pasteboard: NSPasteboard

    /// Tests pass a private pasteboard (`NSPasteboard.withUniqueName()`) so they
    /// never overwrite the user's clipboard.
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard isFinal, !result.text.isEmpty else { return }
        let changeCount = pasteboard.clearContents()
        let wrote = pasteboard.setString(result.text, forType: .string)
        LogService.info("ClipboardSink — changeCount=\(changeCount), setString=\(wrote), len=\(result.text.count)", category: "TextInjection")
    }
}
