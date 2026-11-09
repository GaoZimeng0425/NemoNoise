import XCTest
@testable import NemoNoise

nonisolated final class ModelManagerTests: XCTestCase {

    /// A manager rooted in a fresh, never-created temp directory: these tests
    /// mutate state and call `deleteModel`, which must not reach the user's
    /// downloaded models in Application Support.
    @MainActor private func makeManager() -> ModelManager {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("NemoNoiseTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("NemoNoise/models", isDirectory: true)
        return ModelManager(baseDir: base)
    }

    // MARK: - State property mapping

    @MainActor func testStateForSenseVoice() {
        let manager = makeManager()
        manager.states[ModelDescriptor.senseVoice.id] = .downloading(progress: 0.5)
        if case .downloading(let progress) = manager.state(for: .senseVoice) {
            XCTAssertEqual(progress, 0.5, accuracy: 0.01)
        } else {
            XCTFail("Expected downloading state")
        }
    }

    @MainActor func testStateForParaformer() {
        let manager = makeManager()
        manager.states[ModelDescriptor.paraformer.id] = .downloaded
        XCTAssertEqual(manager.state(for: .paraformer), .downloaded)
    }

    @MainActor func testStateForUnknownReturnsNotDownloaded() {
        let manager = makeManager()
        let unknown = ModelDescriptor(
            id: "unknown", displayName: "", detail: "", downloadSize: "",
            subdir: "", files: []
        )
        XCTAssertEqual(manager.state(for: unknown), .notDownloaded)
    }

    // MARK: - modelPath

    @MainActor func testModelPathReturnsNilWhenNotDownloaded() {
        let manager = makeManager()
        manager.states[ModelDescriptor.senseVoice.id] = .notDownloaded
        XCTAssertNil(manager.modelPath(for: .senseVoice))
    }

    @MainActor func testModelPathReturnsNilWhenDownloading() {
        let manager = makeManager()
        manager.states[ModelDescriptor.paraformer.id] = .downloading(progress: 0.7)
        XCTAssertNil(manager.modelPath(for: .paraformer))
    }

    @MainActor func testModelPathReturnsDirWhenDownloaded() {
        let manager = makeManager()
        manager.states[ModelDescriptor.senseVoice.id] = .downloaded
        let path = manager.modelPath(for: .senseVoice)
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.path.hasSuffix("sensevoice"))
    }

    @MainActor func testModelPathReturnsNilWhenError() {
        let manager = makeManager()
        manager.states[ModelDescriptor.senseVoice.id] = .error("test error")
        XCTAssertNil(manager.modelPath(for: .senseVoice))
    }

    // MARK: - State machine transitions

    @MainActor func testCancelDownloadResetsToNotDownloaded() {
        let manager = makeManager()
        manager.states[ModelDescriptor.senseVoice.id] = .downloading(progress: 0.5)
        manager.cancelDownload(.senseVoice)
        XCTAssertEqual(manager.state(for: .senseVoice), .notDownloaded)
    }

    @MainActor func testCancelDownloadFromNotDownloadedIsNoOp() {
        let manager = makeManager()
        manager.states[ModelDescriptor.senseVoice.id] = .notDownloaded
        manager.cancelDownload(.senseVoice)
        XCTAssertEqual(manager.state(for: .senseVoice), .notDownloaded)
    }

    @MainActor func testDeleteModelResetsToNotDownloaded() {
        let manager = makeManager()
        manager.states[ModelDescriptor.paraformer.id] = .downloaded
        manager.deleteModel(.paraformer)
        XCTAssertEqual(manager.state(for: .paraformer), .notDownloaded)
    }

    @MainActor func testStartDownloadDoesNotStartIfNotNotDownloaded() {
        let manager = makeManager()
        manager.states[ModelDescriptor.senseVoice.id] = .downloaded
        manager.startDownload(.senseVoice)
        XCTAssertEqual(manager.state(for: .senseVoice), .downloaded)
    }

    @MainActor func testStartDownloadDoesNotStartIfDownloading() {
        let manager = makeManager()
        manager.states[ModelDescriptor.paraformer.id] = .downloading(progress: 0.3)
        manager.startDownload(.paraformer)
        if case .downloading = manager.state(for: .paraformer) {
            // Still downloading, not restarted
        } else {
            XCTFail("Expected still downloading")
        }
    }

    // MARK: - Atomic install (regression: failed download destroyed models)

    /// A descriptor whose file URL is unreachable (port 1 → connection
    /// refused), so `startDownload` fails fast without network dependence.
    private static let unreachableDescriptor = ModelDescriptor(
        id: "unreachable",
        displayName: "Unreachable",
        detail: "",
        downloadSize: "",
        subdir: "unreachable",
        files: [("model.onnx", URL(string: "http://127.0.0.1:1/model.onnx")!)]
    )

    /// Regression for the data-loss bug that deleted the ASR models on
    /// 2026-06-25: `download()` used to remove the destination directory up
    /// front and remove it AGAIN on failure. A failed download must leave
    /// whatever was already on disk untouched.
    @MainActor func testFailedDownloadLeavesExistingFilesIntact() async throws {
        let manager = makeManager()
        let d = Self.unreachableDescriptor

        // Stale partial files sit in the destination (state: not downloaded).
        let dir = manager.modelDir(for: d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sentinel = dir.appendingPathComponent("stale-partial.bin")
        try Data([0x01, 0x02]).write(to: sentinel)
        manager.refreshAll()
        XCTAssertEqual(manager.state(for: d), .notDownloaded)

        manager.startDownload(d)
        // Wait for the download to fail (connection refused is fast, but the
        // URLSession machinery still needs a few runloop turns).
        let deadline = Date().addingTimeInterval(15)
        while manager.state(for: d).isDownloadingState {
            if Date() >= deadline { XCTFail("download did not settle within 15s"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // The pre-existing files survived the failed download.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path),
                      "a failed download must not delete existing files")
        if case .error = manager.state(for: d) {
            // nothing was installed → error state is correct
        } else {
            XCTFail("expected .error state, got \(manager.state(for: d))")
        }
    }

    /// A working install must stay usable when a re-download attempt fails:
    /// state falls back to `.downloaded`, not `.error`/`.notDownloaded`.
    @MainActor func testFailedRedownloadKeepsWorkingModelState() async throws {
        let manager = makeManager()
        let d = Self.unreachableDescriptor

        let dir = manager.modelDir(for: d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x01]).write(to: dir.appendingPathComponent("model.onnx"))  // required item
        // Disk check directly (refreshAll only covers registered descriptors).
        XCTAssertEqual(manager.installedModelDir(for: d)?.path, dir.path,
                       "precondition: required item present on disk")

        // Force a re-download attempt by resetting state (the UI guard normally
        // prevents this, but a missing-file reinstall hits this path).
        manager.states[d.id] = .notDownloaded
        manager.startDownload(d)
        let deadline = Date().addingTimeInterval(15)
        while manager.state(for: d).isDownloadingState {
            if Date() >= deadline { XCTFail("download did not settle within 15s"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(manager.state(for: d), .downloaded,
                       "a failed re-download must keep the working model usable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.onnx").path))
    }

    // MARK: - ModelDescriptor

    @MainActor func testSenseVoiceDescriptorId() {
        XCTAssertEqual(ModelDescriptor.senseVoice.id, "sensevoice")
    }

    @MainActor func testParaformerDescriptorId() {
        XCTAssertEqual(ModelDescriptor.paraformer.id, "paraformer")
    }

    @MainActor func testModelDirForDescriptor() {
        let manager = makeManager()
        let dir = manager.modelDir(for: .senseVoice)
        XCTAssertTrue(dir.path.hasSuffix("NemoNoise/models/sensevoice"))
    }

    @MainActor func testSileroVadDescriptorIsRegistered() {
        let ids = ModelManager.allDescriptors.map(\.id)
        XCTAssertTrue(ids.contains("silero-vad"))
    }

    @MainActor func testSileroVadDescriptorRequiresOnnxFile() {
        let d = ModelDescriptor.sileroVad
        XCTAssertEqual(d.subdir, "silero-vad")
        XCTAssertEqual(d.requiredItems, ["silero_vad.onnx"])
    }
}

private extension ModelDownloadState {
    var isDownloadingState: Bool {
        if case .downloading = self { return true }
        return false
    }
    // MARK: - Installing a staged download

    @MainActor private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mm-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor private func write(_ text: String, _ name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    @MainActor private func read(_ name: String, in dir: URL) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A staged extract missing a required file must not replace a working
    /// install.
    @MainActor func testIncompleteStagingLeavesOldInstallIntact() throws {
        let root = try tempDir()
        let final = root.appendingPathComponent("model")
        let staged = root.appendingPathComponent("staged")
        try write("old", "model.onnx", in: final)
        try write("old", "tokens.txt", in: final)
        try write("new", "model.onnx", in: staged)  // tokens.txt missing

        XCTAssertThrowsError(try ModelManager.installStaged(staged, at: final, requiredItems: ["model.onnx", "tokens.txt"]))
        XCTAssertEqual(read("model.onnx", in: final), "old")
        XCTAssertEqual(read("tokens.txt", in: final), "old")
    }

    @MainActor func testCompleteStagingReplacesOldInstall() throws {
        let root = try tempDir()
        let final = root.appendingPathComponent("model")
        let staged = root.appendingPathComponent("staged")
        try write("old", "model.onnx", in: final)
        try write("stale", "leftover.bin", in: final)
        try write("new", "model.onnx", in: staged)

        try ModelManager.installStaged(staged, at: final, requiredItems: ["model.onnx"])
        XCTAssertEqual(read("model.onnx", in: final), "new")
        XCTAssertNil(read("leftover.bin", in: final), "the old directory is replaced, not merged")
    }

    @MainActor func testStagingInstallsWhenNothingWasThere() throws {
        let root = try tempDir()
        let final = root.appendingPathComponent("nested/model")
        let staged = root.appendingPathComponent("staged")
        try write("new", "model.onnx", in: staged)

        try ModelManager.installStaged(staged, at: final, requiredItems: ["model.onnx"])
        XCTAssertEqual(read("model.onnx", in: final), "new")
    }
}
