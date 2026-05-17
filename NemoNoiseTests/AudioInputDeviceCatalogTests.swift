import XCTest
@testable import NemoNoise

final class AudioInputDeviceCatalogTests: XCTestCase {

    func testAvailableInputDevicesIsNonEmpty() {
        // Sanity check: every Mac running these tests has at least one input
        // device (built-in mic, or a CI runner's virtual audio device).
        let devices = AudioInputDeviceCatalog.availableInputDevices()
        XCTAssertFalse(devices.isEmpty, "Expected at least one input device on a Mac")
    }

    func testEveryDeviceHasNonEmptyUIDAndName() {
        let devices = AudioInputDeviceCatalog.availableInputDevices()
        for device in devices {
            XCTAssertFalse(device.uid.isEmpty, "Device UID should not be empty")
            XCTAssertFalse(device.name.isEmpty, "Device name should not be empty")
        }
    }

    func testDeviceIDForUnknownUIDReturnsNil() {
        let id = AudioInputDeviceCatalog.deviceID(forUID: "NEMONOISE_TEST_NOT_A_REAL_DEVICE_UID")
        XCTAssertNil(id)
    }

    func testRoundTripFirstDeviceUID() {
        guard let first = AudioInputDeviceCatalog.availableInputDevices().first else {
            XCTFail("No input devices to round-trip")
            return
        }
        let resolved = AudioInputDeviceCatalog.deviceID(forUID: first.uid)
        XCTAssertNotNil(resolved, "Expected to resolve a UID we just enumerated")
    }
}
