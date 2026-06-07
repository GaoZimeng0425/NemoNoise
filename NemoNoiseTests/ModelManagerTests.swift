import XCTest
@testable import NemoNoise

final class ModelManagerTests: XCTestCase {

    private var manager: ModelManager!

    override func setUp() {
        manager = ModelManager()
    }

    override func tearDown() {
        manager = nil
    }

    // MARK: - State property mapping

    func testStateForSenseVoice() {
        manager.states[ModelDescriptor.senseVoice.id] = .downloading(progress: 0.5)
        if case .downloading(let progress) = manager.state(for: .senseVoice) {
            XCTAssertEqual(progress, 0.5, accuracy: 0.01)
        } else {
            XCTFail("Expected downloading state")
        }
    }

    func testStateForParaformer() {
        manager.states[ModelDescriptor.paraformer.id] = .downloaded
        XCTAssertEqual(manager.state(for: .paraformer), .downloaded)
    }

    func testStateForUnknownReturnsNotDownloaded() {
        let unknown = ModelDescriptor(
            id: "unknown", displayName: "", detail: "", downloadSize: "",
            subdir: "", files: []
        )
        XCTAssertEqual(manager.state(for: unknown), .notDownloaded)
    }

    // MARK: - modelPath

    func testModelPathReturnsNilWhenNotDownloaded() {
        manager.states[ModelDescriptor.senseVoice.id] = .notDownloaded
        XCTAssertNil(manager.modelPath(for: .senseVoice))
    }

    func testModelPathReturnsNilWhenDownloading() {
        manager.states[ModelDescriptor.paraformer.id] = .downloading(progress: 0.7)
        XCTAssertNil(manager.modelPath(for: .paraformer))
    }

    func testModelPathReturnsDirWhenDownloaded() {
        manager.states[ModelDescriptor.senseVoice.id] = .downloaded
        let path = manager.modelPath(for: .senseVoice)
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.path.hasSuffix("sensevoice"))
    }

    func testModelPathReturnsNilWhenError() {
        manager.states[ModelDescriptor.senseVoice.id] = .error("test error")
        XCTAssertNil(manager.modelPath(for: .senseVoice))
    }

    // MARK: - State machine transitions

    func testCancelDownloadResetsToNotDownloaded() {
        manager.states[ModelDescriptor.senseVoice.id] = .downloading(progress: 0.5)
        manager.cancelDownload(.senseVoice)
        XCTAssertEqual(manager.state(for: .senseVoice), .notDownloaded)
    }

    func testCancelDownloadFromNotDownloadedIsNoOp() {
        manager.states[ModelDescriptor.senseVoice.id] = .notDownloaded
        manager.cancelDownload(.senseVoice)
        XCTAssertEqual(manager.state(for: .senseVoice), .notDownloaded)
    }

    func testDeleteModelResetsToNotDownloaded() {
        manager.states[ModelDescriptor.paraformer.id] = .downloaded
        manager.deleteModel(.paraformer)
        XCTAssertEqual(manager.state(for: .paraformer), .notDownloaded)
    }

    func testStartDownloadDoesNotStartIfNotNotDownloaded() {
        manager.states[ModelDescriptor.senseVoice.id] = .downloaded
        manager.startDownload(.senseVoice)
        XCTAssertEqual(manager.state(for: .senseVoice), .downloaded)
    }

    func testStartDownloadDoesNotStartIfDownloading() {
        manager.states[ModelDescriptor.paraformer.id] = .downloading(progress: 0.3)
        manager.startDownload(.paraformer)
        if case .downloading = manager.state(for: .paraformer) {
            // Still downloading, not restarted
        } else {
            XCTFail("Expected still downloading")
        }
    }

    // MARK: - ModelDescriptor

    func testSenseVoiceDescriptorId() {
        XCTAssertEqual(ModelDescriptor.senseVoice.id, "sensevoice")
    }

    func testParaformerDescriptorId() {
        XCTAssertEqual(ModelDescriptor.paraformer.id, "paraformer")
    }

    func testModelDirForDescriptor() {
        let dir = manager.modelDir(for: .senseVoice)
        XCTAssertTrue(dir.path.hasSuffix("NemoNoise/models/sensevoice"))
    }

    func testSileroVadDescriptorIsRegistered() {
        let ids = ModelManager.allDescriptors.map(\.id)
        XCTAssertTrue(ids.contains("silero-vad"))
    }

    func testSileroVadDescriptorRequiresOnnxFile() {
        let d = ModelDescriptor.sileroVad
        XCTAssertEqual(d.subdir, "silero-vad")
        XCTAssertEqual(d.requiredItems, ["silero_vad.onnx"])
    }
}
