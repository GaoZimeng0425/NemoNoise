import Foundation

/// Sink that delivers final transcriptions via Accessibility-based text
/// injection. On failure, falls back to `clipboardFallback` and notifies the
/// controller via `onInjectionFailed`.
final class TextInjectorSink: Sink {
    private let injector: any TextInjecting
    private let clipboardFallback: any Sink
    private let onInjectionFailed: @Sendable () -> Void

    init(
        injector: any TextInjecting,
        clipboardFallback: any Sink,
        onInjectionFailed: @escaping @Sendable () -> Void
    ) {
        self.injector = injector
        self.clipboardFallback = clipboardFallback
        self.onInjectionFailed = onInjectionFailed
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        guard isFinal, !result.text.isEmpty else { return }
        let success = await injector.injectAX(result.text)
        if !success {
            await clipboardFallback.deliver(result, isFinal: true)
            onInjectionFailed()
        }
    }
}
