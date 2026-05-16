import Foundation
import Observation

struct TranscriptRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    let engineLabel: String?
}

/// Persists final dictation transcripts so the user can review past results
/// even when AX injection silently fails or the user simply forgot what was
/// dictated. Stored in `UserDefaults` as JSON — data volume is tiny and avoids
/// pulling in a SwiftData container just for this.
@MainActor
@Observable
final class TranscriptHistoryStore {
    private static let defaultsKey = "transcriptHistoryV1"
    private static let maxRecords = 200

    private(set) var records: [TranscriptRecord] = []

    init() {
        load()
    }

    func add(text: String, engineLabel: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let record = TranscriptRecord(
            id: UUID(),
            text: trimmed,
            timestamp: Date(),
            engineLabel: engineLabel
        )
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records = Array(records.prefix(Self.maxRecords))
        }
        save()
    }

    func remove(id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([TranscriptRecord].self, from: data) else {
            return
        }
        records = decoded
    }
}
