import Foundation
import os

/// One confirmed transcript line in a meeting session. `nonisolated`: built
/// and read from both the pipeline pumps and the main-actor panel.
nonisolated struct MeetingLine: Identifiable, Equatable, Sendable {
    nonisolated enum Track: String, Codable, Sendable {
        case me
        case them

        var label: String { self == .me ? "Me" : "Them" }
    }

    let id = UUID()
    let track: Track
    let text: String
    /// When the line was spoken (the pipeline's `spokenAt`; delivery time
    /// only when that is unknown).
    let timestamp: Date
}

/// Session indirection between the pipelines' sinks and the per-meeting
/// store. Pipelines and their `MeetingSink`s are built once and reused across
/// sessions, while `MeetingTranscriptStore` is created fresh by the controller
/// at every meeting start — the sinks append through this box, and appends
/// while no session is active are dropped.
/// `nonisolated`: called from the two pipeline pump tasks, off the main actor.
nonisolated final class MeetingStoreBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<MeetingTranscriptStore?>(initialState: nil)

    var current: MeetingTranscriptStore? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }

    func append(track: MeetingLine.Track, text: String, at date: Date = Date()) {
        lock.withLock { $0?.append(track: track, text: text, at: date) }
    }
}

/// Crash-safe JSONL transcript store for a meeting session. Every confirmed
/// line is appended to `<id>.jsonl` and flushed immediately, so an app crash
/// loses at most the line in flight. `exportMarkdown()` turns the session into
/// a human-readable `[mm:ss] Me:/Them:` document beside the JSONL.
///
/// Thread-safe: the two pipeline pumps (Me mic track, Them system track) append
/// from their own tasks. `nonisolated` for the same reason.
nonisolated final class MeetingTranscriptStore: @unchecked Sendable {
    struct Entry: Codable {
        let ts: Date
        let track: String
        let text: String
    }

    let jsonlURL: URL
    let startedAt = Date()

    private let handleBox = OSAllocatedUnfairLock<FileHandle?>(initialState: nil)
    private let entriesBox = OSAllocatedUnfairLock<[Entry]>(initialState: [])
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Creates the Meetings directory and the session's JSONL file.
    /// `directory` is injectable for tests; production uses the app's
    /// Application Support container.
    init?(directory: URL? = nil, id: UUID = UUID(), fileManager: FileManager = .default) {
        let dir = directory ?? Self.defaultDirectory(fileManager: fileManager)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            LogService.error("Meeting store: cannot create \(dir.path) — \(error.localizedDescription)",
                             category: "MeetingStore")
            return nil
        }
        jsonlURL = dir.appendingPathComponent("\(id.uuidString).jsonl")
        guard fileManager.createFile(atPath: jsonlURL.path, contents: nil) else {
            LogService.error("Meeting store: cannot create \(jsonlURL.path)", category: "MeetingStore")
            return nil
        }
        do {
            let handle = try FileHandle(forWritingTo: jsonlURL)
            handleBox.withLock { $0 = handle }
        } catch {
            LogService.error("Meeting store: cannot open \(jsonlURL.path) — \(error.localizedDescription)",
                             category: "MeetingStore")
            return nil
        }
    }

    deinit {
        finishFile()
    }

    /// Append one confirmed line. Writes and flushes synchronously so the file
    /// on disk is always a valid prefix of the session.
    func append(track: MeetingLine.Track, text: String, at date: Date = Date()) {
        let entry = Entry(ts: date, track: track.rawValue, text: text)
        entriesBox.withLock { $0.append(entry) }
        guard let data = try? encoder.encode(entry) else { return }
        handleBox.withLock { handle in
            try? handle?.write(contentsOf: data)
            try? handle?.write(contentsOf: Data([0x0A]))  // "\n"
            try? handle?.synchronizeFile()
        }
    }

    /// The confirmed lines so far, in order.
    var entries: [Entry] { entriesBox.withLock { $0 } }

    /// Writes `<id>.md` beside the JSONL and returns its URL, lines in spoken
    /// order (the JSONL keeps arrival order — a slow track appends late).
    @discardableResult
    func exportMarkdown() -> URL? {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let lines = entries.sorted { $0.ts < $1.ts }.map { entry in
            let label = MeetingLine.Track(rawValue: entry.track)?.label ?? entry.track
            return "- \(Self.offset(startedAt: startedAt, at: entry.ts)) [\(label)] \(entry.text)"
        }
        let header = """
        # Meeting — \(formatter.string(from: startedAt))

        \(lines.joined(separator: "\n"))

        """
        let url = jsonlURL.deletingPathExtension().appendingPathExtension("md")
        do {
            try header.data(using: .utf8)?.write(to: url, options: .atomic)
            LogService.info("Meeting exported to \(url.path)", category: "MeetingStore")
            return url
        } catch {
            LogService.error("Meeting export failed: \(error.localizedDescription)", category: "MeetingStore")
            return nil
        }
    }

    /// Closes the file handle. Further appends are dropped silently.
    func finishFile() {
        handleBox.withLock { handle in
            try? handle?.closeFile()
            handle = nil
        }
    }

    private static func offset(startedAt: Date, at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return support.appendingPathComponent("NemoNoise/Meetings", isDirectory: true)
    }
}
