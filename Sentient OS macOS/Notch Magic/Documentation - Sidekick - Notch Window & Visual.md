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
| `IslandLauncher.swift` | `NotchEntryHandle`: frosted 72 × 6 pt menu-bar handles on notchless displays and invisible native targets over hardware cutouts. Includes native press/hold, accessibility activation, and a cached wallpaper crop. |
| `NotchShape.swift` | The silhouette (animatable corner radii) and `NotchSkirtShape`, its open twin the glow strokes (concave top corners + sides + rounded bottom, never the flat top edge). |
| `NotchSpace.swift` | A SkyLight private-API wrapper that pins the panel into a top-level window-server space so it never slides during the Spaces swipe. Best-effort; nil falls back to the public behavior. |
| `SpinningLogo.swift` | Shared `WebsiteLogoMark`, ported from the active website header SVG. `SpinningLogo` animates its diffuse halo at 13 s idle / 2 s while running. Also the Constellation View's sun. |

Design language: a softly shaded hardware cutout within continuous dark underlit glass; the AI spectrum is `GlowHalo.stops` (the same stops the
website logo spins); plain system type for live and submitted speech; serif italic for notices; mono for the machine
whisper; motion is physics. Verify changes by building (the Xcode MCP `BuildProject`); `RenderPreview`
does not work on this target, and the notch is all motion on a physical bezel, so ask for a screen
recording.

## The window (`NotchWindowController`)

- **A fixed canvas, top-flush, never resized during a morph.** The panel is sized once to the biggest notch state plus slack (140 pt wide, 90 pt tall, for the bounce overshoot and the glow bloom) and pinned with its top at the screen edge; the notch shape animates INSIDE it. Per-state window resizing made the notch visibly detach from the bezel mid-morph; do not go back.
- **Click-through = `ignoresMouseEvents` toggled by CURSOR POSITION.** macOS catches a click on ANY non-transparent pixel (the glow) before `hitTest`, and a nil `hitTest` swallows rather than passes it through. So a cursor poll sets `ignoresMouseEvents = false` only while the cursor is over the actual notch SILHOUETTE (a `NotchShape` path test in screen coordinates); everywhere else the whole window ignores the mouse. The poll is two-tier by proximity (60 Hz inside the canvas, 10 Hz far away; the hover monitors bump it back the instant the cursor re-approaches). Interactive states: `.running`, `.typing`, and the idle hover.
- **All Spaces, no slide:** `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]` re-asserted on EVERY reveal (macOS drops `.canJoinAllSpaces` on re-order), plus `NotchSpace.shared?.pin(panel)` (`.stationary` covers Exposé only, not the swipe). Level `.mainMenu + 3`.
- **Typing needs a key window:** `.typing` reveals with `makeKeyAndOrderFront` on a non-activating panel. Outside mouse-downs dismiss directly, including during opening. Transient key loss during a display move is not dismissal; an explicit switch to another app dismisses pending input. Each entry activation also requests editor focus, and Home respects notch keyboard ownership.
- **Esc is LOCAL only:** `addLocalMonitorForEvents(.keyDown)` → `coordinator.cancelCurrent()`, swallowed when handled so dismissing the field never beeps. Over other apps a fresh hotkey press is the cancel.
- **The anchor display:** every interaction picks its screen at the front door (`CommandCoordinator.notchAnchor`): the hotkey and the home command bar → the MAIN (menu-bar) display; a hover or click on the physical notch → the BUILT-IN display's real cutout, so the notch stays a button when an external display is primary. `placeCanvas` re-derives the metrics when the overlay lands on a different display; the anchor is sticky through `.hidden` so the retract merges into the same bezel. Physical-notch entry remains keyed to the built-in screen. Each notchless display has its own idle handle; clicking or holding it anchors the interaction to that display ID. If the display disconnects, placement falls back to the main display.
- On `.hidden` the panel orders out only after the retract animation has played (`settleDelay` 0.56 s; the hover exit waits 1.0 s). Idle = no main canvas; every display retains its small native entry target (visually invisible over a hardware cutout). Other displays' handles stay available while a prompt/message/question is open. Handles are immediately available during retract, so quick re-entry does not wait for window order-out. Observers for screen-parameter changes, Space changes, wake, and app activation re-place and re-reveal.
- `sharingType` is left at default: the notch shows in screen recordings (recordability was chosen; the computer-use agent may see it in its own screenshots).

