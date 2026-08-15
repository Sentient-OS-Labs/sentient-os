# Sidekick (Notch Magic/): the notch window and visual

The living notch overlay: a Dynamic-Island-grade object that drops from the bezel glowing, listens or
lets you type, streams the work, and retracts back into the cutout. This doc is the window mechanics
(where most of the hard bugs were fought) and the visual. Read it before touching ANY of it; the
"lessons" section is a list of things that broke in the field and must not be re-broken.

## Files

| File | Job |
|---|---|
| `NotchWindowController.swift` | The `NSPanel` host: a fixed canvas flush at the bezel, click-through by cursor position, all-Spaces pinning, the hover affordance (the notch as a button), the local Esc monitor, display observers, and the per-interaction display anchor. Also `NotchPanel`, `NotchHostingView`, and the `NSScreen.notchSize` / `displayID` extension. |
| `NotchView.swift` | `NotchMetrics` (per-phase and hover sizing), `NotchView` (the thin binder over the coordinator), `NotchContent` (the pure, previewable visual: morph, shadow bed, layered glow, captions, the type field), `NotchStopButton`, the blur-dissolve transition. |
| `NotchShape.swift` | The silhouette (animatable corner radii) and `NotchSkirtShape`, its open twin the glow strokes (concave top corners + sides + rounded bottom, never the flat top edge). |
| `NotchSpace.swift` | A SkyLight private-API wrapper that pins the panel into a top-level window-server space so it never slides during the Spaces swipe. Best-effort; nil falls back to the public behavior. |
| `SpinningLogo.swift` | The 2D spectrum-ring logo (matches the app icon), 13 s idle / 2 s while running. Also the Constellation View's sun. |

Design language: OLED black as a material; the AI spectrum is `GlowHalo.stops` (the same stops the
website logo spins); serif italic only for the notch's read-back and notices; mono for the machine
whisper; motion is physics. Verify changes by building (the Xcode MCP `BuildProject`); `RenderPreview`
does not work on this target, and the notch is all motion on a physical bezel, so ask for a screen
recording.

## The window (`NotchWindowController`)

- **A fixed canvas, top-flush, never resized during a morph.** The panel is sized once to the biggest notch state plus slack (140 pt wide, 90 pt tall, for the bounce overshoot and the glow bloom) and pinned with its top at the screen edge; the notch shape animates INSIDE it. Per-state window resizing made the notch visibly detach from the bezel mid-morph; do not go back.
- **Click-through = `ignoresMouseEvents` toggled by CURSOR POSITION.** macOS catches a click on ANY non-transparent pixel (the glow) before `hitTest`, and a nil `hitTest` swallows rather than passes it through. So a cursor poll sets `ignoresMouseEvents = false` only while the cursor is over the actual notch SILHOUETTE (a `NotchShape` path test in screen coordinates); everywhere else the whole window ignores the mouse. The poll is two-tier by proximity (60 Hz inside the canvas, 10 Hz far away; the hover monitors bump it back the instant the cursor re-approaches). Interactive states: `.running`, `.typing`, and the idle hover.
- **All Spaces, no slide:** `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]` re-asserted on EVERY reveal (macOS drops `.canJoinAllSpaces` on re-order), plus `NotchSpace.shared?.pin(panel)` (`.stationary` covers Exposé only, not the swipe). Level `.mainMenu + 3`.
- **Typing needs a key window:** `.typing` reveals with `makeKeyAndOrderFront` (a non-activating panel becomes key without bringing the app forward). A `didResignKey` observer dismisses the field on click-away, including one that lands inside the 0.4 s focus-setup grace: a resign inside the grace schedules one re-check just past it (still typing and still not key → a real click-away → dismiss). Without that re-check a click-away mid-morph left an unclosable field.
- **Esc is LOCAL only:** `addLocalMonitorForEvents(.keyDown)` → `coordinator.cancelCurrent()`, swallowed when handled so dismissing the field never beeps. Over other apps a fresh hotkey press is the cancel.
- **The anchor display:** every interaction picks its screen at the front door (`CommandCoordinator.notchAnchor`): the hotkey and the home command bar → the MAIN (menu-bar) display; a hover or click on the physical notch → the BUILT-IN display's real cutout, so the notch stays a button when an external display is primary. `placeCanvas` re-derives the metrics when the overlay lands on a different display; the anchor is sticky through `.hidden` so the retract merges into the same bezel. The hover ENTRY rect is always keyed to the built-in notch screen.
- On `.hidden` the panel orders out only after the retract animation has played (`settleDelay` 0.6 s; the hover exit waits 1.0 s). Idle = no window at all. Observers for screen-parameter changes, Space changes, wake, and app activation re-place and re-reveal.
- `sharingType` is left at default: the notch shows in screen recordings (recordability was chosen; the computer-use agent may see it in its own screenshots).

## The notch as a button (hover + click)

