import Foundation

/// The live-panel half of the meeting sink target, mirroring `SubtitleWriter`.
/// `MeetingController` conforms; the sink updates partials and confirmed lines
/// on the main actor while appending confirmed lines to the JSONL store.
@MainActor
protocol MeetingWriter: AnyObject {
    var meetingLines: [MeetingLine] { get set }
    var meetingPartialMe: String { get set }
    var meetingPartialThem: String { get set }
}

/// Meeting-mode sink. One instance per track: the mic ("Me") and system-audio
/// ("Them") pipelines each own one, appending through the shared
/// `MeetingStoreBox` (per-session store indirection). Confirmed lines go to
/// disk and are promoted on the panel; partials update the per-track live line.
final class MeetingSink: Sink {
    private let track: MeetingLine.Track
    private let target: any MeetingWriter
    private let storeBox: MeetingStoreBox

    init(track: MeetingLine.Track, target: any MeetingWriter, storeBox: MeetingStoreBox) {
        self.track = track
        self.target = target
        self.storeBox = storeBox
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if isFinal {
            // When it was spoken, not when recognition finished: the tracks'
            // delays differ by up to a VAD segment (30 s).
            let spokenAt = result.spokenAt ?? Date()
            storeBox.append(track: track, text: text, at: spokenAt)
            LogService.info("Meeting line (\(track.label)): \"\(text.prefix(24))\"", category: "Meeting")
            await MainActor.run { [target, track] in
                let line = MeetingLine(track: track, text: text, timestamp: spokenAt)
                // A slower track's line can land after later ones: keep the
                // panel in spoken order (scan from the end — usually 0 steps).
                let index = target.meetingLines.lastIndex { $0.timestamp <= spokenAt }.map { $0 + 1 } ?? 0
                target.meetingLines.insert(line, at: index)
                if track == .me { target.meetingPartialMe = "" } else { target.meetingPartialThem = "" }
            }
        } else {
            await MainActor.run { [target, track] in
                if track == .me { target.meetingPartialMe = text } else { target.meetingPartialThem = text }
            }
        }
    }
}
