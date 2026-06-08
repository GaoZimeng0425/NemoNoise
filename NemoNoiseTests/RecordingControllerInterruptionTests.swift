import XCTest
@testable import NemoNoise

@MainActor
final class RecordingControllerInterruptionTests: XCTestCase {
    /// When not recording, an interruption signal must be a safe no-op:
    /// state stays `.ready` and nothing is finalized. (The active-recording
    /// path drives the AVAudioEngine + overlay and is covered by manual QA.)
    func testInterruptionIgnoredWhenNotRecording() {
        let controller = RecordingController()
        XCTAssertEqual(controller.recordingState, .ready)

        controller.handleAudioInterruption(.audioStalled)
        XCTAssertEqual(controller.recordingState, .ready)

        controller.handleAudioInterruption(.deviceConfigurationChanged)
        XCTAssertEqual(controller.recordingState, .ready)
    }
}
