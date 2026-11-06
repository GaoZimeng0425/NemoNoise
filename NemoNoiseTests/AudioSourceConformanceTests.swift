import XCTest
@testable import NemoNoise

nonisolated final class AudioSourceConformanceTests: XCTestCase {
    @MainActor func testMicAudioSourceConformsToAudioSource() {
        let _: any AudioSource = MicAudioSource()
    }

    @MainActor func testSystemAudioSourceConformsToAudioSource() {
        let _: any AudioSource = SystemAudioSource()
    }
}
