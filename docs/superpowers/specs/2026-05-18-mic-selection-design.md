# Microphone Selection in Settings

Date: 2026-05-18
Status: Approved

## Problem

`MicAudioSource` uses `AVAudioEngine().inputNode`, which always follows whatever macOS has set as the system default input device. The user has no way to pick a specific mic from inside the app. This matters when:

- The user keeps a virtual loopback device (BlackHole / Loopback) as the system default for other workflows but wants dictation to use their physical USB / built-in mic.
- The user has multiple physical mics connected (built-in + USB headset) and wants dictation pinned to one regardless of which macOS happens to pick as default.

## Goals

- Add a control in Settings → Engine tab to pick the input device used by voice input (dictation).
- Persist the selection across launches.
- Apply on the next recording, with no pipeline rebuild and no engine reload.
- Silently fall back to system default if the chosen device is unavailable at recording time.

## Non-goals

- Choosing a system-audio source for translation mode — translation captures via `ScreenCaptureKit` and has no concept of "which mic." Untouched.
- Live re-routing of an in-progress recording when the chosen device disappears mid-stream — recording continues on whatever it already opened. Next recording picks up the new state.
- Hot-plug refresh of the device picker — the list is rebuilt each time Settings appears. Plugging in a device while Settings is open does not auto-update the list.
- Filtering "virtual" devices like BlackHole — these are shown as-is. The user may intentionally want one.
- Mic AEC / echo cancellation — separate concern, deferred.

## Design

### Persistence

One new key in `Models/AppDefaults.swift`:

```swift
static let preferredMicUID = "preferredMicUID"
```

Default value: empty string, meaning "use the system default input device." This is the only signal the rest of the code needs.

### Device enumeration

New file `Services/Audio/AudioInputDeviceCatalog.swift`. Pure, stateless, read-only — no instances, just static functions.

```swift
struct AudioInputDevice: Identifiable, Hashable {
    let uid: String   // stable identifier (kAudioDevicePropertyDeviceUID)
    let name: String  // display label (kAudioObjectPropertyName)
    var id: String { uid }
}

enum AudioInputDeviceCatalog {
    /// All audio devices that have at least one input stream.
    static func availableInputDevices() -> [AudioInputDevice]

    /// Resolve a persistent UID to the current ephemeral AudioDeviceID.
    /// Returns nil if no device with that UID is currently connected.
    static func deviceID(forUID uid: String) -> AudioDeviceID?
}
```

Uses CoreAudio HAL:
- `kAudioHardwarePropertyDevices` → list of all `AudioDeviceID`s.
- Filter by `kAudioDevicePropertyStreams` scope `Input` count > 0.
- Read `kAudioDevicePropertyDeviceUID` (string) and `kAudioObjectPropertyName` (string) for each.
- `deviceID(forUID:)` re-enumerates and matches by UID.

Why UID, not `AudioDeviceID`: `AudioDeviceID` is ephemeral — it can change across reboots and reconnects. `kAudioDevicePropertyDeviceUID` is the stable identifier macOS itself uses for persisting audio preferences. We persist UID, resolve to ID at start time.

### Applying the selection in `MicAudioSource`

Single insertion in `MicAudioSource.start()`, after `engine.inputNode` is obtained and before `outputFormat(forBus:)` is read:

```swift
let uid = UserDefaults.standard.string(forKey: AppDefaults.Keys.preferredMicUID) ?? ""
if !uid.isEmpty,
   let deviceID = AudioInputDeviceCatalog.deviceID(forUID: uid),
   let audioUnit = inputNode.audioUnit {
    var id = deviceID
    let status = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &id,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    if status == noErr {
        LogService.info("Mic input set to UID=\(uid)", category: "AudioCapture")
    } else {
        LogService.warn("Failed to set mic input (status=\(status)); using system default", category: "AudioCapture")
    }
}
```

Any failure path — empty UID, UID unknown, `AudioUnitSetProperty` non-zero — leaves the input node on whatever the default behavior would have produced. **Worst case = today's behavior.** This is the central reason this change is safe to land where the AEC attempt wasn't: it cannot leave the audio unit in a configuration that was never working before.

