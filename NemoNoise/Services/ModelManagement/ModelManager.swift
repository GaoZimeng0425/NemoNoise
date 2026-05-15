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
    /// Files to fetch individually. Empty when this descriptor uses `archiveURL`.
    let files: [(name: String, url: URL)]
    /// If set, download this archive (tar.bz2 / tar.gz) and extract into `subdir`.
    let archiveURL: URL?
    /// If true, pass `--strip-components=1` to tar (archive has a single top-level dir to drop).
    let archiveStripsTopLevel: Bool
    /// tar `--exclude` patterns to skip (e.g. "test_wavs", "README.md").
    let archiveExcludes: [String]
    /// Relative paths (file OR directory) that must exist under the model's
    /// subdir for it to be considered downloaded. Defaults to `files.map(\.name)`.
    let requiredItems: [String]

    init(
        id: String,
        displayName: String,
        detail: String,
        downloadSize: String,
        subdir: String,
        files: [(name: String, url: URL)] = [],
        archiveURL: URL? = nil,
        archiveStripsTopLevel: Bool = false,
        archiveExcludes: [String] = [],
        requiredItems: [String]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.downloadSize = downloadSize
        self.subdir = subdir
        self.files = files
        self.archiveURL = archiveURL
        self.archiveStripsTopLevel = archiveStripsTopLevel
        self.archiveExcludes = archiveExcludes
        self.requiredItems = requiredItems ?? files.map(\.name)
    }
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
        detail: "CT-Transformer · adds commas and periods to final transcripts",
        downloadSize: "~70 MB",
        subdir: "punctuation",
        files: [
            (name: "model.onnx", url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12/resolve/main/model.onnx")!),
        ]
    )

    static let qwen3 = ModelDescriptor(
        id: "qwen3",
        displayName: "Qwen3-ASR 0.6B (int8)",
        detail: "Offline · multilingual · LLM-style decoding",
        downloadSize: "~940 MB (extracts to ~1.5 GB)",
        subdir: "qwen3",
        archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2")!,
        archiveStripsTopLevel: true,
        archiveExcludes: ["test_wavs", "README.md"],
        requiredItems: [
            "conv_frontend.onnx",
            "encoder.int8.onnx",
            "decoder.int8.onnx",
            "tokenizer",
        ]
    )
}

// MARK: - Manager

@Observable
final class ModelManager {
    /// State per model, keyed by `ModelDescriptor.id`. Adding a new model only
    /// requires extending the descriptor list — no extra stored property.
    var states: [String: ModelDownloadState] = [:]

    private let baseDir: URL
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    /// All models tracked by this manager.
    static let allDescriptors: [ModelDescriptor] = [.senseVoice, .paraformer, .punctuation, .qwen3]

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
        states[descriptor.id] ?? .notDownloaded
    }

    func startDownload(_ descriptor: ModelDescriptor) {
        guard case .notDownloaded = state(for: descriptor) else { return }
        // Flip state synchronously so a rapid second tap on the same button
        // sees `.downloading` and is rejected by the guard. Without this, two
        // detached Tasks would race on the same model directory.
        setState(.downloading(progress: 0), for: descriptor)
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

    /// Re-scan the models directory for each descriptor. Call after the user has
    /// manually placed files (e.g. via `Show in Finder` for manual-install models).
    func refreshAll() {
        for d in Self.allDescriptors {
            let dir = modelDir(for: d)
            let allPresent = !d.requiredItems.isEmpty && d.requiredItems.allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            setState(allPresent ? .downloaded : .notDownloaded, for: d)
        }
    }

    /// Ensure the model's subdir exists so the user can drop files into it via Finder.
    func ensureModelDirExists(for descriptor: ModelDescriptor) {
        let dir = modelDir(for: descriptor)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: Private

    private func setState(_ state: ModelDownloadState, for descriptor: ModelDescriptor) {
        states[descriptor.id] = state
    }

    private func download(_ descriptor: ModelDescriptor) async {
        let dir = modelDir(for: descriptor)
        do {
            // Clean any partial files from a previous failed download
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            if let archiveURL = descriptor.archiveURL {
                try await downloadAndExtract(descriptor: descriptor, archiveURL: archiveURL, dir: dir)
            } else {
                try await downloadIndividualFiles(descriptor: descriptor, dir: dir)
            }

            setState(.downloaded, for: descriptor)
            LogService.info("\(descriptor.displayName) downloaded to \(dir.path)", category: "ModelManager")
        } catch is CancellationError {
            setState(.notDownloaded, for: descriptor)
            try? FileManager.default.removeItem(at: dir)
        } catch {
            setState(.error(error.localizedDescription), for: descriptor)
            try? FileManager.default.removeItem(at: dir)
            LogService.error("Download failed: \(error)", category: "ModelManager")
        }
    }

    private func downloadIndividualFiles(descriptor: ModelDescriptor, dir: URL) async throws {
        let totalFiles = Double(descriptor.files.count)
        for (index, file) in descriptor.files.enumerated() {
            let dest = dir.appendingPathComponent(file.name)
            let baseProgress = Double(index) / totalFiles
            let fileShare = 1.0 / totalFiles

            try await downloadFile(from: file.url, to: dest) { [weak self] p in
                self?.setState(.downloading(progress: baseProgress + p * fileShare), for: descriptor)
            }
        }
    }

    private func downloadAndExtract(descriptor: ModelDescriptor, archiveURL: URL, dir: URL) async throws {
        let tempArchive = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(descriptor.id)-\(UUID().uuidString).tar.bz2")
        defer { try? FileManager.default.removeItem(at: tempArchive) }

        // Reserve 0..0.92 for download, 0.92..1.0 for extraction.
        try await downloadFile(from: archiveURL, to: tempArchive) { [weak self] p in
            self?.setState(.downloading(progress: p * 0.92), for: descriptor)
        }
        await MainActor.run { self.setState(.downloading(progress: 0.93), for: descriptor) }

        try await Self.extractTarArchive(
            at: tempArchive,
            to: dir,
            stripTopLevel: descriptor.archiveStripsTopLevel,
            excludes: descriptor.archiveExcludes
        )
        await MainActor.run { self.setState(.downloading(progress: 1.0), for: descriptor) }
    }

    private static func extractTarArchive(
        at archive: URL,
        to destDir: URL,
        stripTopLevel: Bool,
        excludes: [String]
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            var args = ["-xjf", archive.path, "-C", destDir.path]
            if stripTopLevel { args.append("--strip-components=1") }
            for pattern in excludes { args.append("--exclude=\(pattern)") }
            process.arguments = args

            let errPipe = Pipe()
            process.standardError = errPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: data, encoding: .utf8) ?? "tar exit \(process.terminationStatus)"
                throw NSError(
                    domain: "ModelManager.tar",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Extraction failed: \(msg)"]
                )
            }
        }.value
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
