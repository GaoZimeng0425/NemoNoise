import SwiftUI
import AppKit
import AVFoundation

struct TranscriptHistoryView: View {
    @Bindable var store: TranscriptHistoryStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.records.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var header: some View {
        HStack {
            Text("\(store.records.count) \(store.records.count == 1 ? "record" : "records")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                store.clear()
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(store.records.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No transcripts yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Each completed dictation will be saved here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(store.records) { record in
                TranscriptRow(record: record) {
                    copy(record.text)
                } onDelete: {
                    store.remove(id: record.id)
                } onPlay: {
                    playAudio(for: record)
                } onReRecognize: {
                    Task { await store.reRecognize(record) }
                }
            }
        }
        .listStyle(.inset)
        .onDisappear {
            player?.stop()
            player = nil
        }
    }

    @State private var player: AVAudioPlayer?

    private func playAudio(for record: TranscriptRecord) {
        guard let url = store.audioURL(for: record) else { return }
        if player?.isPlaying == true {
            player?.stop()
            player = nil
            return
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastWindowController.show("Copied to clipboard", style: .success)
    }
}

private struct TranscriptRow: View {
    let record: TranscriptRecord
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onPlay: () -> Void
    let onReRecognize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.text)
                .font(.system(size: 13, design: .rounded))
                .textSelection(.enabled)
                .lineLimit(4)

            HStack(spacing: 6) {
                Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let label = record.engineLabel {
                    Text("· \(label)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let duration = record.durationSeconds {
                    Text(String(format: "· %.1fs", duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if record.audioFileName != nil {
                    Button(action: onPlay) {
                        Image(systemName: "play.circle")
                    }
                    Button("Re-recognize", action: onReRecognize)
                }
                Button("Copy", action: onCopy)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
