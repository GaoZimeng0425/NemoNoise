# Liquid Glass Overlays Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the HUD, subtitle, and Toast overlays to use macOS 26 Liquid Glass with state-driven tinting and `GlassEffectContainer` merging.

**Architecture:** Each overlay becomes two discrete glass shapes (a status capsule + a content shape) wrapped in a `GlassEffectContainer`. State-to-tint mapping lives in a new `GlassTint` helper. Window/panel plumbing is untouched — all changes happen in SwiftUI view bodies.

**Tech Stack:** SwiftUI on macOS 26.4 (`.glassEffect`, `GlassEffectContainer`, `glassEffectID`, `.glassEffectMorph`); XCTest for the helper's unit tests; manual visual verification for view changes.

**Reference spec:** `docs/superpowers/specs/2026-05-15-liquid-glass-overlays-design.md`

**File map (all paths absolute from repo root):**

| Path | Status | Responsibility |
|---|---|---|
| `NemoNoise/UI/Overlay/GlassTint.swift` | Create | Pure state→Color? mapping for HUD and subtitle tints |
| `NemoNoiseTests/GlassTintTests.swift` | Create | Unit tests for `GlassTint` |
| `NemoNoise/UI/Overlay/ToastWindowController.swift` | Modify | Swap `.background(.regularMaterial)` for `.glassEffect(.regular, in: .capsule)`; remove stroke border |
| `NemoNoise/UI/Overlay/OverlayView.swift` | Modify | Split into status capsule + transcript glass inside `GlassEffectContainer`; apply HUD tint |
| `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift` | Modify | Horizontal two-capsule layout inside `GlassEffectContainer`; drop "Listening…" placeholder when idle |

---

## Task 1: `GlassTint` helper (TDD)

**Files:**
- Create: `NemoNoise/UI/Overlay/GlassTint.swift`
- Test: `NemoNoiseTests/GlassTintTests.swift`

This is the only piece of pure logic in the change — state enums in, optional `Color` out. Writing it test-first locks the mapping table.

- [ ] **Step 1: Write the failing test file**

Create `NemoNoiseTests/GlassTintTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import NemoNoise

final class GlassTintTests: XCTestCase {
    // HUD mapping
    func testHUDReadyReturnsNil() {
        XCTAssertNil(GlassTint.forHUD(.ready))
    }

    func testHUDRecordingReturnsRed() {
        XCTAssertEqual(GlassTint.forHUD(.recording), Color.red.opacity(0.15))
    }

    func testHUDProcessingReturnsBlue() {
        XCTAssertEqual(GlassTint.forHUD(.processing), Color.blue.opacity(0.12))
    }

    func testHUDFailedReturnsOrange() {
        XCTAssertEqual(GlassTint.forHUD(.failed("boom")), Color.orange.opacity(0.18))
    }

    // Subtitle mapping
    func testSubtitleIdleReturnsNil() {
        XCTAssertNil(GlassTint.forSubtitle(.idle))
    }

    func testSubtitleCapturingReturnsGreen() {
        XCTAssertEqual(GlassTint.forSubtitle(.capturing), Color.green.opacity(0.12))
    }

    func testSubtitleErrorReturnsNil() {
        XCTAssertNil(GlassTint.forSubtitle(.error("boom")))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (build error: GlassTint undefined)**

Run:
```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/GlassTintTests 2>&1 | tail -30
```

Expected: build failure with "cannot find 'GlassTint' in scope".

- [ ] **Step 3: Create the helper to make tests pass**

Create `NemoNoise/UI/Overlay/GlassTint.swift`:

```swift
import SwiftUI

enum GlassTint {
    static func forHUD(_ state: RecordingState) -> Color? {
        switch state {
        case .ready:      return nil
        case .recording:  return .red.opacity(0.15)
        case .processing: return .blue.opacity(0.12)
        case .failed:     return .orange.opacity(0.18)
        }
    }

    static func forSubtitle(_ state: TranslationState) -> Color? {
        switch state {
        case .capturing:    return .green.opacity(0.12)
        case .idle, .error: return nil
        }
    }
}
```

- [ ] **Step 4: Add the new files to the Xcode project targets**

Both files need target membership before tests run.

In Xcode, open `NemoNoise.xcodeproj`:
1. Drag `GlassTint.swift` into the `NemoNoise/UI/Overlay/` group, check target **NemoNoise**.
2. Drag `GlassTintTests.swift` into the `NemoNoiseTests/` group, check target **NemoNoiseTests**.

(If automating via `xcodeproj` Ruby gem or similar isn't available, this is a manual step — flag it to the user if running headless.)

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/GlassTintTests 2>&1 | tail -30
```