## The notch as a button (hover + click)

Mouse over the IDLE notch → a trackpad haptic tick (`NSHapticFeedbackManager`, `.alignment`) and the
shell SWELLS (`hoverSize`: +22 pt wide, +3 pt deep; more depth reads as drooping) with a drop shadow and
deliberately no glow; a click opens the same tap-to-type field as a hotkey tap. On notchless displays the persistent handle swells gently instead. Entry detection is zero-permission `.mouseMoved` NSEvent monitors (mouse monitors are not
keyboard-class) doing one cached rect test per move; the panel arrives invisibly (black shell at the
exact hardware silhouette, then springs to the grown shape); exit and click-through ride the cursor
poll with hysteresis (entry = the tight cutout, exit = the grown box + 4 pt); the enter/exit springs are
asymmetric (quick with a tiny overshoot in, slower and fully damped out, because a shrink's overshoot
lands inside the black cutout where a bounce reads as a hard cut). The swell is disabled while
onboarding is before the film's notch beat (a button must never tease a dead click).

## The visual (`NotchView`, `NotchMetrics`, `NotchShape`, `SpinningLogo`)

`NotchMetrics` derives sizes from the display's real notch, with a floating island on notchless
displays. One fixed canvas hosts the whole interaction. Fresh hold-to-talk, transcription finalization,
and starting/running Sidekick share the same activity width and header. Compact mode applies the
same compact footprint to all three. Submitted speech remains in the live transcript's horizontal
row, with identical typography and scroll position; it does not acquire quotes or resize the panel.

Voice owns a `DictationPresentation.Context`: activity, composer, or a captured response. Its
`layoutPhase(for:)` is the shared resolver for rendering and pointer geometry. Starting voice from
the prompt keeps the prompt's size; starting from a response keeps that response and its measured
size. The display metrics carry no copied voice/reply flag. The renderer reads the captured reply
for both its content and its geometry, so an attention update cannot replace it with a maximum-size
empty reader. One morph transaction drives the shell, border and contents. Hidden retracts to the
hardware cutout or the external display's small handle.

Lighting also follows the resolved layout phase. Recording into a response keeps the response's
material clock, ambient clock and light strength; it does not brighten or restart the gradients.
Expanded surfaces use the always-active AppKit blur with a fixed dark tint and spectrum instead
of the system glass lens, which changes tint with keyboard focus even with explicit appearance
overrides. Compact external activity keeps native Liquid Glass without the extra blur.
The typed prompt and the reply field share `notchComposerGlass`: a thin pane with a top-lit fill
and a 0.5 pt hairline, brighter on its top edge, on every surface including the hardware notch. The
prompt's placeholder uses the field's own face and size, so typing never shifts it. The reply field
keeps the same chrome while recording.

The prompt's lifecycle is one continuous object. The placeholder leaves on the first keystroke itself
(never under the first character) while the mic springs away and Send lights; clearing the field
brings it back on the same spring. A long draft wraps, and the notch grows a line at a time on the
morph spring up to `maxDraftLines`, then scrolls inside the field. Rows are one text line tall, so
the text block keeps an equal inset above and below at any length. `promptLineCount` feeds
`size(for:draftLines:)` from the view, the click-through test and the fixed canvas alike, so the
silhouette, hit target and canvas always agree. Sending clears the field and chips in 0.1 s, before
the read-back fades in, so the words are never on screen twice. Typed text, live speech and the
read-back share one 13 pt regular face, and an overflowing read-back fades in at its leading edge
instead of cutting a glyph.
Inline transcription retains keyboard ownership through finalization so it never orders the
panel out and back in. Stopping dictation returns to the same response with an editable draft.

