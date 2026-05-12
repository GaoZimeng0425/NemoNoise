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
        manager.senseVoiceState = .downloading(progress: 0.5)
        if case .downloading(let progress) = manager.state(for: .senseVoice) {
            XCTAssertEqual(progress, 0.5, accuracy: 0.01)
        } else {
            XCTFail("Expected downloading state")
        }
    }

    func testStateForParaformer() {
        manager.paraformerState = .downloaded
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
        manager.senseVoiceState = .notDownloaded
        XCTAssertNil(manager.modelPath(for: .senseVoice))
    }

    func testModelPathReturnsNilWhenDownloading() {
        manager.paraformerState = .downloading(progress: 0.7)
        XCTAssertNil(manager.modelPath(for: .paraformer))
    }

    func testModelPathReturnsDirWhenDownloaded() {
        manager.senseVoiceState = .downloaded
        let path = manager.modelPath(for: .senseVoice)
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.path.hasSuffix("sensevoice"))
    }

    func testModelPathReturnsNilWhenError() {
        manager.senseVoiceState = .error("test error")
        XCTAssertNil(manager.modelPath(for: .senseVoice))
    }

    // MARK: - State machine transitions

    func testCancelDownloadResetsToNotDownloaded() {
        manager.senseVoiceState = .downloading(progress: 0.5)
        manager.cancelDownload(.senseVoice)
        XCTAssertEqual(manager.senseVoiceState, .notDownloaded)
    }

    func testCancelDownloadFromNotDownloadedIsNoOp() {
        manager.senseVoiceState = .notDownloaded
        manager.cancelDownload(.senseVoice)
        XCTAssertEqual(manager.senseVoiceState, .notDownloaded)
    }

    func testDeleteModelResetsToNotDownloaded() {
        manager.paraformerState = .downloaded
        manager.deleteModel(.paraformer)
        XCTAssertEqual(manager.paraformerState, .notDownloaded)
    }

    func testStartDownloadDoesNotStartIfNotNotDownloaded() {
        manager.senseVoiceState = .downloaded
        manager.startDownload(.senseVoice)
        XCTAssertEqual(manager.senseVoiceState, .downloaded)
    }

    func testStartDownloadDoesNotStartIfDownloading() {
        manager.paraformerState = .downloading(progress: 0.3)
        manager.startDownload(.paraformer)
        if case .downloading = manager.paraformerState {
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
}
