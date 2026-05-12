# Custom Hotkey Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace fixed modifier-key hotkey with user-configurable shortcuts supporting arbitrary key combinations.

**Architecture:** Use KeyboardShortcuts library for both recording UI and runtime monitoring. The library's `events(for:)` AsyncStream API provides `.keyDown`/`.keyUp` events, supporting push-to-talk without a custom CGEvent tap. Delete the existing CGEvent tap entirely.

**Tech Stack:** KeyboardShortcuts 2.4.0 (SPM), SwiftUI, Swift concurrency (AsyncStream)

**Spec deviation:** The approved spec called for a hybrid approach (library for recording + CGEvent tap for runtime). The library's built-in `events(for:)` API makes the CGEvent tap unnecessary — same functionality with ~50 fewer lines of complex C-interop code, no locks, no thread safety concerns.

---

### Task 1: Add KeyboardShortcuts SPM dependency

**Files:**
- Modify: `NemoNoise.xcodeproj` (via Xcode)

- [ ] **Step 1: Add package in Xcode**

Open `NemoNoise.xcodeproj` in Xcode → File → Add Package Dependencies → paste:
```
https://github.com/sindresorhus/KeyboardShortcuts
```
Set version rule to "Up to Next Major" from `2.0.0`. Click Add Package, then add `KeyboardShortcuts` library to the `NemoNoise` target.

- [ ] **Step 2: Verify dependency resolves**

Run: `cat NemoNoise.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved | grep -A5 KeyboardShortcuts`
Expected: Package.resolved contains KeyboardShortcuts entry.

- [ ] **Step 3: Commit**

```bash
git add NemoNoise.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved NemoNoise.xcodeproj/project.pbxproj
git commit -m "chore: add KeyboardShortcuts SPM dependency"
```

---

### Task 2: Define shortcut name and migration utility

**Files:**
- Create: `NemoNoise/Services/Input/HotkeyShortcuts.swift`
- Test: `NemoNoiseTests/HotkeyShortcutsTests.swift`

- [ ] **Step 1: Write failing migration test**

```swift
// NemoNoiseTests/HotkeyShortcutsTests.swift
import XCTest
@testable import NemoNoise
import KeyboardShortcuts

final class HotkeyShortcutsTests: XCTestCase {

    func testMigrateFromOptionSetsShortcut() {
        // Simulate old setting
        UserDefaults.standard.set("option", forKey: "hotkeyOption")
        defer { UserDefaults.standard.removeObject(forKey: "hotkeyOption") }

        HotkeyMigration.run()

        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        XCTAssertNotNil(shortcut)
        // Option key = .maskAlternate → carbonModifiers should have it
        XCTAssertTrue(shortcut!.modifiers.contains(.option))
        XCTAssertEqual(shortcut!.carbonKeyCode, 0)

        // Old key should be cleaned up
        XCTAssertNil(UserDefaults.standard.string(forKey: "hotkeyOption"))
    }

    func testMigrateFromRightCommandSetsShortcut() {
        UserDefaults.standard.set("rightCommand", forKey: "hotkeyOption")
        defer { UserDefaults.standard.removeObject(forKey: "hotkeyOption") }

        HotkeyMigration.run()

        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        XCTAssertNotNil(shortcut)
        XCTAssertTrue(shortcut!.modifiers.contains(.command))
        XCTAssertEqual(shortcut!.carbonKeyCode, 0)

        XCTAssertNil(UserDefaults.standard.string(forKey: "hotkeyOption"))
    }

    func testMigrateSkipsIfNoOldSetting() {
        UserDefaults.standard.removeObject(forKey: "hotkeyOption")

        HotkeyMigration.run()

        // Should not crash or set anything unexpected
        XCTAssertNil(UserDefaults.standard.string(forKey: "hotkeyOption"))
    }

    func testMigrateSkipsIfNewShortcutAlreadySet() {
        UserDefaults.standard.set("option", forKey: "hotkeyOption")
        KeyboardShortcuts.setShortcut(.init(.k, modifiers: .command), for: .toggleRecording)
        defer {
            UserDefaults.standard.removeObject(forKey: "hotkeyOption")
            KeyboardShortcuts.setShortcut(nil, for: .toggleRecording)
        }

        HotkeyMigration.run()

        // Should preserve existing shortcut, not overwrite
        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        XCTAssertEqual(shortcut?.carbonKeyCode, KeyboardShortcuts.Shortcut(.k, modifiers: .command).carbonKeyCode)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/HotkeyShortcutsTests 2>&1 | tail -20`
Expected: FAIL — `HotkeyMigration` type not found.

- [ ] **Step 3: Write implementation**

