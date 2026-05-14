import XCTest
@testable import NemoNoise

final class AudioSourceConformanceTests: XCTestCase {
    func testMicAudioSourceConformsToAudioSource() {
        let _: any AudioSource = MicAudioSource()
    }

    func testSystemAudioSourceConformsToAudioSource() {
        let _: any AudioSource = SystemAudioSource()
    }
}