Mouse over the IDLE notch → a trackpad haptic tick (`NSHapticFeedbackManager`, `.alignment`) and the
shell SWELLS (`hoverSize`: +22 pt wide, +3 pt deep; more depth reads as drooping) with a drop shadow and
deliberately no glow; a click opens the same tap-to-type field as a hotkey tap. Real-notch displays
only. Entry detection is zero-permission `.mouseMoved` NSEvent monitors (mouse monitors are not
keyboard-class) doing one cached rect test per move; the panel arrives invisibly (black shell at the
exact hardware silhouette, then springs to the grown shape); exit and click-through ride the cursor
poll with hysteresis (entry = the tight cutout, exit = the grown box + 4 pt); the enter/exit springs are
asymmetric (quick with a tiny overshoot in, slower and fully damped out, because a shrink's overshoot
lands inside the black cutout where a bounce reads as a hard cut). The swell is disabled while
onboarding is before the film's notch beat (a button must never tease a dead click).

## The visual (`NotchView`, `NotchMetrics`, `NotchShape`, `SpinningLogo`)

`NotchMetrics` derives every size from the display's real notch (`auxiliaryTopLeftArea`), or a
default pill on notch-less displays: base ≥ 200 × 32; opening / listening / transcribing = base + 76
wide, base + 2 tall (the reported height is a hair shallower than the real cutout, so the mic state
covers the lip); running / finishing = ≥ 360 wide, base + the caption row (18 pt for one status line,
two lines for a failure so the ✗ reason survives, or the measured read-back height up to 10 lines);
typing = wider plus one field row; hidden = the EXACT hardware cutout with the genuine radius
(`baseHeight / 3`), which is what makes the dismiss a physical retract that merges into the real notch
(on a notch-less display the shell fades instead). The read-back lingers 4 s (one line) to 9 s (ten),
scaled by line count.

`NotchContent` layers, bottom to top: the depth-bed drop shadow (an identical silhouette whose only
visible part is its shadow, so the spectrum reads against darkness rather than the wallpaper); three
glow passes (a wide soft halo, a dense halo, then over the fill a crisp bright rim: a rotating
`AngularGradient(GlowHalo.stops)` masked by a `NotchSkirtShape` stroke, so the glow warps into the
concave corners but never lights the bezel line, and morphs in lockstep with the fill because the mask
lives in the body, not inside the per-frame `TimelineView`); the black shell (tappable only as the
hover affordance); and the content: `SpinningLogo` on the left, a right control in the same 17 pt slot
(mic → spinner → return glyph → STOP → outcome glyph), and the caption row: the serif-italic
read-back in curly quotes, or the gradient "Remembering ‹note›" bloom while codex reads the knowledge
base, or the mono status line with glyph-level `contentTransition(.interpolate)`, swapped with a
blur-dissolve-pop. One spring (`response 0.52, damping 0.72`) drives size, radii, content, and glow
together; reduced motion → a 0.24 s ease. The edge glow is present in every visible state from the
moment the notch appears; each glow layer expands its gradient past the stroke + blur on every edge so
the bottom is not thinner than the sides.

`SpinningLogo`: a soft additive bloom, a thick sharp saturated color band (the visible color; ONE
additive pass, since stacking blows the pale stop to white), a fine white ring, and the white planet
dot. The palette is `GlowHalo.stops` with the pale warm-yellow seam stop deepened to gold so the tight
ring reads as a full rainbow rather than a near-white spot. Wall-clock spin via `TimelineView` with an
anchor that re-bases on speed changes, and `.transaction { $0.animation = nil }` so the notch's morph
spring can never interpolate the gradient angle and reverse-spin the logo.

## Lessons (please do not re-break these)

1. Click-through is `ignoresMouseEvents` by cursor position against the shape path, on a fixed canvas. Not a static `hitTest`, not a rect.
2. The window never resizes during a morph.
3. Re-assert `collectionBehavior` on every reveal; no-slide needs SkyLight.
4. The shape sits flush at the bezel and the glow strokes the skirt, so the bezel line never lights.
5. The glow morphs in lockstep via a `.mask` in the body, never a shape built inside the `TimelineView`.
6. Expand each glow gradient past the stroke + blur on every edge.
7. `SpinningLogo`: one additive color pass and `.transaction { animation = nil }`.
8. No `@State` writes per frame; wall-clock `TimelineView` only.
9. `RenderPreview` is broken on this target; build, then test motion live.
10. Off-main code (the audio tap) is `nonisolated` and captures locals, never `self`; the project uses default-MainActor isolation.
11. The dismiss is a retract into the cutout, not a fade.
12. Keyboard-class `CGEventTap`s are TCC-radioactive; Sidekick rides NSEvent monitors permanently, and only ever `flagsChanged` globally.
13. NSEvent monitors install after launch, never during app init.
14. **The screen's top edge must stay clickable.** A cursor slammed against the top reports EXACTLY the boundary coordinate, and three layers each treat the boundary as outside: `Path.contains` excludes boundary points (the silhouette test uses a point clamped 2 pt into the shape); SwiftUI shape hit-testing does too (the shell's tap gesture rides a `contentShape` inset by −4); `NSRect.contains` is half-open (every cursor rect touching the screen top overhangs it by +2). Fixing one or two is not enough.

## Related docs

`Notch Magic/Documentation - Sidekick - General.md`, `Views/Documentation - Views - Home, Processing & Shared UI.md` (`GlowHalo`, the design language), `Views/Knowledge/Documentation - Knowledge Window (Constellation & Reader).md` (the logo as the sun). The original inspiration was the open-source DynamicNotch app (its `notchSize` extension, fixed-canvas panel, corner-radius match, and SkyLight space delegation were the pieces used or adapted).
