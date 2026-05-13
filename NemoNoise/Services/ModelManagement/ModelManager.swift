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
        displayName: "Paraformer Streaming (zh+en)",
        detail: "Chinese + English streaming · real-time partial results",
        downloadSize: "~240 MB",
        subdir: "paraformer",
        files: [
            (name: "encoder.int8.onnx",  url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/resolve/main/encoder.int8.onnx")!),
            (name: "decoder.int8.onnx",  url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/resolve/main/decoder.int8.onnx")!),
            (name: "tokens.txt",         url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/resolve/main/tokens.txt")!),
        ]
    )

    static let punctuation = ModelDescriptor(
        id: "punctuation",
        displayName: "Punctuation (zh+en)",
        detail: "Chinese + English punctuation restoration",
        downloadSize: "~300 MB",
        subdir: "punctuation",
        files: [
            (name: "model.onnx", url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12/resolve/main/model.onnx")!),
        ]
    )
}

// MARK: - Manager

@Observable
final class ModelManager {
    var senseVoiceState: ModelDownloadState = .notDownloaded
    var paraformerState: ModelDownloadState = .notDownloaded
    var punctuationState: ModelDownloadState = .notDownloaded

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
        case "punctuation": return punctuationState
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
        for d in [ModelDescriptor.senseVoice, .paraformer, .punctuation] {
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
        case "punctuation": punctuationState = state
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
            LogService.info("\(descriptor.displayName) downloaded to \(dir.path)", category: "ModelManager")
        } catch is CancellationError {
            setState(.notDownloaded, for: descriptor)
            try? FileManager.default.removeItem(at: dir)
        } catch {
            setState(.error(error.localizedDescription), for: descriptor)
            LogService.error("Download failed: \(error)", category: "ModelManager")
        }
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let observer = ProgressObserver()
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: observer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
            observer.completion = continuation
            observer.onProgress = { progress in
                Task { @MainActor in onProgress(progress) }
            }
            let task = session.downloadTask(with: url)
            task.resume()
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        await MainActor.run { onProgress(1.0) }
    }
}

private final class ProgressObserver: NSObject, URLSessionDownloadDelegate {
    var completion: CheckedContinuation<URL, Error>?
    var onProgress: ((Double) -> Void)?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let moved = tempDir.appendingPathComponent(downloadTask.originalRequest?.url?.lastPathComponent ?? "download")
        try? FileManager.default.moveItem(at: location, to: moved)
        completion?.resume(returning: moved)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completion?.resume(throwing: error)
        }
    }
}
