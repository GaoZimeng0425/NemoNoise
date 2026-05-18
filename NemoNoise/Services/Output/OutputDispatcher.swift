import AppKit

/// Single chokepoint for the post-transcription side effects: history, injection,
/// clipboard, and user feedback. Clipboard write happens after injection so
/// secure-field outcomes (Task 3) can skip pasteboard pollution.
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

        // History first — always recorded, regardless of target type.
        historyStore.add(text: trimmed, engineLabel: engineLabel)
        LogService.info("OutputDispatcher — history saved, total=\(historyStore.records.count)", category: "Output")

        // Inject.
        let outcome = await injector.inject(trimmed)
        LogService.info("OutputDispatcher — inject outcome=\(outcome)", category: "Output")

        // Clipboard — written for every outcome EXCEPT secure-field skip.
        // Writing the transcript to the pasteboard after a captured password
        // field would leak the password to any clipboard manager.
        if case .skippedSecureField = outcome {
            LogService.info("OutputDispatcher — skipping clipboard write (secure field)", category: "Output")
        } else {
            NSPasteboard.general.clearContents()
            let wrote = NSPasteboard.general.setString(trimmed, forType: .string)
            LogService.info("OutputDispatcher — clipboard wrote=\(wrote), len=\(trimmed.count)", category: "Output")
        }

        // Toast.
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
