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
