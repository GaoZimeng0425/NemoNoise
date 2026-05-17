# Microphone Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick which microphone is used for voice input (dictation), persisted in Settings, falling back silently to the system default when the chosen device is unavailable.

**Architecture:** A new stateless catalog wraps CoreAudio HAL to enumerate input devices and resolve persistent UIDs to ephemeral `AudioDeviceID`s. `MicAudioSource.start()` reads the preferred UID from `UserDefaults` and sets `kAudioOutputUnitProperty_CurrentDevice` on the `AVAudioEngine` input node's underlying `AudioUnit` before `engine.start()`. The Settings UI gains a SwiftUI `Picker` bound via `@AppStorage`. No pipeline rebuild and no controller-level changes.

**Tech Stack:** Swift / SwiftUI, AVFoundation, CoreAudio HAL (`AudioObjectGetPropertyData`), `UserDefaults` via `@AppStorage`, XCTest. Xcode 16 synchronized folder groups — new files in `NemoNoise/` and `NemoNoiseTests/` are auto-discovered.

**Spec:** `docs/superpowers/specs/2026-05-18-mic-selection-design.md`

---

## File Structure

| Action | Path | Purpose |
|---|---|---|
| Modify | `NemoNoise/Models/AppDefaults.swift` | Add `Keys.preferredMicUID` constant. |
| Create | `NemoNoise/Services/Audio/AudioInputDeviceCatalog.swift` | Stateless enumeration + UID→ID resolution via CoreAudio HAL. |
| Modify | `NemoNoise/Services/Audio/MicAudioSource.swift` | Set chosen device on the input audio unit before `engine.start()`. |
| Modify | `NemoNoise/UI/Settings/SettingsView.swift` | Add "Audio Input" section with a SwiftUI Picker. |
| Create | `NemoNoiseTests/AudioInputDeviceCatalogTests.swift` | Unit tests for the catalog. |

No changes to `PipelineProvider`, controllers, pipeline, sinks, engines, or any other audio source.

---

### Task 1: Add the preference key

**Files:**
- Modify: `NemoNoise/Models/AppDefaults.swift`

- [ ] **Step 1: Add the key constant**

Open `NemoNoise/Models/AppDefaults.swift`. Inside `enum Keys`, add the new line right after `static let languagePreference = "languagePreference"`:

```swift
static let preferredMicUID = "preferredMicUID"
```

The empty-string default is implicit (no entry needed in `enum Defaults` because the consumer reads via `UserDefaults.standard.string(forKey:) ?? ""`).

- [ ] **Step 2: Build to confirm no regression**

Run:
```bash
xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/Models/AppDefaults.swift
git commit -m "feat(audio): add preferredMicUID UserDefaults key

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Audio input device catalog (TDD)

**Files:**
- Create: `NemoNoise/Services/Audio/AudioInputDeviceCatalog.swift`
- Create: `NemoNoiseTests/AudioInputDeviceCatalogTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `NemoNoiseTests/AudioInputDeviceCatalogTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests, confirm they fail to compile**

Run:
```bash
xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: build error referencing `AudioInputDeviceCatalog` not in scope. That's the correct first failure.

- [ ] **Step 3: Implement the catalog**

Create `NemoNoise/Services/Audio/AudioInputDeviceCatalog.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests, confirm they pass**

Run:
```bash
xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: tests pass. Specifically look for `Test Suite 'AudioInputDeviceCatalogTests' passed` and no failures.

If `testAvailableInputDevicesIsNonEmpty` fails on a CI machine with no audio hardware, that's a real environmental issue — note it and proceed (manual QA on a real Mac is the source of truth for this feature).

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/Services/Audio/AudioInputDeviceCatalog.swift NemoNoiseTests/AudioInputDeviceCatalogTests.swift
git commit -m "feat(audio): enumerate input devices via CoreAudio HAL

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Apply preferred device in MicAudioSource

**Files:**
- Modify: `NemoNoise/Services/Audio/MicAudioSource.swift`

No unit test — `MicAudioSource` is manual-QA-only per `docs/architecture.md` (real audio unit, real device). The catalog tests in Task 2 cover the failure modes; the integration in `MicAudioSource` is straightforward.

- [ ] **Step 1: Insert the device-set block**

In `NemoNoise/Services/Audio/MicAudioSource.swift`, replace:

```swift
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
```

with:

```swift
        let inputNode = engine.inputNode
        applyPreferredInputDevice(to: inputNode)
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
```

Then add this method to the same class, immediately above `private func requestMicrophoneAccess()`:

```swift
    /// Reads `AppDefaults.Keys.preferredMicUID` and pins the input audio unit
    /// to that device if it resolves. Any failure falls back silently to the
    /// system default — recording must always work.
    private func applyPreferredInputDevice(to inputNode: AVAudioInputNode) {
        let uid = UserDefaults.standard.string(forKey: AppDefaults.Keys.preferredMicUID) ?? ""
        guard !uid.isEmpty else { return }
        guard let deviceID = AudioInputDeviceCatalog.deviceID(forUID: uid) else {
            LogService.info("Preferred mic UID=\(uid) not connected; using system default", category: "AudioCapture")
            return
        }
        guard let audioUnit = inputNode.audioUnit else {
            LogService.warn("Input node audioUnit unavailable; cannot set preferred mic", category: "AudioCapture")
            return
        }
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
            LogService.warn("AudioUnitSetProperty failed (status=\(status)); using system default", category: "AudioCapture")
        }
    }
```

`MicAudioSource.swift` already imports `AVFoundation` and `os`; `AVFoundation` re-exports `CoreAudio` symbols (`AudioUnitSetProperty`, `kAudioOutputUnitProperty_CurrentDevice`, `AudioDeviceID`), so no new imports are needed.

- [ ] **Step 2: Build**

Run:
```bash
xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the existing test suite to confirm no regression**

Run:
```bash
xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' test 2>&1 | tail -10
```
Expected: all tests pass, including `AudioCaptureTests` and `AudioSourceConformanceTests` (which exercise `MicAudioSource` construction).

- [ ] **Step 4: Manual smoke test (default unchanged)**

Without setting any preference yet:
1. Launch the app from Xcode (`⌘R`).
2. Hold the dictation hotkey, speak a short phrase.
3. Confirm transcript appears as before.
4. In Console.app, filter by `subsystem == "com.nemo.NemoNoise" AND category == "AudioCapture"`. Confirm there is **no** "Mic input set to UID=" line (preference is empty, so we don't try to set).

If transcript appears and no `Mic input set` log line is present, the change is non-invasive — proceed.

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/Services/Audio/MicAudioSource.swift
git commit -m "feat(audio): honor preferredMicUID in MicAudioSource

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Settings UI

**Files:**
- Modify: `NemoNoise/UI/Settings/SettingsView.swift`

- [ ] **Step 1: Add the AppStorage and state for the picker**

In `NemoNoise/UI/Settings/SettingsView.swift`, find the existing `@AppStorage` line:

```swift
    @AppStorage(AppDefaults.Keys.engineType) private var engineType = AppDefaults.Defaults.engineType
```

Add immediately below it:

```swift
    @AppStorage(AppDefaults.Keys.preferredMicUID) private var preferredMicUID = ""
    @State private var availableMics: [AudioInputDevice] = []