```swift
// NemoNoise/Services/Input/HotkeyShortcuts.swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
}

enum HotkeyMigration {
    static func run() {
        guard let old = UserDefaults.standard.string(forKey: "hotkeyOption") else { return }

        // Don't overwrite if user already set a new shortcut
        if KeyboardShortcuts.getShortcut(for: .toggleRecording) != nil {
            UserDefaults.standard.removeObject(forKey: "hotkeyOption")
            return
        }

        switch old {
        case "option":
            KeyboardShortcuts.setShortcut(
                .init(carbonKeyCode: 0, carbonModifiers: optionCarbonModifiers),
                for: .toggleRecording
            )
        case "rightCommand":
            KeyboardShortcuts.setShortcut(
                .init(carbonKeyCode: 0, carbonModifiers: cmdCarbonModifiers),
                for: .toggleRecording
            )
        default:
            break
        }

        UserDefaults.standard.removeObject(forKey: "hotkeyOption")
    }

    // optionKey -> 0x0800 in Carbon modifiers (right option is different, but NemoNoise used left)
    private static let optionCarbonModifiers = 0x0800
    // cmdKey -> 0x0100 in Carbon modifiers
    private static let cmdCarbonModifiers = 0x0100
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/HotkeyShortcutsTests 2>&1 | tail -20`
Expected: All 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/Services/Input/HotkeyShortcuts.swift NemoNoiseTests/HotkeyShortcutsTests.swift
git commit -m "feat: add KeyboardShortcuts name definition and migration utility"
```

---

### Task 3: Rewrite HotkeyMonitor to use KeyboardShortcuts.events()

**Files:**
- Modify: `NemoNoise/Services/Input/HotkeyMonitor.swift`
- Test: `NemoNoiseTests/HotkeyMonitorTests.swift`

- [ ] **Step 1: Write failing tests for HotkeyMonitor state callbacks**

```swift
// NemoNoiseTests/HotkeyMonitorTests.swift
import XCTest
@testable import NemoNoise

final class HotkeyMonitorTests: XCTestCase {

    func testOnKeyDownCallbackType() {
        let monitor = HotkeyMonitor()
        var fired = false
        monitor.onKeyDown = { fired = true }
        monitor.simulateKeyDown()
        XCTAssertTrue(fired)
    }

    func testOnKeyUpCallbackType() {
        let monitor = HotkeyMonitor()
        var fired = false
        monitor.onKeyUp = { fired = true }
        monitor.simulateKeyUp()
        XCTAssertTrue(fired)
    }