The property must be set before `engine.start()`. The insertion point above satisfies that.

### Settings UI

New `audioInputSection` in the Engine tab of `UI/Settings/SettingsView.swift`, placed under the existing `engineSection`:

```swift
private var audioInputSection: some View {
    Section("Audio Input") {
        Picker("Microphone", selection: $preferredMicUID) {
            Text("System Default").tag("")
            ForEach(availableMics) { device in
                Text(device.name).tag(device.uid)
            }
        }
        Text("Used by voice input. Real-time subtitles always capture system audio.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
```

Where:

- `@AppStorage(AppDefaults.Keys.preferredMicUID) private var preferredMicUID = ""`
- `@State private var availableMics: [AudioInputDevice] = []`
- `availableMics` is populated in the existing `.onAppear` block alongside `cloudAPIKey` loading: `availableMics = AudioInputDeviceCatalog.availableInputDevices()`.

No `onChange` handler, no pipeline rebuild call. The next `MicAudioSource.start()` reads `UserDefaults` directly.

### Edge case: persisted UID belongs to a now-disconnected device

`Picker` will not display a matching option, so SwiftUI renders the picker as if no selection were made (it falls back to showing the first option's label, which is "System Default"). The stored UID is unchanged — if the device returns later, the picker will re-show its real selection on the next Settings open. Acceptable for v1; no special handling needed.

## Testing

### Unit tests

- `AudioInputDeviceCatalogTests.swift`:
  - `availableInputDevices()` returns a non-empty list on a normal Mac (sanity test, will run on CI / dev machines that have audio hardware).
  - `deviceID(forUID:)` returns nil for a clearly nonexistent UID like `"DOES_NOT_EXIST"`.
  - `deviceID(forUID:)` round-trips: enumerate, pick the first, look it up by UID, get back its ID.

No unit test for `MicAudioSource` device selection — that path is integration-heavy (real audio unit, real device), and the existing approach for `MicAudioSource` is manual QA only. Matches the testing strategy in `docs/architecture.md`.

### Manual QA checklist

1. **Default unchanged.** Fresh setting (`preferredMicUID == ""`). Hold hotkey, speak → transcript appears normally. Logs do not contain "Mic input set to UID=...".
2. **Pick a non-default device.** With a USB / Bluetooth mic connected: pick it in Settings, record. Verify in macOS *Audio MIDI Setup* that the chosen device's input level meter moves while the other devices' meters do not. Logs contain "Mic input set to UID=...".
3. **Disconnect the chosen device.** Pick a USB mic, unplug it, record → falls back silently, transcript still works. Logs may contain "Failed to set mic input" or no "Mic input set" line, depending on whether the device disappeared before or after enumeration.
4. **Reset to default.** Switch the picker back to "System Default" → records using the system default again.
5. **Restart app with custom selection.** Set a non-default mic, quit, relaunch, record → still uses the chosen mic (UID persistence).

## Files touched

| File | Change |
|---|---|
| `Models/AppDefaults.swift` | Add `Keys.preferredMicUID`. |
| `Services/Audio/AudioInputDeviceCatalog.swift` | New file. Static enumeration + UID→ID lookup. |
| `Services/Audio/MicAudioSource.swift` | Add device-set block before `outputFormat(forBus:)`. |
| `UI/Settings/SettingsView.swift` | Add `@AppStorage` for UID, `@State` for device list, `audioInputSection`, populate list in `.onAppear`. |
| `NemoNoiseTests/AudioInputDeviceCatalogTests.swift` | New test file. |

No changes to `PipelineProvider`, controllers, the pipeline, or any sink/engine.

## Rollback plan

The change is additive. If anything misbehaves:

1. Delete the device-set block in `MicAudioSource.swift` — restores prior behavior in one revert.
2. Picker becomes a dead control; can be removed in a follow-up commit.

No data migration concerns — `preferredMicUID` is a leaf preference; leaving stale values in `UserDefaults` is harmless.
