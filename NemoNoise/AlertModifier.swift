import SwiftUI

/// Reads ``RecordingError`` from the SwiftUI environment and presents a
/// standard error alert whenever `error` is non-nil. Dismissing the alert
/// clears the error string.
struct AlertModifier: ViewModifier {
    @Environment(RecordingError.self) private var recordingError

    func body(content: Content) -> some View {
        content
            .alert(
                "Recording Error",
                isPresented: Binding(
                    get: { recordingError.error != nil },
                    set: { if !$0 { recordingError.error = nil } }
                )
            ) {
                Button("OK") { recordingError.error = nil }
            } message: {
                Text(recordingError.error ?? "")
            }
    }
}

extension View {
    /// Presents an alert driven by the ``RecordingError`` value in the
    /// SwiftUI environment.
    func recordingErrorAlert() -> some View {
        modifier(AlertModifier())
    }
}