`NotchContent` layers the lower glass material, the localized, feathered black hardware-cutout cover, the dark Underlight surface and its masked color field, and the controls. On notchless
displays there is no camera cover. The glass, fill, and light all follow the same silhouette;
shape masks remain outside `TimelineView` so size and corner morphs stay synchronized.
`SpinningLogo` sits on the left; the right control keeps its 17 pt slot across mic, spinner,
return, stop and outcome states. Submitted speech keeps the live transcript view; status uses mono with a
blur-dissolve transition. One spring (`response 0.52, damping 0.72`) drives phase geometry;
Reduce Motion substitutes a 0.24 s ease. The lower bloom reserves space outside its mask
so the soft light never gets clipped into a rectangular edge.

At task start, `CommandRunModel` selects one of thirty `SidekickStartupCopy` phrases, excluding the
previous choice. That caption stays fixed through preparation and provider startup, then yields to
real progress. While `isStarting` is true, the physical notch adds a small moving blue/pink/peach
underlight along its bottom edge. The persistent masked layer fades in over 0.7 s and out over 0.35 s
when work progresses or a response expands. It never blurs the desktop. Its 30 fps timeline pauses
when hidden, and Reduce Motion/Low Power uses a static field. The external island retains its
existing colored glass treatment.

`WebsiteLogoMark` is the native port of the active website's
`src/components/reusable/LogoMark.jsx`: the exact sRGB linear-gradient stops, a filled color disc
with Gaussian blur at 24% of its diameter, the subtle larger white wash, one white outer outline
at 5%, and a white center dot at 40%. There is no sharp colored band and no extra inset white line.
Every layer has an explicit size so the larger halo cannot stretch the outline. `OrbMark` uses the
same static renderer; the menu-bar template remains monochrome. `SpinningLogo` rotates only the
halo with its existing 13 s idle / 2 s working cycle, anchored across speed and pause changes, and
uses `.transaction { $0.animation = nil }` to keep parent morph animations out of the rotation.

The logo comparison mode in `preview_island_colors.py --logo-reference <PNG>` compares an SVG
render from the website with the actual native mark at 120, 40, 24 and 17 pt, plus the live notch view.

## Lessons (please do not re-break these)

1. Click-through is `ignoresMouseEvents` by cursor position against the shape path, on a fixed canvas. Not a static `hitTest`, not a rect.
2. The window never resizes during a morph.
3. Re-assert `collectionBehavior` on every reveal; no-slide needs SkyLight.
4. On physical-notch displays the shape sits flush at the bezel and the hardware cutout remains black. On notchless displays the island floats 9 pt below the bezel. Underlight stays concentrated near the lower edge.
5. The glow morphs in lockstep via a `.mask` in the body, never a shape built inside the `TimelineView`.
6. Expand each glow gradient past the stroke + blur on every edge.
7. `SpinningLogo`: match the website SVG ratios, explicitly size every layer, and keep `.transaction { animation = nil }` on the rotation.
8. No `@State` writes per frame; wall-clock `TimelineView` only.
9. `RenderPreview` is broken on this target; build, then test motion live.
10. Off-main code (the audio tap) is `nonisolated` and captures locals, never `self`; the project uses default-MainActor isolation.
11. The dismiss is a retract into the cutout, not a fade.
12. Keyboard-class `CGEventTap`s are TCC-radioactive; Sidekick rides NSEvent monitors permanently, and only ever `flagsChanged` globally.
13. NSEvent monitors install after launch, never during app init.
14. **The screen's top edge must stay clickable.** A cursor slammed against the top reports EXACTLY the boundary coordinate, and three layers each treat the boundary as outside: `Path.contains` excludes boundary points (the silhouette test uses a point clamped 2 pt into the shape); SwiftUI shape hit-testing does too (the shell's tap gesture rides a `contentShape` inset by −4); `NSRect.contains` is half-open (every cursor rect touching the screen top overhangs it by +2). Fixing one or two is not enough.

