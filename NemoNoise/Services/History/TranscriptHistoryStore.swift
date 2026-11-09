import Foundation
import Observation

struct TranscriptRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    let timestamp: Date
    var engineLabel: String?
    var audioFileName: String?
    /// Wall-clock duration of the recording session (diagnostics: latency
    /// vs engine choice). Optional so older records keep decoding.
    var durationSeconds: Double?
}

/// Persists final dictation transcripts so the user can review past results
/// even when AX injection silently fails or the user simply forgot what was
/// dictated. Stored in `UserDefaults` as JSON — data volume is tiny and avoids
/// pulling in a SwiftData container just for this.
///
/// Session audio lives next door in
/// `Application Support/NemoNoise/Recordings/<uuid>.wav` (`audioFileName`);
/// deletion and clear remove the files with the records.
@MainActor
@Observable
final class TranscriptHistoryStore {
    private static let defaultsKey = "transcriptHistoryV1"
    private static let maxRecords = 200
    private static let maxAudioRecords = 100

    private(set) var records: [TranscriptRecord] = []

    init() {
        load()
    }

    func add(text: String, engineLabel: String?, audioURL: URL? = nil, duration: Double? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // No record without text — drop the orphan audio with it.
            if let audioURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
            return
        }
        var fileName: String?
        if let audioURL {
            let name = audioURL.lastPathComponent
            pruneAudio(keeping: name)
            fileName = name
        }
        let record = TranscriptRecord(
            id: UUID(),
            text: trimmed,
            timestamp: Date(),
            engineLabel: engineLabel,
            audioFileName: fileName,
            durationSeconds: duration
        )
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records = Array(records.prefix(Self.maxRecords))
        }
        save()
    }

    func remove(id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        if let url = audioURL(for: record) {
            try? FileManager.default.removeItem(at: url)
        }
        records.removeAll { $0.id == id }
        save()
    }

    func clear() {
        for record in records {
            if let url = audioURL(for: record) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        records.removeAll()
        save()
    }

    func audioURL(for record: TranscriptRecord) -> URL? {
        record.audioFileName.map { SessionAudioRecorder.recordingsDirectory.appendingPathComponent($0) }
    }

    func updateText(id: UUID, text: String, engineLabel: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].text = text
        records[index].engineLabel = engineLabel
        save()
    }

    /// Re-run recognition on the stored session audio with the local
    /// SpeechAnalyzer engine and replace the record's text. This is the
    /// "was it the mic or the engine?" probe: same audio, fresh decode.
    func reRecognize(_ record: TranscriptRecord) async {
        guard let url = audioURL(for: record),
              let samples = SessionAudioRecorder.readMono16kWAV(url) else {
            ToastWindowController.show("Session audio unavailable", style: .warning)
            return
        }
        guard let engine = try? AppleSpeechASREngine(locale: LanguagePreference.current.localeIdentifier ?? "zh-CN") else {
            ToastWindowController.show("Could not create recognition engine", style: .error)
            return
        }
        engine.reset()
        for start in stride(from: 0, to: samples.count, by: 8000) {
            let end = min(start + 8000, samples.count)
            _ = try? await engine.feedChunk(Array(samples[start..<end]), sampleRate: 16000)
        }
        guard let result = try? await engine.finish(),
              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ToastWindowController.show("Re-recognition produced no text — the audio itself is empty/unintelligible", style: .warning, duration: 4)
            return
        }
        updateText(id: record.id, text: result.text, engineLabel: "Apple Speech (re-run)")
    }

    /// Keep only the newest `maxAudioRecords` audio files so recordings
    /// (~32 KB/s) don't grow unbounded.
    private func pruneAudio(keeping protected: String) {
        let withAudio = records.filter { $0.audioFileName != nil }
        guard withAudio.count >= Self.maxAudioRecords else { return }
        for record in withAudio.suffix(withAudio.count - Self.maxAudioRecords + 1) {
            guard let name = record.audioFileName, name != protected,
                  let index = records.firstIndex(where: { $0.id == record.id }) else { continue }
            if let url = audioURL(for: record) {
                try? FileManager.default.removeItem(at: url)
            }
            records[index].audioFileName = nil
        }
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
