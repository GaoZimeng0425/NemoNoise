# Liquid Glass Overlays — Design

**Date:** 2026-05-15
**Status:** Draft (awaiting user review)
**Scope:** Restyle three overlay surfaces to macOS 26 Liquid Glass.

## Goal

Replace the current `.ultraThickMaterial` + `RoundedRectangle` overlay style
with macOS 26's native Liquid Glass (`.glassEffect()`), adopting Apple's
"discrete glass elements merged by a container" pattern (`GlassEffectContainer`)
so the HUD, subtitle bar, and Toast feel native to Tahoe.

**Non-goals:** redesign interaction or layout semantics; touch NSPanel/window
plumbing; change colors of non-glass UI (menubar icons, settings, onboarding).

## Constraints

- Deployment target is macOS 26.4 — `.glassEffect()`, `GlassEffectContainer`,
  `glassEffectID(_:in:)`, and `.glassEffectMorph` transitions are all available
  natively. No fallback path required.
- Window controllers (`OverlayWindowController`, `SubtitleOverlayController`,
  `ToastWindowController`) already use borderless transparent `NSPanel`s with
  `backgroundColor = .clear`. Glass renders in the SwiftUI layer; panel code
  stays untouched.
- State enum cases are authoritative:
  - `RecordingState`: `.ready`, `.recording`, `.processing`, `.failed(String)`
  - `TranslationState`: `.idle`, `.capturing`, `.error(String)`

## Components

### 1. HUD Overlay — `NemoNoise/UI/Overlay/OverlayView.swift`

Split the current single rounded-rectangle container into **two discrete glass
shapes** wrapped by one `GlassEffectContainer`:

- **Status capsule** (always visible): contains status indicator, timer, and
  `LiveWaveformView`. Shape: `.capsule`. Receives the state tint (see §4).
- **Transcript glass** (visible when `shouldShowTranscript`): contains
  confirmed segments, partial text, and the "I'm listening…" empty-state row.
  Shape: `.rect(cornerRadius: 22)` — transcript can wrap and grow tall,
  capsule would distort. Stays untinted.

Structure:

```swift
@Namespace private var glassNS

GlassEffectContainer(spacing: 8) {
    VStack(spacing: 8) {
        headerBar
            .padding(.horizontal, 16).padding(.vertical, 10)
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
```

Where `statusGlass` is a computed property returning a `Glass` value (use type
inference if the concrete SDK type name shifts between betas):
```swift
private var statusGlass: some Glass {
    if let tint = GlassTint.forHUD(controller.recordingState) {
        Glass.regular.tint(tint)
    } else {
        Glass.regular
    }
}
```
If `some Glass` doesn't resolve, fall back to inlining the ternary at the
`.glassEffect(...)` call site.

**Remove:** the existing outer `.background { RoundedRectangle(...).fill(.ultraThickMaterial).shadow(...) }`
on the root `VStack`. `.glassEffect()` provides shadow and edge highlight; an
extra shadow breaks the glass look.

**Keep unchanged:** `statusIndicator` (the small pulsing red dot stays — see
§4 rationale), `timerText`, `statusText`, `LiveWaveformView`, transcript
content rendering, and all animations on transcript content.

### 2. Subtitle Overlay — `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift`

Same two-glass pattern, but laid out **horizontally** because the subtitle
sits at screen bottom and reads left-to-right:

- **Status capsule** (always visible): state dot + 5-bar waveform. Receives
  `GlassTint.forSubtitle(...)`.
- **Text capsule** (visible when `hasTranscript`): English (gray, small) over
  Chinese (white, large). Shape: `.capsule` is safe here because subtitle
  text is `lineLimit(1)` truncated — height is fixed.

```swift
@Namespace private var glassNS

GlassEffectContainer(spacing: 6) {
    HStack(spacing: 8) {
        statusGroup
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassEffect(subtitleStatusGlass, in: .capsule)
            .glassEffectID("subtitle-status", in: glassNS)

        if hasTranscript {
            textGroup
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .glassEffectID("subtitle-text", in: glassNS)
                .transition(.glassEffectMorph)
        }
    }
}
.frame(minWidth: 220, maxWidth: 900)
```

**Behavior change:** `hasTranscript` is `!controller.englishText.isEmpty || !controller.partialText.isEmpty`.
When false, the existing "Listening…" placeholder text is **not** shown —
the status capsule's presence is enough. (Current behavior keeps an
"Listening…" string visible even when idle, which would manifest as an
empty-content glass capsule.)

**Remove:** the existing `.background { RoundedRectangle(cornerRadius: 12).fill(.ultraThickMaterial) }`.