## Quick actions

The typing layout includes a 20-point row 10 points beneath the prompt, with content-sized
Summarize and Proofread chips aligned to the field's leading edge, and 12 points below them. Their low-contrast
capsule borders brighten on hover; there are no full-width dividers or split action panels.
Each chip shows its global shortcut, `⌘,` or `⌘.`, set like a menu key equivalent, with an accessibility hint and conflict help. Its size
participates in the same silhouette measurements, fixed-canvas sizing and cursor hit testing as the
rest of the notch. The physical collapsed notch does not gain a permanent extra row.

Selection capture temporarily prevents key-window transfer and text-field focus. If the user moves
on during capture, the pending typing presentation is dismissed. Proofread uses a non-key notice
with a working mark and Stop control while the original editor keeps focus. Its notice is explicitly
interactive for that control. Summary and corrected-copy readers use `Views/ReadingPanel.swift`;
the window owns its size, and its hosting view does not resize it to the text document's height.

## Related docs

`Notch Magic/Documentation - Sidekick - General.md`, `Views/Documentation - Views - Home, Processing & Shared UI.md` (`GlowHalo`, the design language), `Views/Knowledge/Documentation - Knowledge Window (Constellation & Reader).md` (the logo as the sun). The original inspiration was the open-source DynamicNotch app (its `notchSize` extension, fixed-canvas panel, corner-radius match, and SkyLight space delegation were the pieces used or adapted).

## Provider-plan recovery actions

An evidence-backed ChatGPT Free/Go limit can add `SidekickUpgradeActions` to the existing recovery
panel. Home's composer uses the same component. Its explanation and compact button row are included in
`SidekickRecoveryLayout` measurement, leaving the guidance field fixed while overflowing content
scrolls. Upgrade opens pricing only on click; Change AI opens provider settings. Try again and Stop
remain available. This recovery stays pending while hidden, preserving the guidance during an
external visit; generic failure timing and clarification behavior keep their existing rules.

## External displays and notchless Macs

There are three geometry modes: bezel-attached notch, floating external island, and hardware
island. The hardware island uses the floating island silhouette, corner-concentric controls and
materials, but retains a camera reservation between its header wings and puts body text below
that band. Hardware-island compact wings have equal widths, centering both the bar and its
camera gap; the original notch retains its asymmetric wings. No synthetic
resting handle is drawn over a real cutout; the existing invisible hardware entry target is used.

On macOS 27+, a built-in Multi-Touch display with an auxiliary camera exclusion area selects the
hardware-island mode. Its reserved width comes from `NSScreen` auxiliary areas; its header is
centered horizontally on the display and vertically in the menu bar. Menu-bar height comes from
the top `frame`/`visibleFrame` gap, with safe insets and auxiliary areas preserving the protected
band when the menu bar is hidden. Header height leaves equal upper/lower padding, and hover grows
around that same centerline. Expanded text starts below the menu bar. External touch displays and
existing notched MacBooks retain their respective modes, including the external pill's 9 pt inset.
Exact optical fit still needs on-device validation. Previews use an explicitly illustrative cutout,
not published Apple dimensions.

Each attached display without a hardware cutout gets a slim menu-bar handle, subject to the existing
notch-click preference and onboarding availability. Click opens typing; a 250 ms hold enters the
existing voice lifecycle and releasing near the press sends. Releasing more than 48 pt away stops
into an editable draft. The same recognizer retains a held press through view replacement and
pointer drift. Accessibility activation opens typing directly.

The handle has a fixed, locally sampled wallpaper crop, blurred once when the display configuration
is built, plus a translucent tint and fine highlight. It does not capture screen contents, request
recording permission, run a live material, or animate at idle. A missing wallpaper falls back to the
tint. Reduce Transparency uses a solid surface; Reduce Motion retains the existing gentle transitions.
The sampled backdrop stays fixed until a display reconfiguration (including a resolution change).

