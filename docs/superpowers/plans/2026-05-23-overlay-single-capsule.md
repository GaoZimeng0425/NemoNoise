# Overlay Single-Capsule HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three-glass dictation HUD with a single morphing Liquid Glass shape and restore the panel system shadow.

**Architecture:** Wrap the entire `OverlayView` content (headerRow + optional transcript) in one `.glassEffect(statusGlass, in: .rect(cornerRadius: 26))` inside the existing `GlassEffectContainer`. The engine name becomes a tinted in-glass chip (no separate `.glassEffect`). Re-enabling `NSPanel.hasShadow` restores the silhouette so Liquid Glass's rim highlight reads.

**Tech Stack:** SwiftUI (macOS Tahoe Liquid Glass API), AppKit `NSPanel`, Xcode `xcodebuild`.

**Reference spec:** `docs/superpowers/specs/2026-05-23-overlay-single-capsule-design.md`

---

## Task 1: Re-enable panel system shadow

**Files:**
- Modify: `NemoNoise/UI/Overlay/OverlayWindowController.swift:52`

- [ ] **Step 1: Read current `makePanel()`**

Read `NemoNoise/UI/Overlay/OverlayWindowController.swift` lines 34–58. Locate the line `panel.hasShadow = false`.

- [ ] **Step 2: Flip the shadow flag**

Change:

```swift
panel.hasShadow = false
```

to:

```swift
panel.hasShadow = true
```

No other lines in this file change.

- [ ] **Step 3: Build the app**

Run:

```bash
xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug build -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manually verify shadow**

Run the app from Xcode (`Cmd+R`). Trigger the dictation HUD (whatever hotkey/menu action shows it — typically the user's configured hotkey starts recording). Confirm there is now a visible drop shadow under the HUD's glass shape. The shape is still rendered with three internal glass capsules at this point — that's expected, this task only changes the shadow.

- [ ] **Step 5: Commit**

```bash
git add NemoNoise/UI/Overlay/OverlayWindowController.swift
git commit -m "$(cat <<'EOF'
fix(overlay): re-enable system shadow on HUD panel

