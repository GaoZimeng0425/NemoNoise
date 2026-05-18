import AppKit

/// Single chokepoint for the post-transcription side effects: clipboard, history,
/// AX/keystroke injection, and user feedback. Clipboard is written unconditionally
/// here in Task 1; Task 4 reorders so secure-field outcomes skip the clipboard.
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

        NSPasteboard.general.clearContents()
        let wrote = NSPasteboard.general.setString(trimmed, forType: .string)
        LogService.info("OutputDispatcher — clipboard wrote=\(wrote), len=\(trimmed.count)", category: "Output")

        historyStore.add(text: trimmed, engineLabel: engineLabel)
        LogService.info("OutputDispatcher — history saved, total=\(historyStore.records.count)", category: "Output")

        let outcome = await injector.inject(trimmed)
        LogService.info("OutputDispatcher — inject outcome=\(outcome)", category: "Output")

        switch outcome {
        case .injectedAX, .injectedKeystroke:
            ToastWindowController.show(
                "Inserted (\(trimmed.count) chars)",
                style: .success,
                duration: 2.5
            )
        case .skippedSecureField:
            ToastWindowController.show(
                "Secure field detected — not auto-typed",
                style: .info,
                duration: 4
            )
        case .failed:
            ToastWindowController.show(
                "Copied to clipboard — press ⌘V to paste",
                style: .info,
                duration: 4
            )
        }
    }
}