The main canvas keeps its fixed size through all morphs. Rounded island geometry and the 9 pt top
inset are shared by rendering and hit testing; the gap above, rounded corners, and glow pass clicks
through. The hover handle retains a forgiving target around its thin visible surface. Display changes
rebuild the tiny launcher panels, and teardown releases both launchers and the main canvas.

Verification: `test_compact_notch.py` exercises both hardware and island hit testing;
`test_dictation_gesture.py` checks press/release behavior. `test_dictation_ui.py --app <Debug app>`
renders the resting, hover, typing, listening and compact variants and exercises actual external
panel activation, anchored placement, retract/reopen, preference gating and teardown in isolated
fixture defaults without recording audio or making provider calls.

### Display materials and lighting

External displays use Underlight (D): dark glass with soft color in the lower surface and a diffuse
bloom below. The physical notch uses a refined version of the original line glow: a 1.4 pt core,
a soft surrounding bloom, and a slower 12-second blue/violet/rose/amber cycle. Its open skirt path
never draws across the flat bezel edge. Working light is restrained; attention and completion still
receive a brief stronger arrival.

On hardware-notch displays, prompt entry, messages and questions use continuous dark glass with
subtle lower color. One full-width black crown covers the camera band through the hardware height
plus its small cover margin, then fades smoothly over up to 48 pt. It is drawn over continuous dark
glass, not composited from inverse material masks, avoiding a bright horizontal seam. There is no
localized camera patch to call out the physical cutout. Smaller status and voice views stay fully
black with the same line glow. Hidden and hover states retain their existing black retract/swell.
The geometry, camera clearance, and pointer hit regions remain unchanged.

Notchless displays retain their floating glass shape and cached tiny resting handle. On macOS 26+,
external running states use native Liquid Glass without the additional backdrop blur. Input,
reading and other expanded external states retain a behind-window `NSVisualEffectView` with an
explicitly active HUD material, so focus changes cannot remove their blur. The physical notch's
lower glass always retains that blur. On older macOS versions it supplies the material fallback.
Reduce Transparency provides a fully opaque base; Reduce Motion and Low Power Mode stop the
color clock. Reading/question states also pause it; typing, voice and working states animate.
The 12-second color cycle pauses and resumes without resetting its color position.

The spectrum is drawn above the glass sampling layer so the glass never refracts the whole halo
into a rainbow fill. The external bloom extends below its shape; the physical notch's black crown hides the camera
without exposing a separate cutout outline. The fixed panel canvas still never resizes during
morphs, and glow pixels outside the interactive silhouette still pass clicks through.

The dictation UI lab captures notched typing, dictation, compact work, and external states, including
focused/unfocused glass over a synthetic detailed background. `preview_island_colors.py --app
<Debug app> --selected-design` renders a side-by-side native/external showcase and a complete color
cycle using the production default. Without that flag it retains the B/C/D design comparison;
alternative treatments are preview overrides, not user-facing settings.

Normal work uses a faint underlight. New messages, questions, setup prompts, notices and completion
states receive one brighter arrival, held for 650 ms and eased back over 650 ms. Re-rendering the same
content does not replay it. Leaving that event resets the arrival identity for a later completion;
Reduce Motion and Low Power Mode skip the flare. Fill opacity and text brightness are unaffected.

### Keep hardware-notch motion on the original shape path

The physical notch's black fill and its three line-glow shapes stay mounted through hidden,
hover, opening and retracting states. Their existing spring animates geometry; glow presence
uses opacity. Never conditionally insert those shapes on reveal or replace the black fill with
a live material during the spring.

The optional hardware glass and color surface appear only after the geometry has settled
(900 ms of black, then a gentle 1.6 s ease-in/out opacity fade). A key containing phase, display metrics, message and
question identity invalidates them immediately when geometry changes. Cancelling or closing
an opening cancels its delayed material work, and a later reopening gets its own settle.
External-island materials are unchanged. `preview_island_colors.py --motion --app <Debug app>`
checks actual hidden/open/close/interrupted-open transitions, live-material lifetime and fixed
canvas geometry; still screenshots alone are insufficient to validate these animations.

