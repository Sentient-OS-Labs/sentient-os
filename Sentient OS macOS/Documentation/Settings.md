# Settings — the two-pane window

The real Settings (shipped 2026-07-04, PRs #107 + #109): a modern two-pane window in the
OLED-editorial design language. Sidebar of five sections on the left (plus the About footer:
version, GitHub, report-an-issue — the "Open source on GitHub" link + heart wear
**`Theme.Ink.gold`**, the open-source pride mark, deliberately louder than the footer's whisper
and distinct from the caution amber), the selected pane on the right, and the trust ribbon —
since 2026-07-13 riding ONLY Knowledge Sources and Permissions & Health (the panes where the
files story is the message), not every pane. Opened from the home's top-bar gear
(`windowID "settings"`, 940×660 default). Everything lives in `Views/Settings/`: the shell
(`SettingsView.swift`), one file per pane, and the shared pieces (`SettingsComponents.swift`).

## ⚠️ NOT wired up yet (read this first)

*(Two former items are DONE and gone from this list: the mirror's encryption at rest shipped —
AES-256-GCM before upload, see `MCP Mirror Client.md` — so the pane's E2E copy is now true; and
the System pane's Updates group is live with Sparkle, see `Auto-Update (Sparkle).md`.)*

1. **The morning notification** — the Notifications permission row is real, and the permission ask
   is now wired: onboarding's permissions screen fires `Notify.ask()` on appear, so the native
   macOS prompt happens once with no extra UI (`ask()` no-ops unless status is still
   `.notDetermined`). What's still dormant is the *sending* — `Notify.now()` has zero call sites;
   the "Proactive Intelligence is ready" morning note ships with the reminders/scheduler work.
2. **Privacy toggles transmit only in RELEASE builds** — by design (Sentry/TelemetryDeck never
   boot in DEBUG), so a Debug QA can verify persistence but not transmission.
3. **Small known holes, accepted for now:** removing the LAST custom folder can bypass the
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
Autosaving standing instructions + Sidekick's shortcut key and standing context. The **shortcut
key** (right ⌘ / right ⌥) is live — toggling it posts `.sidekickHotkeyChanged`, which re-keys the
running `SidekickHotkeyMonitor` with no restart. The two **text fields** are live too: the keys
live in `CustomInstructions` (so producer and consumers can't drift), and `proactive.instructions`
feeds both proactive prompts (`Proactive.instructionsBlock` — PART 1 + PART 2) while
`sidekick.context` feeds the command/Sidekick prompt (`CommandRunModel.commandPrompt`, §6b of the
Notch doc). Each is `""`-safe: no text → the prompt is unchanged.

**The Speed vs Intelligence slider (2026-07-13):** a compact custom three-detent slider
(`SpeedIntelligenceSlider`, private to the pane — 300×24pt pill permanently wearing its own
three-stop spectrum, `Theme.Ink.green` → cyan → purple, glow beneath; only the white thumb moves;
the readout docks the tier name under the left edge and "GPT-5.6 SOL · LOW/MED/HIGH THINKING"
under the right, live mid-drag). It writes `ComputerUseSpeed` (`Cloud/ComputerUseSpeed.swift` —
the one source of truth: key `sidekick.speed`, tiers Faster/Medium/Smarter → gpt-5.6-sol effort
low/medium/high, default Faster = the pre-slider behavior). **It governs EVERY computer-use run**
— Sidekick, the command bar, and a card's fire all ride `runAgentCommand`, which reads the
setting fresh per run (live, no restart). A brighter `SettingsHairline(opacity: 0.12)` splits the
Proactive and Sidekick groups (same splitter as Health's codex divider).

### Give AIs Knowledge (`ShareKnowledgePane.swift`)
*(Renamed 2026-07-13 from "Connect AIs to Knowledge"/`YourAIsPane` — the whole surface family is
now `ShareKnowledge*`: the pane, the home's `ShareKnowledgePopover`, `Pane.shareKnowledge`. The
guided `ConnectAIsView` window keeps its name — in there "connect" is the literal action.)*
The story leads: a value blurb (your ChatGPT/Claude, phone apps included, read the knowledge
base and choose what's relevant) then the plain-language privacy explainer (local-first,
PII-stripped summaries only, E2E-encrypted, no accounts, the 30-day
self-delete in plain words, open-source backend). Then the share toggle (OFF = confirm dialog →
`disable()`, which deletes the cloud copy but keeps the token), and the pane's HERO: the glowing
**Set up in 2 minutes** capsule (`ConnectCTA` — same label as the home popover's CTA) →
**`ConnectAIsView`, the REAL guided setup**: step 1 =
the masked link (`MirrorClient.maskedURL`) + Copy, step 2 = Copy the system prompt, closing with
the magic line ("ask it: what do you know about me?"); a sharing-off state points back at
Settings. Live `stats()` activity below; local-only story when sharing is off.
**Regenerate was removed from the UI** (a footgun that bricks every connector the user set up) —
`MirrorClient.regenerateToken()` remains as a backend/support remediation.
⚠️ `maskedURL` must search "/mcp" BACKWARDS: the host `https://mcp.sentient-os.ai` itself
contains "/mcp", and a forward hit inverts the range (a shipped-then-fixed crash).

### System (`SystemPane.swift`)
Reads as three chapters split by two dividers (2026-07-13): *how Sentient runs* (Overnight ·
Startup · Updates), then a bright hairline; *privacy*; then a **red-tinted hairline**
(`SettingsHairline(color: Theme.Ink.red, opacity: 0.25)` — the app's one semantic divider, the
line you cross into destructive territory) guarding the exit door (Danger Zone · Uninstall).
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

**Uninstall Sentient…** (Danger Zone) opens the farewell sheet — `Views/Settings/UninstallView.swift`
driving `System/Uninstall.swift`, four phases. The farewell: "Before you go." + the founders' note
(open source / free forever), a mono-caps **manifest** of what gets removed (a 2×2 grid: model ·
knowledge base · cloud copy · wake helper), the uniform Keep/Uninstall pill pair (`FarewellPill` —
one equal-width capsule shape for the whole sheet), **Email the founders** centered beneath (a
mailto that routes around browser-owned handlers → Apple Mail → copies the address; the click never
silently no-ops), and the **GitHub mark** bottom-right (`GitHubMark` template SVG asset → the org
repo) — deliberately no trust footer on this sheet. Then: the working teardown (stage whispers) →
the helper-password interstitial (only if the admin prompt is declined) → gone (drag the .app to
the Trash, hard-exit Quit). The teardown removes the wake helper, cloud copy, Keychain identity,
knowledge base, model, caches, the TCC automation grant, and every default — leaving the .app,
`~/.codex`, and gift keepsakes. ⚠️ It raises `AppState.isUninstalling` FIRST: the defaults wipe
re-publishes every @AppStorage key (the card deck's included), and without that gate the home
re-dealt a demo deck behind the sheet (field-found 2026-07-11). The home empties its deck while
the flag is up; a cancel deals the cards back in.

### Permissions & Health (`HealthPane.swift`)
The health board. A spinner line ("Checking your Sentient…") holds the pane through the first
probe (the codex login check shells out and takes seconds), then rows cascade in (a gentle
staggered rise). Severity-ordered rows, each with an `InfoTip` (tiny info icon; hover 0.15s
opens a popover to the right; `TipWarmth` makes sibling tips open instantly):

- **ON-DEVICE INTELLIGENCE** (the analysis machinery): Full Disk Access (fix = the floating
  drag-panel guide with Sentient as the card — `PermissionGuide`, see `Permission Guide
  (First-Use Grants).md` — + the relaunch link) · Overnight wake (🟢 = the daemon ANSWERS over
  XPC — `WakeHelperClient.healthProbe()`, the only check the System Settings background toggle
  can't fool [2026-07-11]; `notSetUp` fixes with `WakeHelperInstaller.installAsync()` —
  **[DECIDED 2026-07-04] the password install IS production** — while `disabled` ("turned off in
  login items") gets a **Turn On…** that deep-links to the switch, since a reinstall can't
  override it) · Launch at login (yellow when off; a needs-approval state adds the guide's
  instruction panel over Login Items).
- **SIDEKICK & PROACTIVE** (the magic's grants — lazy-asked, yellow while not-asked/off; only an explicit mic/speech DENIAL goes red):
  Microphone & Speech (one row: `VoiceCapture.requestPermissions()` asks both; denied deep-links
  to the actual blocker) · **Screen Recording** (Sentient's OWN grant — Sidekick snaps a screen
  still per command, `Notch Magic/ScreenCapture.swift`; **OPTIONAL by decision [2026-07-09]**:
  amber with an "optional" note, commands run text-only without it; fix = the drag-panel guide
  with Sentient as the card — NOT `CGRequestScreenCaptureAccess`, which on Tahoe doesn't reliably
  add the app to the list) · Notifications (the morning briefing note).

  **The lazy-grant policy (Sidekick permissions):** nothing is requested at launch or as an
  onboarding step. The mic + speech prompts surface the FIRST time the user holds the hotkey
  (`VoiceCapture.authorize`, on a confirmed hold — never on a tap), and the FIRST computer-use
  action (command bar, Sidekick, a card's fire) raises the one-time `ComputerUseGate` window,
  which gathers mic+speech, the optional screen recording, and the codex helper's two grants in
  one place (see `Permission Guide (First-Use Grants).md`). This pane stays the always-available
  fallback; Sidekick degrades gracefully without the optional grants (voice needs mic; the screen
  still is skipped).
- **SET UP CODEX:** CLI / ChatGPT account / **ChatGPT plan** / computer use — the CLI, account,
  and computer-use rows go red when missing, and their fixes drive the shared `CodexSetup` engine
  **INLINE** (no sheet — the old wiring bounced through `CodexSetupView`, now dev-tools-only;
  decided 2026-07-11): while a step runs its LED goes AMBER (a third meaning: *working on it*),
  the note narrates ("installing…" / "finish in your browser" / "setting up…"), the pill hides,
  and failures land as a quiet prose line under the row. The browser login is auto-noticed (the
  same 2s `codex login status` poll onboarding uses — no "I'm done" button; the pill stays as
  **Re-open…** so an abandoned browser never strands the row), and the computer-use bootstrap
  streams its progress line under the row (a ~535 MB download deserves narration). The plan row
  (shown once logged in, decoded via `CodexAuth.currentPlan()`) is amber on free/go — "free ·
  knowledge base only" — with a **Re-check** pill that runs `CodexAuth.refreshPlan()` (the
  on-demand token re-mint), so an upgrade shows up in seconds instead of on codex's 8-day timer;
  a limited plan also keeps the codex group expanded (it never folds into "Codex is all good").
- **CODEX PERMISSIONS:** the helper's Accessibility + Screen Recording — system-TCC, read via
  our FDA; shown once computer use exists. Fix = the drag-panel guide with the HELPER as the
  card (the plain deep-link survives only as the helper-missing fallback).
- **The codex collapse:** when the WHOLE stack is green, the five codex rows fold into one line
  ("Codex is all good. · Details"); expanding is a one-way door per visit. Anything unhealthy
  keeps the full board open.
- **Automation has NO row:** ~0.5s after the pane opens, `Permissions.selfHealComputerUseAutomation`
  probes the user-db grant and silently re-runs `grantComputerUseAutomation()` if missing
  (idempotent, logged). The user has no job there, so the UI gives them none. (The same extracted
  self-heal also runs when the first-use `ComputerUseGate` window presents — before the first fire
  ever needs it.)
- Red = a core capability is broken · yellow = optional, fixable-later, or working on it.
  Statuses re-probe on every app foreground. The home's live health banner
  (`System/HealthCaution.swift`, see the Home doc) is this board's herald: it watches the same
  ground truths and its *Open Settings* lands here.

## Copy rules learned here

No em dashes in user-facing settings copy (reads as AI slop; use commas/semicolons/colons/
breaks). Guilt-trip confirms on the toggles that keep Sentient alive. Info-tip copy is short,
plain, and trust-first: who the grant belongs to, what it unlocks, what stays on the Mac.
Dense tips break into short paragraphs (`\n\n` in the string — `InfoTip` renders them natively):
what-it-does first, mechanics/privacy after; a tip that appears on multiple surfaces carries the
SAME copy everywhere (mic, FDA, overnight wake, screen recording all have twins).
