# Custom Hotkey Recording Design

**Date**: 2026-05-12
**Status**: Approved

## Goal

Replace the fixed modifier-key-only hotkey system with user-configurable shortcuts that support arbitrary key combinations (modifier+key, single key, function keys, etc.).

## Approach

Hybrid: third-party library for recording UI + existing CGEvent tap for runtime monitoring.

### Library

[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by sindresorhus:
- SwiftUI-native `Recorder()` view for capturing shortcuts
- Automatic UserDefaults storage
- Well-maintained, pure Swift, lightweight

### Runtime

Retain and extend the existing `HotkeyMonitor` CGEvent tap:
- Expand `eventMask` to include `keyDown` + `keyUp` in addition to `flagsChanged`
- Match on modifier flags + keyCode (read from KeyboardShortcuts storage)

## Data Flow

```
User records shortcut in Settings
  → KeyboardShortcuts stores (carbonKeyCode + carbonModifiers)
  → HotkeyMonitor reads stored shortcut at runtime
  → CGEvent tap monitors flagsChanged + keyDown/keyUp
  → Matches user-defined combination
```

## Detailed Design

### Data Model

Delete `HotkeyOption` enum from `ASRModels.swift`.

Define shortcut name:
```swift
extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
}
```

### HotkeyMonitor Changes

- `eventMask`: add `keyDown` and `keyUp` event types
- Read shortcut via `KeyboardShortcuts.getShortcut(for: .toggleRecording)`
- Convert `carbonModifiers` to `CGEventFlags` for matching
- Use `carbonKeyCode` directly (same encoding as `CGKeyCode`)
- Track `keyCode` state for keyDown/keyUp pairing

### Matching Logic

**keyDown event**:
1. `event.flags` contains required modifiers
2. `event.keyCode` matches stored keyCode
3. No extra modifiers present (strict match)
4. Trigger recording start

**keyUp event**:
1. `keyCode` matches stored keyCode
2. In Push-to-talk mode: trigger recording stop

### Edge Cases

- **Modifier-only shortcut** (e.g., Option): keyCode = 0, match via flagsChanged only
- **Escape cancels recording**: handled by KeyboardShortcuts built-in
- **No shortcut set**: disable global hotkey monitoring entirely
- **Modifier + modifier** (e.g., Ctrl+Option): no keyCode, flagsChanged branch only

### Settings UI

- Replace `HotkeyOption` Picker with `KeyboardShortcuts.Recorder()`
- Add conflict warning: maintain a blacklist of common system shortcuts (Cmd+C, Cmd+V, Cmd+Q, Cmd+Space, etc.), show yellow warning text when matched, but allow the setting
- Keep RecordingMode (Push-to-talk / Toggle) Picker

### Migration

One-time migration from old `hotkeyOption` UserDefaults key:
- `"option"` → set KeyboardShortcuts to Option (no keyCode)
- `"rightCommand"` → set KeyboardShortcuts to Right Command (no keyCode)
- Delete old UserDefaults key after migration

## Files Changed

| File | Change |
|------|--------|
| Xcode project / Package.resolved | Add KeyboardShortcuts SPM dependency |
| `HotkeyMonitor.swift` | Extend eventMask, refactor matching to modifier+keyCode, read from KeyboardShortcuts |
| `ASRModels.swift` | Delete `HotkeyOption` enum |
| `SettingsView.swift` | Replace Picker with `KeyboardShortcuts.Recorder()`, add conflict warning, keep RecordingMode Picker |
| `RecordingController.swift` | Adapt to new shortcut reading interface if needed |

## Files NOT Changed

- `AudioCapture`, ASR engines, `TextInjector`, Overlay — unaffected
- `RecordingMode` enum stays the same

## Test Points

- Recording UI: click to record, press key, display shortcut
- Push-to-talk: hold to start, release to stop
- Toggle: press once to start, press again to stop
- Modifier-only shortcut (e.g., Option alone)
- Modifier + regular key (e.g., Ctrl+Option+R)
- Single regular key (e.g., F6)
- Clear shortcut disables global monitoring
- Old settings migration works correctly