```

- [ ] **Step 2: Populate the device list on appear**

Find the existing `.onAppear` block:

```swift
        .onAppear {
            cloudAPIKey = KeychainService.load(key: KeychainService.Keys.cloudAPIKey) ?? ""
            // LSUIElement apps default to .accessory policy which suppresses
            // activation. Briefly switch to .regular so the Settings window
            // can come to the front; .onDisappear flips it back.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
```

Replace with:

```swift
        .onAppear {
            cloudAPIKey = KeychainService.load(key: KeychainService.Keys.cloudAPIKey) ?? ""
            availableMics = AudioInputDeviceCatalog.availableInputDevices()
            // LSUIElement apps default to .accessory policy which suppresses
            // activation. Briefly switch to .regular so the Settings window
            // can come to the front; .onDisappear flips it back.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
```

- [ ] **Step 3: Add the section view**

Inside the `SettingsView` struct, immediately above the existing `private var engineSection: some View {` line, add the new section:

```swift
    private var audioInputSection: some View {
        Section("Audio Input") {
            Picker("Microphone", selection: $preferredMicUID) {
                Text("System Default").tag("")
                ForEach(availableMics) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            Text("Used for voice input only. Real-time subtitles always capture system audio.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
```

- [ ] **Step 4: Mount the section in the Engine tab**

In the existing `engineTab` computed property:

```swift
    private var engineTab: some View {
        Form {
            cloudAPIKeySection
            engineSection
            if engineType == "paraformer" {
                modelSection(for: .paraformer)
            }
            if engineType == "qwen3" {
                modelSection(for: .qwen3)
            }
            modelSection(for: .punctuation)
            privacySection
            aboutSection
        }
        // ... existing .alert continues
```

Add `audioInputSection` between `engineSection` and the `if engineType == "paraformer"` block:

```swift
    private var engineTab: some View {
        Form {
            cloudAPIKeySection
            engineSection
            audioInputSection
            if engineType == "paraformer" {
                modelSection(for: .paraformer)
            }
            if engineType == "qwen3" {
                modelSection(for: .qwen3)
            }
            modelSection(for: .punctuation)
            privacySection
            aboutSection
        }
        // ... existing .alert continues
```

- [ ] **Step 5: Build**

Run:
```bash
xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Run the existing test suite**

Run:
```bash
xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' test 2>&1 | tail -10
```
Expected: all tests pass.

- [ ] **Step 7: Manual QA — full checklist**

Launch the app (`⌘R` in Xcode). Then run each step. Mark each result.

1. **Default unchanged.**
   - Open Settings (menubar gear). Engine tab. Confirm "Audio Input" section with picker showing "System Default" selected.
   - Hold hotkey, speak. Transcript appears.
   - Console: no `Mic input set to UID=` line.
   - ☐ Pass / ☐ Fail

2. **Pick a non-default device.**
   - In the Audio Input picker, pick a non-default mic (e.g. AirPods, USB mic, or built-in if default is something else).
   - Hold hotkey, speak.
   - Open *Audio MIDI Setup*. While speaking, the chosen device's input level meter moves; other devices' meters don't.
   - Console: `Mic input set to UID=<uid>` appears once at recording start.
   - ☐ Pass / ☐ Fail

3. **Disconnect the chosen device.**
   - With a non-default device picked, disconnect it (unplug USB, or turn off Bluetooth).
   - Hold hotkey, speak.
   - Transcript still works (audio captured from system default).
   - Console: `Preferred mic UID=<uid> not connected; using system default`.
   - ☐ Pass / ☐ Fail

4. **Reset to default.**
   - Open Settings, change picker back to "System Default".
   - Hold hotkey, speak. Transcript appears.
   - Console: no `Mic input set` line.
   - ☐ Pass / ☐ Fail

5. **Persistence across launch.**
   - Pick a non-default mic. Quit the app fully (menubar → Quit, or `⌃C` in Xcode).
   - Relaunch. Open Settings. Picker still shows the chosen mic.
   - Hold hotkey, speak. Console: `Mic input set to UID=<uid>`.
   - ☐ Pass / ☐ Fail

If any step fails, do NOT proceed to commit. Investigate, root-cause, then either fix or open a follow-up. Do not paper over a failure.

- [ ] **Step 8: Commit**

```bash
git add NemoNoise/UI/Settings/SettingsView.swift
git commit -m "feat(settings): add microphone picker to Engine tab

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Commit the spec

The design spec was written during brainstorming but deliberately left uncommitted to bundle with the implementation. Commit it now as the final step.

**Files:**
- New: `docs/superpowers/specs/2026-05-18-mic-selection-design.md`
- New: `docs/superpowers/plans/2026-05-18-mic-selection.md`

- [ ] **Step 1: Verify both files exist**

Run:
```bash
ls -la docs/superpowers/specs/2026-05-18-mic-selection-design.md docs/superpowers/plans/2026-05-18-mic-selection.md
```
Expected: both files listed, neither empty.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-05-18-mic-selection-design.md docs/superpowers/plans/2026-05-18-mic-selection.md
git commit -m "docs: spec and plan for microphone selection setting

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 3: Verify branch state**

Run:
```bash
git log --oneline -6
git status
```
Expected: five new commits (preference key, catalog + tests, MicAudioSource integration, settings UI, docs). Working tree clean.

---

## Self-review notes

- **Spec coverage:** every spec section maps to a task. Persistence → Task 1. Catalog → Task 2. MicAudioSource integration → Task 3. Settings UI → Task 4. Spec/plan docs → Task 5. Testing strategy (unit + manual) → Tasks 2 (unit) and 4 (manual QA checklist).
- **No placeholders:** all code is concrete, all paths absolute or repo-relative, all commands runnable.
- **Type consistency:** `AudioInputDevice(uid:name:)`, `AudioInputDeviceCatalog.availableInputDevices()`, `AudioInputDeviceCatalog.deviceID(forUID:)`, `AppDefaults.Keys.preferredMicUID` are used identically across Tasks 2, 3, and 4.
- **Rollback:** if Task 3's manual smoke test fails, `git revert` the Task 3 commit; Tasks 1, 2, 4 are independently shippable (catalog and picker are inert without the MicAudioSource hook, but harmless).
