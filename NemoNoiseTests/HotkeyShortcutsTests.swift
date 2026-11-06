import XCTest
@testable import NemoNoise
import KeyboardShortcuts

nonisolated final class HotkeyShortcutsTests: XCTestCase {

    /// The test host shares the app's bundle id, so the recording shortcut and
    /// the legacy `hotkeyOption` key are the user's real settings. Start each
    /// test from a cleared shortcut and put the user's values back afterwards.
    @MainActor private func isolateHotkeySettings() -> () -> Void {
        let savedShortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        let savedLegacy = UserDefaultsSnapshot(["hotkeyOption"])
        KeyboardShortcuts.setShortcut(nil, for: .toggleRecording)
        return {
            KeyboardShortcuts.setShortcut(savedShortcut, for: .toggleRecording)
            savedLegacy.restore()
        }
    }

    @MainActor func testMigrateFromOptionSetsShortcut() {
        let restoreSettings = isolateHotkeySettings()
        defer { restoreSettings() }
        UserDefaults.standard.set("option", forKey: "hotkeyOption")

        HotkeyMigration.run()

        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        XCTAssertNotNil(shortcut)
        XCTAssertTrue(shortcut!.modifiers.contains(.option))
        XCTAssertEqual(shortcut!.carbonKeyCode, 0)

        XCTAssertNil(UserDefaults.standard.string(forKey: "hotkeyOption"))
    }

    @MainActor func testMigrateFromRightCommandSetsShortcut() {
        let restoreSettings = isolateHotkeySettings()
        defer { restoreSettings() }
        UserDefaults.standard.set("rightCommand", forKey: "hotkeyOption")

        HotkeyMigration.run()

        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        XCTAssertNotNil(shortcut)
        XCTAssertTrue(shortcut!.modifiers.contains(.command))
        XCTAssertEqual(shortcut!.carbonKeyCode, 0)

        XCTAssertNil(UserDefaults.standard.string(forKey: "hotkeyOption"))
    }

    @MainActor func testMigrateSkipsIfNoOldSetting() {
        let restoreSettings = isolateHotkeySettings()
        defer { restoreSettings() }
        UserDefaults.standard.removeObject(forKey: "hotkeyOption")

        HotkeyMigration.run()

        XCTAssertNil(UserDefaults.standard.string(forKey: "hotkeyOption"))
    }

    @MainActor func testMigrateSkipsIfNewShortcutAlreadySet() {
        let restoreSettings = isolateHotkeySettings()
        defer { restoreSettings() }
        UserDefaults.standard.set("option", forKey: "hotkeyOption")
        KeyboardShortcuts.setShortcut(.init(.k, modifiers: .command), for: .toggleRecording)

        HotkeyMigration.run()

        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        XCTAssertEqual(shortcut?.carbonKeyCode, KeyboardShortcuts.Shortcut(.k, modifiers: .command).carbonKeyCode)
    }
}
