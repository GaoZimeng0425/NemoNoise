import XCTest
@testable import NemoNoise
import KeyboardShortcuts

final class HotkeyShortcutsTests: XCTestCase {

    override func setUp() {
        KeyboardShortcuts.setShortcut(nil, for: .toggleRecording)
    }

    override func tearDown() {
        KeyboardShortcuts.setShortcut(nil, for: .toggleRecording)
    }

    func testMigrateFromOptionSetsShortcut() {
        UserDefaults.standard.set("option", forKey: "hotkeyOption")
        defer { UserDefaults.standard.removeObject(forKey: "hotkeyOption") }

        HotkeyMigration.run()

        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        XCTAssertNotNil(shortcut)
        XCTAssertTrue(shortcut!.modifiers.contains(.option))
        XCTAssertEqual(shortcut!.carbonKeyCode, 0)

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

        XCTAssertNil(UserDefaults.standard.string(forKey: "hotkeyOption"))
    }

    func testMigrateSkipsIfNewShortcutAlreadySet() {
        UserDefaults.standard.set("option", forKey: "hotkeyOption")
        KeyboardShortcuts.setShortcut(.init(.k, modifiers: .command), for: .toggleRecording)
        defer {
            UserDefaults.standard.removeObject(forKey: "hotkeyOption")
        }

        HotkeyMigration.run()

        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        XCTAssertEqual(shortcut?.carbonKeyCode, KeyboardShortcuts.Shortcut(.k, modifiers: .command).carbonKeyCode)
    }
}