The hardware glass, color tint and black crown are grouped into one composited decoration before
fading in. Separate fades caused a pale flash, and inserting the crown during expansion produced
a black rectangle outside the animated outline. Removal is immediate (no outgoing material
transition) so closing also runs on the black shape. The motion fixture records two actual open /
close cycles with ScreenCaptureKit, restricted to its owned window and without audio.

### Outside-click dismissal and retract

Both local and global mouse-down monitors route to the same silhouette-aware outside-click handler.
An on-display click outside the expanded prompt, message or question dismisses it synchronously;
it does not wait for key-window resignation or its setup grace. The click is still delivered to
its destination. Off-display automation probes and app-modal dialogs are excluded. A held voice
gesture retains release-to-send, and ordinary app clicks never stop an active Sidekick task.

Application activation can reassert panel visibility, but never makes it key again. Typing focus
uses a cancellation-aware task keyed to phase/readiness, so a queued focus request cannot revive a
prompt after click-away. Transient key resignation is no longer treated as dismissal; actual other-app activation handles keyboard app switches.

The opening keeps its original spring. Dismissal uses a bounded 500 ms ease-in/out curve with no
overshoot, followed by window order-out at 560 ms; the retract therefore finishes before its canvas
is removed. The native motion fixture verifies first-click dismissal during opening, dismissal of
an already non-key prompt, no focus reclamation on app activation, and eventual panel order-out.
`test_notch_click_away.py` covers production routing across input, question, message and work states.

### Fixed hosting and cross-display handoff

`NotchHostingView` and the idle handle's SwiftUI host explicitly disable `sizingOptions` and automatic
safe-area regions. The AppKit controller alone owns their fixed frames. The hosting root is replaced
only when display metrics or the backdrop actually change; coordinator observation handles ordinary
phase/content updates. This prevents content animation from competing with window geometry updates.
The observed freeze had a main thread blocked on SwiftUI's update lock after an off-main NSWindow
geometry exception terminated a rendering thread; its original process sample was saved during diagnosis.

Entry handles stay available on other displays while typing, reading a response, or answering a question.
Activating another handle updates the anchor and a focus request, moving the same composer/reader with
its draft intact. Entry presses are exempt from outside-click dismissal. The invisible hardware-notch
handle is a plain native view and does not create a second SwiftUI overlay. Voice holds can also begin
from an existing typing surface, using the same release-to-send recognizer.

`test_notch_surface_switching.py` runs the real Home view alongside the production controller in isolated
state, alternates native press/release and accessibility activation across every attached display, and
checks draft/host preservation, other entry visibility, fixed hosting options, stale-retract suppression,
and a return to Home. It saves a process sample if the owned fixture times out. No provider or microphone
is used.

A transfer explicitly refreshes the notch editor's focus request. Home's reply-reference observer uses
its guarded focus helper too, so a quote/reply initiated in the notch cannot focus the retained Home
editor. This keeps focus ownership consistent across typing, replying, window activation and display
handoff rather than relying on a delayed key-loss dismissal timer.

### Pill-to-island continuity

The external island now also keeps its base silhouette and color surface mounted through hidden,
hover, open and retract states. Their size, corner radius and opacity share the existing morph.
Live glass is attached after a 600 ms geometry settle and fades in over 350 ms, with immediate
removal on close; it no longer replaces the shell during expansion. Automatic window sizing
remains disabled. `preview_island_colors.py --island-motion --app <Debug app>` records the actual
pill/open/retract cycle and checks interruption, material lifetime and focus behavior.

Cross-display hover first orders the old canvas out, installs the destination frame and metrics
with animations disabled, and resets only the inner presentation identity by display ID. The
shared host, coordinator and draft stay intact. Hover is published after placement, so the previous
display's retract, horizontal offset and corner animation cannot travel onto the new screen. Hover
entry uses a more damped spring to avoid the thin external pill oscillating. The switching fixture
also exercises defocus followed immediately by opposite-display hover and captures arrival/settle.

