import XCTest
@testable import NemoNoise

nonisolated final class AudioCaptureTests: XCTestCase {

    @MainActor func testStopWithoutStartDoesNotCrash() {
        let capture = MicAudioSource()
        capture.stop()
    }

    @MainActor func testMultipleStopsAreSafe() {
        let capture = MicAudioSource()
        capture.stop()
        capture.stop()
        capture.stop()
    }

    @MainActor func testAudioChunkCreation() {
        let chunk = AudioChunk(samples: [0.1, 0.2, 0.3], rmsLevel: 0.5, spectrum: [])
        XCTAssertEqual(chunk.samples, [0.1, 0.2, 0.3])
        XCTAssertEqual(chunk.rmsLevel, 0.5)
    }

    @MainActor func testAudioChunkWithEmptySamples() {
        let chunk = AudioChunk(samples: [], rmsLevel: 0.0, spectrum: [])
        XCTAssertTrue(chunk.samples.isEmpty)
        XCTAssertEqual(chunk.rmsLevel, 0.0)
    }
}
