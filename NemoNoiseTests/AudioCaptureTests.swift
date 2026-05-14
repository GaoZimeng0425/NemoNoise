import XCTest
@testable import NemoNoise

final class AudioCaptureTests: XCTestCase {

    func testStopWithoutStartDoesNotCrash() {
        let capture = MicAudioSource()
        capture.stop()
    }

    func testMultipleStopsAreSafe() {
        let capture = MicAudioSource()
        capture.stop()
        capture.stop()
        capture.stop()
    }

    func testAudioChunkCreation() {
        let chunk = AudioChunk(samples: [0.1, 0.2, 0.3], rmsLevel: 0.5)
        XCTAssertEqual(chunk.samples, [0.1, 0.2, 0.3])
        XCTAssertEqual(chunk.rmsLevel, 0.5)
    }

    func testAudioChunkWithEmptySamples() {
        let chunk = AudioChunk(samples: [], rmsLevel: 0.0)
        XCTAssertTrue(chunk.samples.isEmpty)
        XCTAssertEqual(chunk.rmsLevel, 0.0)
    }
}
