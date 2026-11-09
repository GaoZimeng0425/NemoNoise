import Foundation
import os

/// Records each dictation session's raw (pre-VAD) 16 kHz mono audio to a WAV
/// file so the History tab can play it back and re-run recognition — the
/// ground truth for "was it the mic or the engine?".
///
/// Chunks are handed to a serial utility queue for the actual file writes;
/// the audio tap thread only copies under a lock.
nonisolated final class SessionAudioRecorder {
    nonisolated(unsafe) static let shared = SessionAudioRecorder()

    static var recordingsDirectory: URL {
        let dir = NSHomeDirectory() + "/Library/Application Support/NemoNoise/Recordings"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: dir)
    }

    private struct Slot {
        let handle: FileHandle
        let url: URL
        var frames: Int
    }

    private let lock = OSAllocatedUnfairLock<Slot?>(initialState: nil)
    private let queue = DispatchQueue(label: "nemo.session-audio", qos: .utility)
    private let sampleRate: Double = 16000

    var isActive: Bool { lock.withLock { $0 != nil } }

    /// Start capturing into a fresh WAV; the previous session (if still open)
    /// is discarded.
    func beginSession() {
        let url = Self.recordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        queue.sync { _ = try? handle.write(contentsOf: Self.wavHeader(frames: 0, sampleRate: sampleRate)) }
        lock.withLock { $0 = Slot(handle: handle, url: url, frames: 0) }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let slot = lock.withLock { $0 }
        guard let slot else { return }
        let data = samples.withUnsafeBufferPointer { buf -> Data in
            guard let base = buf.baseAddress else { return Data() }
            var out = Data(capacity: samples.count * 2)
            for i in 0..<samples.count {
                let clamped = max(-1, min(1, base[i]))
                var v = Int16(clamped * Float(Int16.max)).littleEndian
                withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
            }
            return out
        }
        let frames = samples.count
        queue.async {
            try? slot.handle.write(contentsOf: data)
            self.lock.withLock { $0?.frames += frames }
        }
    }

    /// Close the WAV. Returns its URL (nil when nothing was captured or no
    /// session was open). The file is kept on disk.
    @discardableResult
    func endSession() -> URL? {
        let slot = lock.withLock { current -> Slot? in
            let old = current
            current = nil
            return old
        }
        guard let slot else { return nil }
        // Sizes come from the file itself once every queued write has landed:
        // the slot's frame counter is read before the queue drains, so it
        // under-counted and players stopped early.
        let dataBytes: UInt32 = queue.sync {
            let fileSize = (try? slot.handle.seekToEnd()) ?? 44
            let bytes = UInt32(max(0, Int(fileSize) - 44))
            let riff = UInt32(36 + bytes).littleEndian
            let data = bytes.littleEndian
            try? slot.handle.seek(toOffset: 4)
            try? slot.handle.write(contentsOf: withUnsafeBytes(of: riff) { Data($0) })
            try? slot.handle.seek(toOffset: 40)
            try? slot.handle.write(contentsOf: withUnsafeBytes(of: data) { Data($0) })
            try? slot.handle.close()
            return bytes
        }
        guard dataBytes > 0 else {
            try? FileManager.default.removeItem(at: slot.url)
            return nil
        }
        return slot.url
    }

    /// Discard the current session's file (aborted/error sessions keep no
    /// history record, so their audio is removed).
    func discardSession() {
        if let url = endSession() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - WAV

    private static func wavHeader(frames: Int, sampleRate: Double) -> Data {
        var data = Data(capacity: 44)
        let dataBytes = UInt32(frames * 2)

        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        func appendASCII(_ s: String) {
            data.append(contentsOf: Array(s.utf8))
        }

        appendASCII("RIFF")
        append(UInt32(36 + dataBytes).littleEndian)
        appendASCII("WAVE")
        appendASCII("fmt ")
        append(UInt32(16).littleEndian)          // PCM chunk size
        append(UInt16(1).littleEndian)           // PCM format
        append(UInt16(1).littleEndian)           // mono
        append(UInt32(sampleRate).littleEndian)
        append(UInt32(sampleRate * 2).littleEndian)  // byte rate
        append(UInt16(2).littleEndian)           // block align
        append(UInt16(16).littleEndian)          // bits per sample
        appendASCII("data")
        append(dataBytes.littleEndian)
        return data
    }

    /// Read a mono 16-bit WAV produced by this recorder back into Float
    /// samples at the original rate. Returns nil for anything malformed.
    static func readMono16kWAV(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        let header = [UInt8](data.prefix(44))
        guard Array(header.prefix(4)) == Array("RIFF".utf8),
              header[20] == 1, header[21] == 0,      // PCM
              header[22] == 1, header[23] == 0,      // mono
              header[34] == 16, header[35] == 0 else { return nil }
        let body = data.suffix(from: 44)
        var samples = [Float]()
        samples.reserveCapacity(body.count / 2)
        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for offset in stride(from: 0, to: raw.count - 1, by: 2) {
                let v = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                samples.append(Float(Int16(littleEndian: v)) / Float(Int16.max))
            }
        }
        return samples
    }
}
