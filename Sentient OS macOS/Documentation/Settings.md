# Settings — the two-pane window

The real Settings (shipped 2026-07-04, PRs #107 + #109): a modern two-pane window in the
OLED-editorial design language. Sidebar of five sections on the left (plus the About footer:
version, GitHub, report-an-issue), the selected pane on the right, the trust ribbon riding the
foot. Opened from the home's top-bar gear (`windowID "settings"`, 940×660 default). Everything
lives in `Views/Settings/`: the shell (`SettingsView.swift`), one file per pane, and the shared
pieces (`SettingsComponents.swift`).

## ⚠️ NOT wired up yet (read this first)

1. **Proactive instructions + Sidekick context/hotkey** (`ProactivePane`) — the controls work and
   persist (`proactive.instructions` · `sidekick.context` · `sidekick.hotkey`), but **nothing
   consumes the values yet**. The proactive/Sidekick prompts learn to read them with the
   prompt-refinement work, and the Right ⌥ choice additionally needs `RightCommandMonitor`
   support (it listens for right-⌘ only today).
2. **The E2E encryption claim front-runs the code** — the Connect-AIs privacy blurb says the cloud
   copy is end-to-end encrypted and unreadable even by Sentient's devs. That is LAUNCH truth,
   decided 2026-07-04: the mirror stores plaintext markdown today, and the "mcp encryption"
   backlog item (Aditya) MUST ship before launch or the copy must change. Do not soften the copy;
   ship the encryption.
3. **The morning notification** — the Notifications permission row is real, but nothing in the app
   *sends* notifications yet (`Notify.now()` has zero call sites). The "Proactive Intelligence is
   ready" morning note ships with the reminders/scheduler work; the permission ask then moves to
   onboarding's notifications step.
4. **The Updates group** (System pane) — doesn't exist until Sparkle lands; it brings its own
   keep-it-on message.
5. **Privacy toggles transmit only in RELEASE builds** — by design (Sentry/TelemetryDeck never
   boot in DEBUG), so a Debug QA can verify persistence but not transmission.
6. **Small known holes, accepted for now:** removing the LAST custom folder can bypass the
   four-selection minimum (the guard covers chip toggle-offs only) · the reset-vs-run race has
   only the UI guard (see Reset below; the Layer-2 generation counter is deferred hardening) ·
   three Settings deep-link anchors (Speech Recognition, Accessibility, Screen Recording) are
   standard but unverified on Tahoe specifically.

## The design philosophy: form encodes content

No uniform card rows. Each kind of content wears its natural form:
- **Prose** for stories (the overnight explainer, the privacy pledge); no boxes.
- **Hairline toggle lines** for switches: title + quiet subtitle + a green switch.
- **Chips** for sources: capsule pills that light green (wash + ring + dot) when selected; counts
  ride inline ("12 chats"). Action chips (`isAction`, e.g. "+ Add Folder") wear a dashed border
  and no dot: an invitation, not a source.
- **Status LEDs** for health: glowing verdict dots (`HealthDot` — bright core + double bloom),
  mono-caps states, a pill fix button only when something needs one.
- **Bordered surfaces only for real input**: the text boxes and the secret-link capsule.
- Pane titles in the SF display voice ("System" — `.display(27)`, no trailing period) over a
  quiet plain-sans whisper, mono-caps group labels, a 640pt editorial measure, and one green
  everywhere (`Theme.Ink.green`, #4ade80). *(The old serif-italic titles/whispers were retired
  June 2026 — serif-italic display is a vibe-coded-AI tell.)*

Shared components (`SettingsComponents.swift`): `SettingsPane` · `SettingsGroup` · `SettingsProse`
· `SettingToggleLine` · `SettingsPillButton` · `ChipFlow` (a wrapping `Layout`) · `SettingsChip` ·
`HealthDot` · `StatusLine` · `InfoTip`/`TipWarmth` · `SettingsTextBox` · `SettingsHairline`.

## The five panes

### Knowledge Sources (`SourcesPane.swift`)
The real source picker, on the SAME keys as Analyze Now / Dev Tools / the 3am run
(`SourceSelection`, `Sources/SourceSelection.swift`). Three groups: **Folders**
(Desktop/Downloads/Documents toggles + persistent custom roots + Add Folder), **Chats & Notes**
(WhatsApp — hidden when not installed — and iMessage open the shared `ChatPicker`; Apple Notes
toggles), **Through Your ChatGPT** (Gmail / Calendar open their real connect sheets; note:
connecting ARMS the source — the initial read happens on the next run, same as connecting from
the Home popover. In knowledge-base-only mode these two chips render LOCKED — dim + lock glyph +
the instant `LockedChipTip` hover "Only supported on ChatGPT Plus"). A fix-it `StatusLine`
appears when Full Disk Access is missing. The **four-selection minimum**
(`SourceSelection.selectionCount` / `minimumSelections` — every folder, chat source, Notes, and
connector counts as ONE; the same rule onboarding's ready screen enforces, so the two surfaces
can never drift) guards chip toggle-offs on the 4→3 drop only (a pre-onboarding state below four
is never trapped); violations flash the bottom whisper amber.

**`CustomRoots`** (in `Sources/SourceSelection.swift`) is the persistent store for user-added
folders: one newline-joined UserDefaults string (`files.customRoots`) so views react via plain
`@AppStorage`. This replaced the old session-only `@State customRoots`; the overnight run now
sees custom folders. Verified by a headless selftest (7/7) on ship day.

### Proactive & Sidekick (`ProactivePane.swift`)
Autosaving standing instructions + Sidekick's shortcut key and standing context. Stored, not yet
consumed — see the NOT-wired list above.

### Connect AIs to Knowledge (`YourAIsPane.swift`)
The story leads: a value blurb (your ChatGPT/Claude, phone apps included, read the knowledge
base and choose what's relevant) then the plain-language privacy explainer (local-first,
PII-stripped summaries only, E2E-encrypted [see the NOT-wired list], no accounts, the 30-day
self-delete in plain words, open-source backend). Then the share toggle (OFF = confirm dialog →
`disable()`, which deletes the cloud copy but keeps the token), and the pane's HERO: the glowing
**Connect your AIs** `GlowButton` → **`ConnectAIsView`, now the REAL guided setup**: step 1 =
the masked link (`MirrorClient.maskedURL`) + Copy, step 2 = Copy the system prompt, closing with
the magic line ("ask it: what do you know about me?"); a sharing-off state points back at
Settings. Live `stats()` activity below; local-only story when sharing is off.
**Regenerate was removed from the UI** (a footgun that bricks every connector the user set up) —
`MirrorClient.regenerateToken()` remains as a backend/support remediation.
⚠️ `maskedURL` must search "/mcp" BACKWARDS: the host `https://mcp.sentient-os.ai` itself
contains "/mcp", and a forward hit inverts the range (a shipped-then-fixed crash).

### System (`SystemPane.swift`)
The overnight-intelligence story (prose; 3 AM is our taste, not a dial), launch-at-login
(`LoginItem`) with a keep-Sentient-alive confirm on the way off, the privacy pledge with the two
split consents (crash reports `diagnosticsEnabled` → Sentry · analytics `analyticsEnabled` →
TelemetryDeck, each with its own `applyEnabledChange()`), and the **Danger Zone**: Reset runs the
shared `FactoryReset` (`Ingestion/FactoryReset.swift` — cycle store + knowledge-base folder +
proactive traces + lifetime counters + the cloud mirror copy, deleted best-effort so an offline
reset still succeeds; same code path as Dev Tools' "Reset everything", so the wipes can never
drift. The mirror token + opt-in survive — the share URL pasted into the user's connectors keeps
working, and the next push recreates the copy). **Reset also REWINDS to the start of onboarding**:
it clears `onboarding.step`, `plan.kbOnly`, and `hasCompletedOnboarding` (flipping the live
`AppState` so the main window switches immediately), and the Settings window dismisses itself to
reveal it — this is the free→Plus "Reset & Rebuild" path (re-onboarding re-runs the plan
crossroads, which re-detects the plan fresh). The free home's Reset buttons deep-link here via
`SettingsView.requestedPane = .system` (a one-shot handoff consumed on appear).
**The Reset button locks while the pipeline runs**
(`Ingestion/PipelineActivity.swift`, a counter flag begun/ended by `IterativeRun` +
`ProactiveCycle`) — wiping mid-run would leave high-water marks pointing past erased notes.

### Permissions & Health (`HealthPane.swift`)
The health board. A spinner line ("Checking your Sentient…") holds the pane through the first
probe (the codex login check shells out and takes seconds), then rows cascade in (a gentle
staggered rise). Severity-ordered rows, each with an `InfoTip` (tiny info icon; hover 0.15s
opens a popover to the right; `TipWarmth` makes sibling tips open instantly):

- **ON-DEVICE INTELLIGENCE** (the analysis machinery): Full Disk Access (grant deep-link +
  relaunch link) · Overnight wake (🟢 = the installed daemon plist points at THIS binary; fix runs
  `WakeHelperInstaller.installAsync()` — **[DECIDED 2026-07-04] the password install IS
  production**, no Login Items migration) · Launch at login (yellow when off).
- **SIDEKICK & PROACTIVE** (the magic's grants — lazy-asked, yellow while not-asked/off; only an explicit mic/speech DENIAL goes red):
  Microphone & Speech (one row: `VoiceCapture.requestPermissions()` asks both; denied deep-links
  to the actual blocker) · **Screen Recording** (Sentient's OWN grant — Sidekick snaps a screen
  still per command, `Notch Magic/ScreenCapture.swift`; commands run text-only without it; fix =
  `CGRequestScreenCaptureAccess`, which prompts only on the first-ever ask, else the Settings
  deep-link; there's no macOS API to tell "never asked" from "denied") · Notifications (the
  morning briefing note).

  **The lazy-grant policy (Sidekick permissions):** nothing is requested at launch or as an
  onboarding step. The mic + speech prompts surface the FIRST time the user holds the hotkey
  (`VoiceCapture.authorize`, on a confirmed hold — never on a tap); the screen-recording ask joins
  that same first-invoke moment when the onboarding gating lands (the wiring that arms Sidekick
  only after initial processing — [WIP]). Until then this pane's "Allow…" rows are where the
  grants happen; Sidekick degrades gracefully without them (voice needs mic; the screen still is
  skipped).
- **SET UP CODEX:** CLI / ChatGPT account / **ChatGPT plan** / computer use — the CLI, account,
  and computer-use rows go red when missing and their fixes open the shared `CodexSetupView`
  (statuses re-probe when the sheet closes). The plan row (shown once logged in, decoded via
  `CodexAuth.currentPlan()`) is amber on free/go — "free · knowledge base only" — with a
  **Re-check** pill that runs `CodexAuth.refreshPlan()` (the on-demand token re-mint), so an
  upgrade shows up in seconds instead of on codex's 8-day timer; a limited plan also keeps the
  codex group expanded (it never folds into "Codex is all good").
- **CODEX PERMISSIONS:** the helper's Accessibility + Screen Recording — system-TCC, read via
  our FDA, status + deep-link only; shown once computer use exists.
- **The codex collapse:** when the WHOLE stack is green, the five codex rows fold into one line
  ("Codex is all good. · Details"); expanding is a one-way door per visit. Anything unhealthy
  keeps the full board open.
- **Automation has NO row:** ~0.5s after the pane opens it probes the user-db grant and silently
  re-runs `grantComputerUseAutomation()` if missing (idempotent, logged). The user has no job
  there, so the UI gives them none.
- Red = a core capability is broken · yellow = optional or fixable-later. Statuses re-probe on
  every app foreground.

## Copy rules learned here

No em dashes in user-facing settings copy (reads as AI slop; use commas/semicolons/colons/
breaks). Guilt-trip confirms on the toggles that keep Sentient alive. Info-tip copy is short,
plain, and trust-first: who the grant belongs to, what it unlocks, what stays on the Mac.