Response previews omit the redundant author heading and begin directly with the message below the
camera/control row. Their measurement removes the heading and its gap, and lowers the minimum
panel height accordingly. The notch line glow is an overlay on the shell rather than a separately
sized sibling stack, so both receive the same interpolated bounds during typing/running transitions.
The motion fixture includes typing → running → typing, in addition to open/retract cycles.

The shell owns its own shadow and line-glow overlay. A separate filled shadow-bed shape is no
longer drawn: its independent layout could visibly trail the main silhouette when shrinking from
typing to work. The sole shell frame now drives both fill/shadow and the border overlay.

The response's “Open in Sentient” control is a labeled top-right button replacing the small history
icon. Its former footer row is removed; selection reset and task stop remain beside the reply field.
Message measurement therefore reserves only the reading/reply gap, not a footer or footer gap.

The entire shell/material group is clipped to the same animated silhouette as its line overlay.
Native backdrop dismantling explicitly hides the view and removes its layer animations, and material
removal disables inherited animation transactions. This prevents a retained native effect or snapshot
from painting the previous expanded rectangle beneath a shrinking outline.

External-pill hover is handled locally by the already-visible native entry view. A short 140 ms
Core Animation transform grows its cached surface from 72 × 6 to 84 × 9, anchored at top-center;
exit eases back in 180 ms. Mouse entry does not place/reveal the main canvas or start a SwiftUI
render. The full canvas is prepared only on click/hold. The slightly larger transparent panel
reserves animation room, with input confined to the central 84 × 18 hit target. Reduced Motion
applies the feedback without motion. Hardware-notch hover retains its existing overlay behavior.

### Voice follow-ups from a response

The central camera/header area remains a press-and-hold target while a response or prompt is open;
header controls remain outside that target. The response reply field also has the same native mic
button as prompt entry: click latches recording, hold uses release-to-send. A voice follow-up retains
the exact response reference and shows its live transcript/waveform in the existing reading-sized
surface. It still respects the one-task-at-a-time and pending-question gates.

Transcription finalization remains an internal lifecycle state, but renders the same transcript and
waveform at the same size. It does not show a separate “Finishing transcription” panel. Audio stops
synchronously on release, finalization stays bounded and cancellable, and failures preserve speech
in the draft. The dictation lifecycle and UI labs cover response context and the unchanged release layout.

Voice follow-ups keep the response renderer mounted, including its scroll position and header.
The reply field, rather than the message body, becomes the live voice composer. Its right-side mic
changes to Stop, and Send can finalize/submit. Home and response fields show a left-aligned audio
waveform until the first nonempty transcript, then crossfade to the words. The response material
identity stays stable across listening/finalizing so dictation cannot collapse or re-open the panel.


### Voice continuity verification

`Scripts/test_voice_continuity_ui.py` runs the real SwiftUI surfaces in an isolated signed-app fixture.
It records a movie and observes rendered geometry for voice-to-work, composer voice, repeated response
voice and compact-mode handoffs on both notch and island layouts. Display metrics remain unchanged
during the response test, and the original message is cleared while its captured reply stays visible.
A deliberate resize is the negative control for the geometry observer. The movie also captures live
text through submission and the thinking underlight building, moving and fading. No microphone or provider is used.

### External island spacing

Floating activity and voice states share one 48 pt row rather than a camera band plus caption.
The 24 pt logo and primary control sit 12 pt from the ends; their centers coincide with the
24 pt corner centers. Expanded panels retain those header coordinates. Prompt, reply and
question fields are inset consistently, with corner radii derived from the outer radius minus
the inset. The compact island keeps its 34 pt height and 17 pt controls, with matching 8.5 pt
end insets. Hardware-notch dimensions and layout remain separate.

`Scripts/preview_island_colors.py --layout-refinement --app <Debug.app>` captures the actual
working, listening, prompt, response, compact and question states. Voice continuity, pointer
routing and click-away tests cover the shared geometry during transitions.
