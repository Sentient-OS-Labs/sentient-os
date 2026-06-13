# The Constellation Home (UI)

The app's home screen (Arch §9; design bar: `UI_Inspiration/01` + its HTML motion mockup).
Three files, three jobs:

## `Views/Orb.swift` — the living orb (design-system primitive)

The logo made dimensional: a dark glassy planet with the logo's white dot glowing as a
*heart* inside it, wrapped in a tilted ring of orbiting light. Pure SwiftUI — no Metal
files, no SceneKit.

- **True 3D occlusion:** the ring is drawn by TWO Canvases sandwiching the planet — one
  draws only the far half (`depth < 0`), one only the near half — so it genuinely passes
  behind and in front.
- **Physics, not UI:** ~230 seeded particles in two bands (with a Cassini-style gap) on
  **Keplerian** orbits (inner faster, `ω ∝ r^-1.5`); two shimmer glints chase around the
  band in opposite directions; the planet casts a shadow on the far side of the ring; the
  whole plane wobbles on slow precession cycles (23s/29s); 5.5s breathing.
- **Color geography is anchored to angle** (the sentient spectrum at deep-space brightness)
  — colors stay put while matter flows through them.
- **Modes:** `.idle` / `.processing` (fast + bright) / `.attention` (quiet amber). The
  processing/attention hooks are ready for the home ⟷ processing morph (a later phase).
- **Performance rules (learned the 8-fps way; the file header repeats them):** no @State
  writes per frame (the ring clock is a pure function of wall time) · no per-frame blur
  filters (halo = pre-rasterized texture that only rotates; nebula/heart = radial gradients)
  · one Canvas glow pass per side · the planet's diameter is FIXED (vector-crisp — breathing
  lives in the heart/halo/ring, never a whole-orb scaleEffect).
- `OrbMark` = the tiny static header glyph.

## `Views/ConstellationHome.swift` — the home screen

Orb dead-center; serif-italic status ("All caught up." / "Ready to begin."); mono-caps
whisper (real `LifetimeStats.analyzed`); compact **Analyze Now** on the shared `GlowHalo`;
four satellite cards pinned at the corners (±1.4–2° rotations — pinned, not gridded), each a
door-with-preview; dotted tether lines drawn from **real geometry** (`anchorPreference` →
Canvas) so they survive any window size; trust footer; `DEV TOOLS` bottom-right.

- **Real data:** things-understood count, vault note/domain counts (walks
  `VaultGenerator.vaultRoot` on appear), source chips (live from the dev picker's prefs),
  Copy MCP Link (real `MirrorClient.shared.shareURL` when the mirror is on).
- **Showcase data:** everything hard-coded lives in the file-private `Demo` enum and ONLY
  there (briefing card, Your AIs numbers, synced time, pending count, "last night" foot) —
  wiring real data later is a search for `Demo.`.
- Vault card opens the existing knowledge window; the briefing card's door opens the
  briefings window when that phase lands.

## `Views/DevToolsView.swift` — the dev cockpit (sheet)

The pre-Constellation home, moved verbatim behind the DEV TOOLS button: Start Analysis,
View knowledge, source picker + chat pickers, Reset store, Update Knowledge Base, FDA
tools, VaultView. The Phase-6 "Release strip" re-hides it.

- **`SourceSelection`** (top of the file) is the one shared reader of the `dbg.run.*`
  prefs, so RootView's *Analyze Now* and the sheet's *Start Analysis* run exactly the same
  selection. Its defaults must mirror the `@AppStorage` declarations (folders ON, DB
  sources OFF). The `@AppStorage` copies inside `DevToolsView` exist for SwiftUI
  reactivity; `SourceSelection` exists for everyone else.

## `Views/RootView.swift` — the switchboard

Constellation (idle) ⟷ ProcessingView (takeover), today a cross-fade — the cohesive
"cards recede, orb rises, processing assembles" morph is its own upcoming phase, along with
the briefings window and the vault viewer (in that order).
