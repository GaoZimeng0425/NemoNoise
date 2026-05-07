import Foundation
import Observation

enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case error(String)
}

// MARK: - Per-model descriptor

struct ModelDescriptor {
    let id: String
    let displayName: String
    let detail: String
    let downloadSize: String
    let subdir: String
    let files: [(name: String, url: URL)]
}

extension ModelDescriptor {
    static let senseVoice = ModelDescriptor(
        id: "sensevoice",
        displayName: "SenseVoiceSmall (int8)",
        detail: "Chinese · English · Japanese · Korean · Cantonese · emotion detection",
        downloadSize: "~60 MB",
        subdir: "sensevoice",
        files: [
            (name: "model.int8.onnx", url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx")!),
            (name: "tokens.txt",      url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt")!),
        ]
    )

    static let paraformer = ModelDescriptor(
        id: "paraformer",
        displayName: "Paraformer Streaming (zh)",
        detail: "Chinese streaming · real-time partial results · no emotion",
        downloadSize: "~50 MB",
        subdir: "paraformer",
        files: [
            (name: "model_quant.onnx",   url: URL(string: "https://huggingface.co/csukuangfj/streaming-paraformer-zh/resolve/main/model_quant.onnx")!),
            (name: "decoder_quant.onnx", url: URL(string: "https://huggingface.co/csukuangfj/streaming-paraformer-zh/resolve/main/decoder_quant.onnx")!),
            (name: "tokens.txt",         url: URL(string: "https://huggingface.co/csukuangfj/streaming-paraformer-zh/resolve/main/tokens.txt")!),
        ]
    )
}

// MARK: - Manager

@Observable
final class ModelManager {
    var senseVoiceState: ModelDownloadState = .notDownloaded
    var paraformerState: ModelDownloadState = .notDownloaded

    private let baseDir: URL
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDir = appSupport.appendingPathComponent("NemoNoise/models", isDirectory: true)
        refreshAll()
    }

    func modelDir(for descriptor: ModelDescriptor) -> URL {
        baseDir.appendingPathComponent(descriptor.subdir, isDirectory: true)
    }

    func modelPath(for descriptor: ModelDescriptor) -> URL? {
        guard state(for: descriptor) == .downloaded else { return nil }
        return modelDir(for: descriptor)
    }

    func state(for descriptor: ModelDescriptor) -> ModelDownloadState {
        switch descriptor.id {
        case "sensevoice": return senseVoiceState
        case "paraformer": return paraformerState
        default: return .notDownloaded
        }
    }

    func startDownload(_ descriptor: ModelDescriptor) {
        guard case .notDownloaded = state(for: descriptor) else { return }
        let id = descriptor.id
        let task = Task {
            await download(descriptor)
            downloadTasks.removeValue(forKey: id)
        }
        downloadTasks[descriptor.id] = task
    }

    func cancelDownload(_ descriptor: ModelDescriptor) {
        downloadTasks[descriptor.id]?.cancel()
        downloadTasks[descriptor.id] = nil
        setState(.notDownloaded, for: descriptor)
    }

    func deleteModel(_ descriptor: ModelDescriptor) {
        try? FileManager.default.removeItem(at: modelDir(for: descriptor))
        setState(.notDownloaded, for: descriptor)
    }

    // MARK: Private

    private func refreshAll() {
        for d in [ModelDescriptor.senseVoice, .paraformer] {
            let dir = modelDir(for: d)
            let allPresent = d.files.allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.name).path)
            }
            setState(allPresent ? .downloaded : .notDownloaded, for: d)
        }
    }

    private func setState(_ state: ModelDownloadState, for descriptor: ModelDescriptor) {
        switch descriptor.id {
        case "sensevoice": senseVoiceState = state
        case "paraformer": paraformerState = state
        default: break
        }
    }

    private func download(_ descriptor: ModelDescriptor) async {
        let dir = modelDir(for: descriptor)
        do {
            // Clean any partial files from a previous failed download
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let totalFiles = Double(descriptor.files.count)
            for (index, file) in descriptor.files.enumerated() {
                let dest = dir.appendingPathComponent(file.name)
                let baseProgress = Double(index) / totalFiles
                let fileShare = 1.0 / totalFiles

                try await downloadFile(from: file.url, to: dest) { [weak self] p in
                    self?.setState(.downloading(progress: baseProgress + p * fileShare), for: descriptor)
                }
            }

            setState(.downloaded, for: descriptor)
            print("[ModelManager] \(descriptor.displayName) downloaded to \(dir.path)")
        } catch is CancellationError {
            setState(.notDownloaded, for: descriptor)
            try? FileManager.default.removeItem(at: dir)
        } catch {
            setState(.error(error.localizedDescription), for: descriptor)
            print("[ModelManager] Download failed: \(error)")
        }
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        let totalBytes = (response as? HTTPURLResponse)?.expectedContentLength ?? -1

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: destination) else {
            throw URLError(.cannotOpenFile)
        }
        defer { try? fileHandle.close() }

        var buffer = Data(capacity: 65_536)
        var received: Int64 = 0

        for try await byte in asyncBytes {
            try Task.checkCancellation()
            buffer.append(byte)
            received += 1
            if buffer.count >= 65_536 {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if totalBytes > 0 {
                    await MainActor.run { onProgress(Double(received) / Double(totalBytes)) }
                }
            }
        }
        if !buffer.isEmpty { try fileHandle.write(contentsOf: buffer) }
        await MainActor.run { onProgress(1.0) }
    }
}
