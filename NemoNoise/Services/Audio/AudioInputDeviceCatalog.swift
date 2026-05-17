import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Read-only CoreAudio HAL queries. No state, no I/O beyond synchronous HAL
/// reads; safe to call from any thread, including MainActor.
enum AudioInputDeviceCatalog {

    /// Every audio device with at least one input stream, in HAL order.
    static func availableInputDevices() -> [AudioInputDevice] {
        return allDeviceIDs()
            .filter { hasInputStream($0) }
            .compactMap { id in
                guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                      let name = stringProperty(id, kAudioObjectPropertyName)
                else { return nil }
                return AudioInputDevice(uid: uid, name: name)
            }
    }

    /// Resolve a persistent UID to the current ephemeral `AudioDeviceID`,
    /// or `nil` if no connected device matches.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for id in allDeviceIDs() {
            if stringProperty(id, kAudioDevicePropertyDeviceUID) == uid {
                return id
            }
        }
        return nil
    }

    // MARK: - HAL helpers

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buf in
            AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, buf.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    private static func hasInputStream(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr
        else { return false }
        return dataSize > 0
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = cfString else { return nil }
        return cf.takeRetainedValue() as String
    }
}