Expected: `Test Suite 'GlassTintTests' passed` with 7 tests run, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add NemoNoise/UI/Overlay/GlassTint.swift NemoNoiseTests/GlassTintTests.swift NemoNoise.xcodeproj
git commit -m "feat(overlay): add GlassTint state→color mapping helper

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Toast capsule glass

**Files:**
- Modify: `NemoNoise/UI/Overlay/ToastWindowController.swift:104-119` (the `ToastCapsule` view body)

Smallest visual change — does one capsule, no container, no tint. Validates that `.glassEffect()` compiles and renders in our build before tackling the bigger views.

- [ ] **Step 1: Replace the `ToastCapsule` background and overlay**

In `NemoNoise/UI/Overlay/ToastWindowController.swift`, find the `ToastCapsule.body` (around line 104) and change the bottom of the modifier chain.

**Before (current lines 115–118):**
```swift
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
```

**After:**
```swift
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
```

(Two lines deleted: `.background(.regularMaterial, in: Capsule())` and `.overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))`. One line added.)

- [ ] **Step 2: Build to confirm it compiles**

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual visual check — trigger a Toast and verify glass renders**

Build and run the app:
```bash
xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' build && \
  open ~/Library/Developer/Xcode/DerivedData/NemoNoise-*/Build/Products/Debug/NemoNoise.app
```

Trigger a Toast by causing a recognizable warning (e.g. attempt dictation without a downloaded model, or use any UI path that calls `ToastWindowController.show(...)`).

Expected: a translucent capsule slides up from the bottom of the screen. The capsule has glass-style edge highlight (no harsh stroke), background blurs whatever is behind it, icon color matches `ToastStyle` (blue/green/orange/red). Slide-in and auto-dismiss timing unchanged.

If the visual is wrong (e.g. capsule looks opaque, edges harsh), inspect with the SwiftUI inspector or temporarily set the app's appearance to dark mode to verify behavior in both modes.

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/UI/Overlay/ToastWindowController.swift
git commit -m "feat(toast): use Liquid Glass capsule

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: HUD overlay (two-glass + tint)

**Files:**
- Modify: `NemoNoise/UI/Overlay/OverlayView.swift` (full body restructure)

Restructure the body to wrap the header bar and the transcript area in a `GlassEffectContainer`, each as its own glass shape. Apply the HUD tint to the status capsule only.

- [ ] **Step 1: Rewrite the `body` and add `@Namespace` + `statusGlass`**

In `NemoNoise/UI/Overlay/OverlayView.swift`, replace the whole `struct OverlayView` definition from the existing `@State private var isPulsing = false` line down through the closing brace of `body`, with:

```swift
struct OverlayView: View {
    @Environment(RecordingController.self) private var controller

    @State private var isPulsing = false
    @Namespace private var glassNS

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                headerBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(statusGlass, in: .capsule)
                    .glassEffectID("status", in: glassNS)

                if shouldShowTranscript {
                    transcriptArea
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        .glassEffectID("transcript", in: glassNS)
                        .transition(.glassEffectMorph)
                }
            }
        }
        .frame(minWidth: 360, maxWidth: 520)
        .animation(.smooth(duration: 0.4), value: controller.recordingState)
    }

    private var statusGlass: some Glass {
        if let tint = GlassTint.forHUD(controller.recordingState) {
            Glass.regular.tint(tint)
        } else {
            Glass.regular
        }
    }
```

