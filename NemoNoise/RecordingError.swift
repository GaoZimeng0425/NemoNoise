import SwiftUI

/// A lightweight model that surfaces transient alerts to the UI layer.
/// `recordingError` is set by controllers/services whenever a recoverable
/// error occurs (e.g. ASR failure, audio-engine hiccup). The overlay or
/// popover can observe it via `@Environment(RecordingError.self)` and
/// present an `.alert` binding.
@Observable
final class RecordingError {
    var error: String?
}