    func testStopCancelsEventStream() {
        let monitor = HotkeyMonitor()
        monitor.start()
        monitor.stop()
        // After stop, callbacks should not fire from simulated events
        var fired = false
        monitor.onKeyDown = { fired = true }
        monitor.simulateKeyDown()
        XCTAssertFalse(fired)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/HotkeyMonitorTests 2>&1 | tail -20`
Expected: FAIL — `simulateKeyDown()` method not found.

- [ ] **Step 3: Rewrite HotkeyMonitor implementation**

Replace entire contents of `NemoNoise/Services/Input/HotkeyMonitor.swift`:

```swift
import KeyboardShortcuts
import os

@MainActor
final class HotkeyMonitor: ObservableObject {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var eventTask: Task<Void, Never>?

    /// For testing: simulate a keyDown event
    func simulateKeyDown() {
        guard eventTask != nil else { return }
        onKeyDown?()
    }

    /// For testing: simulate a keyUp event
    func simulateKeyUp() {
        guard eventTask != nil else { return }
        onKeyUp?()
    }

    func start() {
        guard AXIsProcessTrusted() else {
            LogService.warn("Accessibility permission not granted — hotkey disabled", category: "HotkeyMonitor")
            return
        }

        eventTask = Task { [weak self] in
            for await event in KeyboardShortcuts.events(for: .toggleRecording) {
                guard let self else { return }
                switch event {
                case .keyDown:
                    self.onKeyDown?()
                case .keyUp:
                    self.onKeyUp?()
                }
            }
        }
        LogService.info("Hotkey event stream started", category: "HotkeyMonitor")
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
    }

    deinit {
        eventTask?.cancel()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -only-testing:NemoNoiseTests/HotkeyMonitorTests 2>&1 | tail -20`
Expected: All 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/Services/Input/HotkeyMonitor.swift NemoNoiseTests/HotkeyMonitorTests.swift
git commit -m "feat: rewrite HotkeyMonitor using KeyboardShortcuts.events()"
```

---

### Task 4: Delete HotkeyOption enum

**Files:**
- Modify: `NemoNoise/Models/ASRModels.swift` — delete `HotkeyOption` enum (lines 43-53)

- [ ] **Step 1: Verify no other references to HotkeyOption**

Run: `grep -rn "HotkeyOption" NemoNoise/`
Expected: Only the definition in `ASRModels.swift` and the import in `SettingsView.swift` and `HotkeyMonitor.swift`. If found elsewhere, those references need updating in this step.

- [ ] **Step 2: Delete HotkeyOption enum**

In `NemoNoise/Models/ASRModels.swift`, delete lines 43-53:

```swift
// DELETE THIS ENTIRE BLOCK:
enum HotkeyOption: String, CaseIterable, Codable {
    case option = "⌥ Option"
    case rightCommand = "☘ Right Command"

    var cgFlags: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .rightCommand: return .maskCommand
        }
    }
}
```

- [ ] **Step 3: Build to verify no compilation errors**

Run: `xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED with no errors. (References in SettingsView and RecordingController will be fixed in later tasks.)

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/Models/ASRModels.swift
git commit -m "refactor: remove HotkeyOption enum"
```

---

### Task 5: Update SettingsView shortcuts tab

**Files:**
- Modify: `NemoNoise/UI/Settings/SettingsView.swift`

- [ ] **Step 1: Add import and rewrite shortcutsSection**

In `NemoNoise/UI/Settings/SettingsView.swift`:

Add `import KeyboardShortcuts` at the top.

Replace the `shortcutsSection` (lines 104-126) with:

```swift
private var shortcutsSection: some View {
    Section("Shortcuts") {
        KeyboardShortcuts.Recorder("Activation Key:", name: .toggleRecording) { shortcut in
            conflictWarning = shortcut?.isTakenBySystem == true
        }

        if conflictWarning {
            Label("This shortcut may conflict with a system shortcut", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
        }

        Picker("Mode", selection: Binding(
            get: { controller.recordingMode },
            set: { controller.recordingMode = $0 }
        )) {
            ForEach(RecordingMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }

        if !AXIsProcessTrusted() {
            Label("Accessibility permission required for global hotkey", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            .font(.caption)
        }
    }
}
```

Add state property to `SettingsView`:

```swift
@State private var conflictWarning = false
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add NemoNoise/UI/Settings/SettingsView.swift
git commit -m "feat: replace hotkey picker with KeyboardShortcuts.Recorder"
```

---

### Task 6: Update RecordingController

**Files:**
- Modify: `NemoNoise/App/RecordingController.swift`

- [ ] **Step 1: Rewrite hotkeyDisplayText**

In `NemoNoise/App/RecordingController.swift`, replace `hotkeyDisplayText` (lines 42-54):

```swift
var hotkeyDisplayText: String {
    let keyName: String
    if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
        keyName = shortcut.description
    } else {
        keyName = "Not set"
    }
    switch recordingMode {
    case .pushToTalk:
        return "Hold **\(keyName)** to record"
    case .toggle:
        return "Press **\(keyName)** to start/stop"
    }
}
```

Add `import KeyboardShortcuts` at the top of the file.

- [ ] **Step 2: Add migration call in init**

In the `init()` method, add migration call before `hotkeyMonitor.start()`:

```swift
HotkeyMigration.run()
hotkeyMonitor.start()
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/App/RecordingController.swift
git commit -m "feat: update RecordingController to use KeyboardShortcuts"
```

---

### Task 7: Run full test suite

- [ ] **Step 1: Run all tests**

Run: `xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -30`
Expected: All tests PASS.

- [ ] **Step 2: Run build clean**

Run: `xcodebuild clean build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

---

### Task 8: Manual verification

- [ ] **Step 1: Launch app in Xcode**

Run the app from Xcode (Cmd+R).

- [ ] **Step 2: Verify migration**

Open Settings → Shortcuts tab. If you previously had Option or Right Command selected, it should now appear as a recorded shortcut in the Recorder field.

- [ ] **Step 3: Verify recording UI**

Click the Recorder field, press a new key combination (e.g., Ctrl+Option+R). Verify it appears in the field.

- [ ] **Step 4: Verify push-to-talk**

Set mode to Push-to-talk. Press and hold the recorded shortcut. Verify recording starts. Release. Verify recording stops and text is injected.

- [ ] **Step 5: Verify toggle mode**

Set mode to Toggle. Press the shortcut once. Verify recording starts. Press again. Verify recording stops.

- [ ] **Step 6: Verify conflict warning**

Record a system shortcut (e.g., Cmd+C). Verify yellow warning appears.

- [ ] **Step 7: Verify clear shortcut**

Clear the shortcut (click Recorder, press Delete/Backspace). Verify no global monitoring occurs (hotkey doesn't trigger).

- [ ] **Step 8: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address manual testing findings"
```