The HUD panel had hasShadow = false, which suppressed the silhouette
contrast that Liquid Glass's rim highlight depends on. Enabling the
system shadow restores the floating glass look without changing any
other panel settings.
EOF
)"
```

---

## Task 2: Unify the HUD into one morphing glass shape

**Files:**
- Modify: `NemoNoise/UI/Overlay/OverlayView.swift` (replace `body`, replace `headerBar`, remove `engineChip`, add `engineNameChip`)

- [ ] **Step 1: Read the current view**

Read `NemoNoise/UI/Overlay/OverlayView.swift` end-to-end (lines 1–165). Note these regions you will replace:
- `body` (lines 13–41) — currently has two `.glassEffect()` calls in an HStack and a third one on `transcriptArea` inside an `if`.
- `engineChip` (lines 43–50) — separate private var used as its own glass capsule.
- `headerBar` (lines 56–73) — the dot + RECORDING + timer + spectrum row.

You will keep these unchanged:
- `shouldShowTranscript` (lines 52–54)
- `statusIndicator` (lines 75–89)
- `timerText` (lines 91–104)
- `statusText` (lines 106–113)
- `transcriptArea` (lines 115–136)
- `inlineTranscript` (lines 138–163)

- [ ] **Step 2: Replace `body`**

Replace the entire `body` computed property (currently lines 13–41) with this implementation:

```swift
var body: some View {
    GlassEffectContainer(spacing: 8) {
        VStack(alignment: .leading, spacing: 8) {
            headerBar

            if shouldShowTranscript {
                transcriptArea
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(statusGlass, in: .rect(cornerRadius: 26))
        .glassEffectID("hud", in: glassNS)
    }
    .frame(minWidth: 360, maxWidth: 520)
    .animation(.smooth(duration: 0.4), value: controller.recordingState)
    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: shouldShowTranscript)
}
```

Notes:
- `headerBar` no longer takes its own `.padding(...)` / `.glassEffect(...)` modifiers — those moved up to the unified container.
- The trailing `engineChip` from the old HStack is gone from `body`; it gets re-introduced as an in-glass chip inside `headerBar` in step 3.
- `transcriptArea` no longer takes `.padding(16)` / `.glassEffect(...)` / `.glassEffectID(...)` — same reason.

- [ ] **Step 3: Replace `headerBar` and add `engineNameChip`**

Replace the existing `headerBar` private var (lines 56–73) with:

```swift
private var headerBar: some View {
    HStack(spacing: 12) {
        statusIndicator

        Text(timerText)
            .font(.system(.caption, design: .monospaced))
            .fontWeight(.medium)
            .foregroundStyle(.secondary)

        Spacer()

        SpectrumBarsView(
            spectrum: controller.spectrum,
            isActive: controller.recordingState == .recording,
            barCount: 16
        )

        engineNameChip
    }
}

private var engineNameChip: some View {
    Text(controller.currentEngineLabel)
        .font(.system(.caption2, design: .rounded).weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.white.opacity(0.10), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .fixedSize()
}
```

- [ ] **Step 4: Remove the old `engineChip`**

Delete the old `engineChip` private var (was lines 43–50):

```swift
private var engineChip: some View {
    Text(controller.currentEngineLabel)
        .font(.system(.caption2, design: .rounded))
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
}
```

`engineNameChip` from step 3 replaces it.

- [ ] **Step 5: Build the app**

Run:

```bash
xcodebuild -project NemoNoise.xcodeproj -scheme NemoNoise -configuration Debug build -quiet
```

Expected: `** BUILD SUCCEEDED **`. If Swift errors mention `engineChip` still being referenced, you missed a usage — search the file: `grep -n engineChip NemoNoise/UI/Overlay/OverlayView.swift` (should print nothing).

- [ ] **Step 6: Run unit tests**

Run:

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS' -quiet 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **`. Specifically `GlassTintTests`, `OverlayProgressSinkTests`, and `TranscriptionPipelineTests` should all pass — none of them touch view structure, so they should continue to pass unchanged.

- [ ] **Step 7: Manually verify single-glass morphing**

Run the app (`Cmd+R`). Trigger recording. Verify:

1. **Idle/start state**: the HUD shows as a single horizontal capsule with a visible drop shadow. No seam between the status region, the spectrum bars region, and the engine name. The engine name appears as a small inset chip with a hairline border, inside the main glass.
2. **Tint**: while recording, the glass shows a faint red tint (`GlassTint.forHUD(.recording)`). Stop recording → during processing the tint switches to faint blue.
3. **Transcript morph**: speak something so transcript text appears. Confirm the shape grows downward into a rounded-card silhouette (same rounded corners, more height), and the growth uses a spring (smooth, slightly bouncy — not a hard snap). When the transcript clears, the shape collapses back to the capsule form.
4. **Empty-state listening prompt**: when the empty-state branch in `transcriptArea` fires ("I'm listening…" with the mic icon), it should appear inside the same unified glass, not in a separate slab.
5. **Failed state**: if you can trigger an engine failure (e.g. disable network on a network engine), confirm the tint shifts to faint orange (`GlassTint.forHUD(.failed)`).

If anything looks wrong (double glass surfaces, jarring snap during morph, missing chip border, shadow doubled), stop and re-read the spec at `docs/superpowers/specs/2026-05-23-overlay-single-capsule-design.md` — the spec includes a fallback for the shadow risk: revert `panel.hasShadow = true` and add `.shadow(radius:y:)` directly on the glass view instead.

- [ ] **Step 8: Commit**

```bash
git add NemoNoise/UI/Overlay/OverlayView.swift
git commit -m "$(cat <<'EOF'
refactor(overlay): unify HUD into single morphing Liquid Glass shape

Replace the three separate .glassEffect() calls (headerBar capsule,
engineChip capsule, transcript rect) with one .rect(cornerRadius: 26)
wrapping the whole VStack. Height grows naturally when transcript
arrives — the same shape reads as a capsule when short and as a
rounded card when tall.

The engine name keeps its own visual identity as a tinted in-glass
chip with a hairline border, but is no longer a separate glass
surface.

Spec: docs/superpowers/specs/2026-05-23-overlay-single-capsule-design.md
EOF
)"
```

---

## Verification checklist (after both tasks)

- [ ] `git log --oneline -3` shows the two new commits on top
- [ ] `grep -n engineChip NemoNoise/UI/Overlay/OverlayView.swift` returns nothing
- [ ] `grep -n "hasShadow = false" NemoNoise/UI/Overlay/OverlayWindowController.swift` returns nothing
- [ ] App builds, unit tests pass
- [ ] Visual verification from Task 2 Step 7 all pass