**Keep unchanged:** `displayEnglishText` / `displayChineseText` logic
(except the empty-state branch noted above), translation task setup,
`waveformBarHeight` math, all `.translationTask` / `.onChange` modifiers.

### 3. Toast — `NemoNoise/UI/Overlay/ToastWindowController.swift`

Only the inner `ToastCapsule` view body changes:

```swift
.padding(.horizontal, 16).padding(.vertical, 10)
.glassEffect(.regular, in: .capsule)
```

**Remove:**
- `.background(.regularMaterial, in: Capsule())`
- `.overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))` — glass
  renders its own edge highlight; double borders look wrong.

**No tint** — the colored SF Symbol icon (`style.icon` rendered in
`style.color`) already conveys severity. Tinting the glass would be redundant
and would compete with the icon's hue.

**No `GlassEffectContainer`** — Toast is a lone capsule; container has nothing
to fuse with.

**Keep unchanged:** `NSAnimationContext` slide-in/slide-out, dismiss timer,
panel sizing/positioning, `ToastStyle` enum.

### 4. Shared tint mapping — `NemoNoise/UI/Overlay/GlassTint.swift` (new)

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
        case .capturing: return .green.opacity(0.12)
        case .idle, .error: return nil
        }
    }
}
```

**Conventions:**

1. Tint is applied **only to status capsules**, never to content capsules
   (transcript / subtitle text). Content glass stays neutral so text contrast
   doesn't drift.
2. Opacity range 0.12–0.18. Higher values overpower the glass material and
   defeat translucency; lower values are imperceptible.
3. No pulse animation on tint. The existing red-dot pulse in HUD
   `statusIndicator` (OverlayView.swift:50–55) already animates the recording
   state; pulsing the tint as well is visual overload.
4. Tint transitions use `.animation(.smooth(duration: 0.4), value: state)`
   attached at the call site so changes in recording/translation state crossfade
   smoothly. macOS 26's default glass animation curve is `.smooth`.
5. Light/Dark mode: `.glassEffect()` materials auto-adapt; tint colors at
   12–18% opacity read correctly in both modes (verified that
   `.red.opacity(0.15)` produces a soft pink in light mode and muted red in
   dark mode — both acceptable).

## Files Touched

| File | Change |
|---|---|
| `NemoNoise/UI/Overlay/OverlayView.swift` | Restructure body to `GlassEffectContainer` + two glass shapes; remove old `RoundedRectangle` background. |
| `NemoNoise/UI/SubtitleOverlay/SubtitleOverlayView.swift` | Restructure body to horizontal `GlassEffectContainer`; drop "Listening…" placeholder when idle; remove old background. |
| `NemoNoise/UI/Overlay/ToastWindowController.swift` | Replace `.background` + `.overlay` on `ToastCapsule` with `.glassEffect(.regular, in: .capsule)`. |
| `NemoNoise/UI/Overlay/GlassTint.swift` | **New file.** Centralized state → tint mapping. |

**Not touched:** `OverlayWindowController.swift`, `SubtitleOverlayController.swift`,
`LiveWaveformView.swift`, any controller/service/pipeline code.

## Risk & Verification

**Visual risk** — tint opacity values are tuned by reading, not measurement.
Verification: launch app, exercise each state (READY → RECORDING → PROCESSING
→ failed; idle → capturing for subtitle), confirm tint is visible but doesn't
overpower glass. Adjust opacity ±0.03 inline if needed.

**Layout risk** — splitting one container into two could change panel sizing.
The `OverlayWindowController.positionOnActiveScreen()` computes position from
`panel.frame.size` after `layoutIfNeeded()`, so any size change is absorbed.
Verification: HUD still centered horizontally, sits 48pt above screen bottom.

**Transition risk** — `.glassEffectMorph` between insert/remove of the
transcript glass needs `@Namespace` and `glassEffectID` to be stable across
re-renders. Verification: start dictation, observe transcript glass "grows"
from the status capsule (not pop-in), then collapses cleanly when dictation
ends.

**No test changes needed** — overlays are SwiftUI views with no logic beyond
state-to-style mapping; existing `SubtitleOverlaySinkTests` and
`OverlayProgressSinkTests` exercise sinks, not view rendering.

## Out of Scope

- Animating tint (kept static; the red-dot already pulses).
- Dynamic-island-style morphing single-capsule (would require
  `matchedGeometryEffect` and panel resize choreography — rejected as
  Option C during brainstorming).
- Restyling Settings/Onboarding/Menubar surfaces.
- Adapting `LiveWaveformView` colors to match tint — bars stay their current
  color so the waveform reads consistently across states.
