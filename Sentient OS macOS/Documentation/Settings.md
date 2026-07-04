# Settings — the two-pane window

The real Settings (shipped 2026-07-04, PR #107): a modern two-pane window in the OLED-editorial
design language. Sidebar of five sections on the left (plus the About footer: version, GitHub,
report-an-issue), the selected pane on the right, the trust ribbon riding the foot. Opened from the
home's top-bar gear (`windowID "settings"`, 940×660 default).

Everything lives in `Views/Settings/`: the shell (`SettingsView.swift`), one file per pane, and the
shared pieces (`SettingsComponents.swift`).

## The design philosophy: form encodes content

No uniform card rows. Each kind of content wears its natural form:
- **Prose** for stories (the overnight explainer, the privacy pledge) — naked editorial text, no box.
- **Hairline toggle lines** for switches — title + quiet subtitle + a green switch, separated by hairlines.
- **Chips** for sources — capsule pills that light green (wash + ring + dot) when selected; counts
  ride inline ("12 chats"). Action chips (`isAction`, e.g. "+ Add Folder") wear a dashed border and
  no dot: an invitation, not a source.
- **Status LEDs** for health — glowing verdict dots (green/amber/red, bright core + double bloom)
  with mono-caps states and a "Fix…" pill only when something needs one.
- **Bordered surfaces only for real input** — the multiline text boxes and the secret-link capsule.
- Bold serif-italic pane titles ("System."), mono-caps group labels, a 640pt editorial measure.

Shared components: `SettingsPane` (scaffold) · `SettingsGroup` · `SettingsProse` ·
`SettingToggleLine` · `SettingsPillButton` · `ChipFlow` (a wrapping `Layout`) · `SettingsChip` ·
`StatusLine` · `SettingsTextBox` · `SettingsHairline`.

## The five panes

### Knowledge Sources (`SourcesPane.swift`)
The real source picker, on the SAME keys as Analyze Now / Dev Tools / the 3am run
(`SourceSelection`, `Sources/SourceSelection.swift`). Three groups: **Folders** (Desktop/Downloads/
Documents toggles + persistent custom roots + Add Folder), **Chats & Notes** (WhatsApp — hidden
when not installed — and iMessage open the shared `ChatPicker`; Apple Notes toggles), **Through
Your ChatGPT** (Gmail / Calendar open their connect sheets). A fix-it `StatusLine` appears when
Full Disk Access is missing. The **three-connector minimum** guards direct toggles on the 3→2 drop
only (all folders together count as ONE connector; a pre-onboarding state below three is never
trapped); a violation flashes the bottom whisper amber.

**`CustomRoots`** (in `Sources/SourceSelection.swift`) is the persistent store for user-added
folders — one newline-joined UserDefaults string (`files.customRoots`) so views react via plain
`@AppStorage`. This replaced the old session-only `@State customRoots`; the overnight run now sees
custom folders (the old §9 caveat is dead). Verified by a headless selftest (7/7) on ship day.

### Proactive & Sidekick (`ProactivePane.swift`)
Autosaving standing instructions for the proactive suggestion writer + Sidekick's shortcut key and
standing context. Keys: `proactive.instructions` · `sidekick.hotkey` ("rightCommand" /
"rightOption") · `sidekick.context`. ⚠️ Stored but not yet consumed — the prompts pick them up with
the prompt-refinement work, and Right ⌥ additionally awaits `RightCommandMonitor` support.

### Your AIs (`YourAIsPane.swift`)
`MirrorClient` end-to-end: the share toggle (OFF = confirm dialog → `disable()`, which deletes the
cloud copy but keeps the token), the masked secret link (Copy + **Regenerate** →
`regenerateToken()`), live `stats()` activity, connect-guide links, and the local-only story when
sharing is off. ⚠️ The maskedURL must search "/mcp" BACKWARDS — the host `https://mcp.sentient-os.ai`
itself contains "/mcp", and a forward hit inverts the range (a shipped-then-fixed crash).

### System (`SystemPane.swift`)
The overnight-intelligence story (prose — 3 AM is our taste, not a dial), launch-at-login
(`LoginItem`) with a keep-Sentient-alive confirm on the way off, and the privacy pledge with the
two split consents: crash reports (`diagnosticsEnabled` → Sentry) and analytics
(`analyticsEnabled` → TelemetryDeck), each calling its own `applyEnabledChange()`. The Sparkle
auto-update group (with its own keep-it-on message) lands here when Sparkle ships.

### Permissions & Health (`HealthPane.swift`)
The health board: live status LEDs for Full Disk Access (grant deep-link + relaunch link),
Notifications (requests when never-asked; deep-links when denied), launch-at-login, and the Codex
stack via `CodexSetup.shared` (installed / logged in / computer use — every fix opens the shared
`CodexSetupView`). Statuses re-probe on every app foreground. All-green flips the pane whisper to
"All clear." The **Danger Zone** holds Reset: an honest confirm, then `FactoryReset.run()`.

**`FactoryReset`** (`Ingestion/FactoryReset.swift`) is the ONE full wipe — cycle store, knowledge
base folder, proactive traces, lifetime counters — shared by this pane and Dev Tools' "Reset
everything" so the destructive sequences can never drift. Deliberately NOT touched: the cloud
mirror (the next push whole-replaces it; the 30-day lease is the backstop), the mirror token, and
the source selections. Post-reset the user lands on the empty home today; routing to onboarding
arrives with onboarding itself.

## Copy rules learned here

No em dashes in user-facing settings copy (reads as AI slop — use commas/semicolons/colons/breaks).
Guilt-trip confirms on the toggles that keep Sentient alive (launch-at-login; auto-update later).
One green everywhere: `Theme.Ink.green` (#4ade80) — selection chips, switches, status dots, and
every formerly-mint accent in the app.
