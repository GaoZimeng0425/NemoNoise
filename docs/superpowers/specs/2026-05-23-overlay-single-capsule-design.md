# Overlay HUD: single morphing glass capsule

## Problem

The current dictation overlay HUD (`OverlayView.swift`) renders **three independent
glass shapes** inside a single `GlassEffectContainer`:

1. `headerBar` — status dot, RECORDING label, timer, spectrum bars — in a
   `.capsule` glass.
2. `engineChip` — engine name (e.g. `sherpa-onnx`) — in its own `.capsule` glass.
3. `transcriptArea` — confirmed + partial text — in a `.rect(cornerRadius: 22)`
   glass.

User feedback: the layout reads as fragmented (three floating slabs), and the
Liquid Glass rim highlights are barely visible because the panel disables the
system shadow (`OverlayWindowController.swift:52` — `panel.hasShadow = false`),
which kills the silhouette contrast that makes Liquid Glass's specular edge
readable.

## Goal

Unify the HUD into **one Liquid Glass surface** that morphs in height as
transcript content arrives, and restore the system shadow so the rim highlight
is visible.

All five content elements stay: status dot, status label, timer, spectrum
bars, engine name, transcript.

## Non-goals

- No change to the pipeline architecture (`docs/architecture.md` stays valid).
- No change to `SubtitleOverlay*` (translation subtitle mode is a separate panel).
- No change to `GlassTint.forHUD(_:)` — same colors, same opacities.
- No change to `SpectrumBarsView` or `OverlayProgressSink` data flow.
- No change to the `RecordingState` machine or `shouldShowTranscript` predicate.

## Design

### Single morphing shape

Replace the three nested `.glassEffect(...)` calls with **one** outer
`.glassEffect(statusGlass, in: .rect(cornerRadius: 26))` wrapping the whole
VStack. The corner radius is fixed at 26pt; because:

- In compact state (header row only, ≈44pt tall) the corner radius exceeds
  height/2, so the shape renders as a pure capsule.
- In expanded state (header + transcript, ≈90pt+ tall) the same corner radius
  renders as a rounded card.

As content height changes, SwiftUI animates the frame and the glass surface
morphs in place. One glass, one `glassEffectID("hud", in: glassNS)`, one tint.

### Engine name → internal chip (not a separate glass)

The engine name (`controller.currentEngineLabel`) keeps a distinct visual
identity but is **no longer its own glass capsule**. It becomes a tinted
non-glass chip inside the main glass:

```swift
Text(controller.currentEngineLabel)
    .font(.system(.caption2, design: .rounded).weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10).padding(.vertical, 4)
    .background(.white.opacity(0.10), in: .capsule)
    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
```

It sits at the trailing end of the header row, after the spectrum bars.

### Final layout

```
GlassEffectContainer(spacing: 8) {
    VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {                           // headerRow
            statusIndicator                              // dot + RECORDING
            Text(timerText)                              // 0:12
            Spacer()
            SpectrumBarsView(spectrum:isActive:barCount:)
            engineNameChip                               // tinted in-glass pill
        }
        if shouldShowTranscript {
            transcriptArea                               // unchanged Text composition
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
```

### Window: re-enable shadow

In `OverlayWindowController.makePanel()`:

```swift
panel.hasShadow = true   // was false
```

All other panel settings stay: `borderless`, `backgroundColor = .clear`,
`isOpaque = false`, `level = .floating`, `collectionBehavior =
[.canJoinAllSpaces, .fullScreenAuxiliary]`.

### Transcript styling — unchanged

`inlineTranscript` keeps its existing composition:
- confirmed segments: `.system(size: 19, weight: .medium, design: .rounded)`,
  `.primary`
- partial: `.system(size: 18, weight: .regular, design: .rounded)`, italic,
  `.secondary`
- `.lineLimit(1).truncationMode(.head)`, `.frame(maxWidth: .infinity,
  alignment: .leading)`

The "I'm listening…" empty-state HStack (mic icon + secondary text) is also
unchanged; it just renders inside the unified glass now.

### State tint table (unchanged)

| `RecordingState` | tint |
|---|---|
| `.ready`      | nil (clear glass) |
| `.recording`  | red @ 0.15 |
| `.processing` | blue @ 0.12 |
| `.failed`     | orange @ 0.18 |

## Files touched

- `NemoNoise/UI/Overlay/OverlayView.swift` — restructure body, drop the two
  inner `.glassEffect()` calls, add `engineNameChip` private var, add the
  `shouldShowTranscript` animation modifier.
- `NemoNoise/UI/Overlay/OverlayWindowController.swift` — flip `hasShadow` to
  `true`.

## Files not touched

- `NemoNoise/UI/Overlay/GlassTint.swift`
- `NemoNoise/UI/Overlay/SpectrumBarsView.swift`
- `NemoNoise/UI/Overlay/ToastWindowController.swift`
- `NemoNoise/UI/SubtitleOverlay/*`
- `NemoNoise/Services/Sinks/*`
- `NemoNoiseTests/GlassTintTests.swift` (assertions against `GlassTint` still
  valid because `forHUD` is unchanged).

## Verification

1. Manual: start dictation. Confirm:
   - HUD is a single glass shape (no visible seam between status / engine /
     transcript regions).
   - System shadow visible on the panel.
   - When recording starts with no transcript, shape reads as a capsule.
   - When transcript arrives, shape smoothly grows downward into a rounded
     card — height transition uses spring, no jarring snap.
   - Engine name still visible inside the header row, with the chip outline.
   - Tints still switch with state (red while recording, blue while
     processing, etc.).
2. Existing `OverlayProgressSinkTests`, `GlassTintTests`,
   `TranscriptionPipelineTests` continue to pass — they don't depend on view
   structure.

## Risks

- **Shadow on a fully transparent panel**: AppKit draws the shadow from the
  rendered content's alpha. Because the only opaque content is the glass
  shape, the shadow follows the rounded-rect silhouette as expected. If the
  shadow looks wrong on real hardware (too harsh, doubled with the glass's
  own inner shadow), fall back to `hasShadow = false` and add an explicit
  `.shadow(radius:y:)` on the glass view instead.
- **Single `glassEffectID` value**: switching from three IDs (`status`,
  `engineChip`, `transcript`) to one (`hud`) means any prior morph-from-old-id
  state is irrelevant — the new HUD always appears/disappears as one unit.
  This is the intended behavior.
