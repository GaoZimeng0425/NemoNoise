import AppKit

/// Single chokepoint for the post-transcription side effects: clipboard, history,
/// AX injection, and user feedback. Each step runs unconditionally so a failure
/// in one (e.g. AX injection silently no-ops) never causes the others to be skipped.
///
/// This intentionally bypasses the Sink fan-out for finals — the Sink protocol's
/// "guard isFinal, !empty" pattern hides empty-text edge cases (some streaming
/// engines flush all text via partials and return empty on finish), which made
/// the previous design collapse silently. Here, the controller decides what
/// `text` to dispatch (with partial fallback) and we just guarantee delivery.
@MainActor
enum OutputDispatcher {
    static func dispatch(
        text: String,
        injector: any TextInjecting,
        historyStore: TranscriptHistoryStore,
        engineLabel: String?
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            LogService.info("OutputDispatcher — empty text, nothing to do", category: "Output")
            return
        }

        // ① Clipboard — always. This is the user's last-resort retrieval path.
        NSPasteboard.general.clearContents()
        let wrote = NSPasteboard.general.setString(trimmed, forType: .string)
        LogService.info("OutputDispatcher — clipboard wrote=\(wrote), len=\(trimmed.count)", category: "Output")

        // ② History — always. The user must be able to find this later.
        historyStore.add(text: trimmed, engineLabel: engineLabel)
        LogService.info("OutputDispatcher — history saved, total=\(historyStore.records.count)", category: "Output")

        // ③ AX injection — best effort. Only AX selectedText: no Cmd-V simulation
        // because that path silently "succeeds" even when nothing was pasted.
        let injected = await injector.injectAX(trimmed)
        LogService.info("OutputDispatcher — AX injection success=\(injected)", category: "Output")

        // ④ Feedback — always. The user must know what happened.
        if injected {
            ToastWindowController.show(
                "Inserted (\(trimmed.count) chars)",
                style: .success,
                duration: 2.5
            )
        } else {
            ToastWindowController.show(
                "Copied to clipboard — press ⌘V to paste",
                style: .info,
                duration: 4
            )
        }
    }
}