Keep `shouldShowTranscript`, `statusIndicator`, `timerText`, `statusText` **unchanged**. Adjust `headerBar` and `transcriptArea` to drop their inner padding (now applied at the `.glassEffect` call site, otherwise we'd double-pad).

**Three deletions from the old body:**

1. The outer `.background { RoundedRectangle(cornerRadius: 16).fill(.ultraThickMaterial).shadow(...) }` modifier on the root `VStack` is gone — the new `body` shown above has no such outer background.
2. `headerBar`'s trailing `.padding(16)` (see edit below).
3. `transcriptArea`'s trailing `.padding(16)` (see edit below).

Update `headerBar` to drop its trailing `.padding(16)`:

**Before (lines 28–46 in current file):**
```swift
    private var headerBar: some View {
        HStack(spacing: 12) {
            statusIndicator
            …
            LiveWaveformView(...)
            .animation(...)
        }
        .padding(16)
    }
```

**After:**
```swift
    private var headerBar: some View {
        HStack(spacing: 12) {
            statusIndicator
            …
            LiveWaveformView(...)
            .animation(...)
        }
    }
```

(Drop the final `.padding(16)`. Padding now applies at the `.glassEffect` call site.)

Similarly update `transcriptArea` to drop its trailing `.padding(16)`:

**Before (lines 88–133):**
```swift
    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            …
        }
        .padding(16)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: controller.confirmedSegments.count)
    }
```

**After:**
```swift
    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            …
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: controller.confirmedSegments.count)
    }
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

If the compiler rejects `some Glass`, fall back to inlining the glass at the call site:
```swift
.glassEffect(
    GlassTint.forHUD(controller.recordingState).map { Glass.regular.tint($0) } ?? Glass.regular,
    in: .capsule
)
```
and delete the `statusGlass` computed property.

- [ ] **Step 3: Manual visual verification — exercise all four states**

Build and run. Trigger the HUD by starting dictation. Walk through states:

1. **READY** (app idle, HUD invisible or not shown — depending on controller logic, this may not be directly visible).
2. **RECORDING** — start a dictation. Expected:
   - Status capsule visible at bottom-center of screen.
   - Capsule has a subtle red tint blended into the glass.
   - Red dot inside capsule pulses (existing animation).
   - If you start speaking, transcript glass appears below as a separate, slightly rounded shape, and the two glass elements visually fuse/blend at their adjacent edges (GlassEffectContainer merging).
3. **PROCESSING** — finish dictation; capsule briefly takes on a blue tint while engine processes.
4. **ERROR / FAILED** — force an error (disconnect mic mid-recording or trigger via debug menu). Capsule shows orange tint.

Also verify dark mode by switching System Settings → Appearance → Dark and re-triggering.

Expected for all states: glass blur is visible (you can see desktop/windows through it), no double-stroked edges, transitions between states are smooth (no flash/pop).

- [ ] **Step 4: Commit**

```bash
git add NemoNoise/UI/Overlay/OverlayView.swift
git commit -m "feat(overlay): restyle HUD with two-glass capsule + state tint

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Subtitle overlay (horizontal two-capsule)

**Files:**
- Modify: `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift` (full body restructure)

Mirror the HUD pattern, but horizontal. Drop the "Listening…" placeholder so the text capsule disappears when idle.

- [ ] **Step 1: Refactor `body` to a `GlassEffectContainer` with two capsules**

In `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift`, replace the existing `body` (lines 9–77) with:

```swift
    @Namespace private var glassNS

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 8) {
                statusGroup
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(subtitleStatusGlass, in: .capsule)
                    .glassEffectID("subtitle-status", in: glassNS)

                if hasTranscript {
                    textGroup
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("subtitle-text", in: glassNS)
                        .transition(.glassEffectMorph)
                }
            }
        }
        .frame(minWidth: 220, maxWidth: 900)
        .animation(.smooth(duration: 0.4), value: controller.translationState)
        .translationTask(.init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))) { session in
            translationSession = session
            controller.translationService.setSession(session)
        }
        .onChange(of: controller.englishText) { _, newText in
            translationTask?.cancel()
            guard !newText.isEmpty else { return }
            translationTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }

                controller.isTranslating = true
                do {
                    let result = try await controller.translationService.translate(newText)
                    guard !Task.isCancelled else { return }
                    controller.chineseText = result
                } catch is CancellationError {
                    return
                } catch {
                    LogService.warn("Translation failed: \(error.localizedDescription)", category: "Translation")
                    controller.chineseText = "—"
                }
                controller.isTranslating = false
            }
        }
        .onDisappear { translationTask?.cancel() }
    }

    private var hasTranscript: Bool {
        !controller.englishText.isEmpty || !controller.partialText.isEmpty
    }

    private var statusGroup: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.translationState == .capturing ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(controller.translationState == .capturing ? Color.green : Color.secondary.opacity(0.3))
                        .frame(width: 3, height: waveformBarHeight(index: index))
                }
            }
            .frame(height: 20)
            .animation(.easeOut(duration: 0.1), value: controller.audioLevel)
        }
    }

    private var textGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayEnglishText)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(controller.chineseText.isEmpty ? displayEnglishText : controller.chineseText)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subtitleStatusGlass: some Glass {
        if let tint = GlassTint.forSubtitle(controller.translationState) {
            Glass.regular.tint(tint)
        } else {
            Glass.regular
        }
    }
```

- [ ] **Step 2: Update `displayEnglishText` to return empty string when idle**

The current `displayEnglishText` returns `"Listening…"` as a fallback. With `hasTranscript` gating the text capsule, that fallback is no longer reached, but to be safe and self-consistent change it:

**Before (lines 79–87):**
```swift
    private var displayEnglishText: String {
        if !controller.partialText.isEmpty {
            return controller.partialText
        }
        if !controller.englishText.isEmpty {
            return controller.englishText
        }
        return "Listening…"
    }
```

**After:**
```swift
    private var displayEnglishText: String {
        if !controller.partialText.isEmpty {
            return controller.partialText
        }
        return controller.englishText
    }
```

(`hasTranscript` already guards rendering when both strings are empty, so the fallback is unreachable. Returning `englishText` instead of `"Listening…"` removes the dead branch.)

- [ ] **Step 3: Build to confirm it compiles**

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

If `some Glass` fails to compile, use the same inline fallback as in Task 3.

- [ ] **Step 4: Manual visual verification — exercise translation states**

Build, run, and enable translation overlay (the controller exposes a way to start translation — typically a menubar action or hotkey; consult `TranslationController.swift` if unclear).

1. **Idle / not capturing** — only the small status capsule (gray dot + idle waveform bars) is at the bottom of the screen. No "Listening…" text capsule.
2. **Capturing, no audio yet** — status capsule turns green (green tint + green dot + green bars). Still no text capsule.
3. **English text appears (partial)** — text capsule slides/morphs out to the right of the status capsule. Two capsules visibly merge at the edge (GlassEffectContainer fusion).
4. **Chinese translation arrives** — Chinese text replaces English in the larger lower text inside the text capsule; English stays as the smaller upper text.
5. **Stop capturing** — text capsule retracts via `.glassEffectMorph`; only the status capsule remains (gray, no tint).

Verify in both light and dark mode.

Run unit tests too:
```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' \
  -only-testing:NemoNoiseTests/SubtitleOverlaySinkTests 2>&1 | tail -20
```
Expected: existing sink tests still pass (we didn't change the sink, just the view).

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift
git commit -m "feat(subtitle): restyle overlay with horizontal Liquid Glass capsules

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Cross-overlay integration check

**Files:** none modified — verification only.

- [ ] **Step 1: Run the full test suite**

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise \
  -destination 'platform=macOS' 2>&1 | tail -40
```

Expected: all tests pass, including the new `GlassTintTests` and the pre-existing `OverlayProgressSinkTests` / `SubtitleOverlaySinkTests`.

- [ ] **Step 2: Cross-overlay scenario test**

Run the app. Exercise this sequence in one session:

1. Trigger a Toast (e.g. a warning) — confirm glass capsule.
2. Start dictation — HUD glass appears with red-tinted status capsule. Speak briefly — transcript glass grows from below.
3. Stop dictation — transcript glass collapses.
4. Switch to translation mode — subtitle glass appears at bottom.
5. While translation runs, trigger another Toast — Toast should appear above the subtitle without z-fighting or visual glitches (each panel is independent NSPanel).
6. Switch to dark mode mid-session — all three overlays adapt smoothly.

Expected: all overlays read as members of one design system (consistent glass material, consistent corner geometry between status capsules across HUD and subtitle).

If tint opacity feels off after seeing all three live:
- Adjust the constants in `GlassTint.swift` (currently 0.12/0.15/0.18).
- Re-run `GlassTintTests` and update the expected values to match.
- Commit any tweaks as a separate "tune(overlay): adjust glass tint opacity" commit.

- [ ] **Step 3: Final commit (if any tuning was done)**

If you did not adjust opacity, skip this step. Otherwise:

```bash
git add NemoNoise/UI/Overlay/GlassTint.swift NemoNoiseTests/GlassTintTests.swift
git commit -m "tune(overlay): adjust glass tint opacity after visual check

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **No fallback path for pre-macOS 26.** Deployment target is 26.4; `.glassEffect()` and friends are always available.
- **Don't touch the window controllers.** `OverlayWindowController`, `SubtitleOverlayController`, and `ToastWindowController`'s NSPanel setup is already correct (borderless, clear background, floating level). All work is inside SwiftUI view bodies.
- **`LiveWaveformView` is unchanged.** Its bar colors stay as-is so the waveform reads consistently regardless of the surrounding glass tint.
- **The pulsing red dot in HUD's `statusIndicator` is kept.** Spec rationale: tint + dot pulse would be over-animated.
- **If `Glass.regular.tint(...)` syntax is wrong for this SDK build,** the actual macOS 26 API may be `.regular.tint(.red.opacity(0.15))` chained as `Glass` literals. Inline the resolution at the call site if needed (shown in Task 3 fallback).
- **Xcode target membership** is the one thing that requires GUI interaction (or `xcodeproj` Ruby gem manipulation). If running fully headless, halt and ask the user to add the two new files to their targets after Task 1.
