# Settings (Views/Settings/)

The two-pane Settings window (windowID `settings`, opened from the home's gear): a quiet sidebar of six
sections with an About footer (version, the gold "Open source on GitHub" pride mark, Report an issue),
the selected pane on the right, and the trust ribbon riding only the two panes where the files story is
the message (Knowledge Sources, Permissions & Health). Design philosophy: form encodes content. Prose
for stories, hairline toggle lines for switches, chips for sources, status LEDs for health, bordered
surfaces only for real input. Pane titles in the SF display voice, mono-caps group labels, a 640 pt
measure, one green.

## Files

| File | Job |
|---|---|
| `SettingsView.swift` | The shell: sidebar + detail, the `Pane` enum, `requestedPane` (a one-shot deep link consumed on appear), the `switchPane` notification (a pane deep-linking to a sibling), the update-gate overlay. |
| `SettingsComponents.swift` | The shared pieces: `SettingsPane`, `SettingsGroup`, `SettingsProse`, `SettingToggleLine`, `SettingsPillButton`, `ChipFlow`, `SettingsChip`, `StatusLine` + `HealthDot`, `InfoTip`, `SettingsTextBox`, `SettingsHairline`, `LockedChipTip`. |
| `SourcesPane.swift` | Knowledge Sources. |
| `FrontierModelPane.swift` | Frontier Model Choice (a thin wrapper over the shared `FrontierEnginePicker`). |
| `ProactivePane.swift` | Proactive & Sidekick. |
| `ShareKnowledgePane.swift` | Give AIs Knowledge. |
| `SystemPane.swift` | System. |
| `HealthPane.swift` | Permissions & Health. |
| `UninstallView.swift` · `PrivacyPolicyView.swift` | The farewell sheet and the one-screen privacy policy. |

## The panes

**Knowledge Sources.** The real source picker on the SAME keys as the home popover, onboarding, Dev
Tools, and the 3 AM run (`SourceSelection`, `CustomRoots`). Folders (Desktop / Downloads / Documents
toggles, persistent custom roots with ✕, "+ Add Folder" through an `NSOpenPanel`), Chats & Notes
(WhatsApp, hidden when not installed, and iMessage open the shared `ChatPicker` with chat counts inline;
Apple Notes toggles), and Through Your ChatGPT (Gmail, Google Calendar → `CloudConnectSheet`; locked
chips with a hover tip on free/go plans and custom backends). A fix-it line appears when Full Disk
Access is missing. The **four-selection minimum** (`SourceSelection.selectionCount`, shared with
onboarding's ready screen) guards toggle-offs on the 4 → 3 drop and flashes the whisper amber.

**Frontier Model Choice.** Which engine powers the cloud ~10%: the shared engine pills and per-engine
panels (`FrontierEnginePicker`, layout `.settingsGrid`); Settings' own ChatGPT panel activates with Use
ChatGPT and points at Permissions & Health for login and plan. See the BYOM doc.

**Proactive & Sidekick.** The user's standing proactive instructions (`proactive.instructions`, fed to
both proactive prompts), the Sidekick key (right ⌘ / right ⌥; toggling posts `.sidekickHotkeyChanged`
and re-keys the live monitor), the standing Sidekick context (`sidekick.context`, fed to the command
prompt), and the **Speed vs Intelligence** slider (`ComputerUseSpeed`: Faster / Medium / Smarter → low /
medium / high effort on every computer-use run, read fresh per run; dimmed with a hover explanation on
a custom backend, where the model's single reasoning level lives in Frontier Model Choice). All live,
no restart; the two keys live in `CustomInstructions` so producer and consumers cannot drift.

**Give AIs Knowledge** (pane title "ChatGPT & Claude"). The value blurb and four privacy pillars
(local-first, zero-access encryption, no account + the 30-day self-delete, open-source backend), the
Cloud Sync group with the "Set up in 2 minutes" / "Configure" CTA into `ConnectAIsView` (which owns
sharing on/off; the pane carries no toggle), live `stats()` activity when sharing is on, and the
"prefer fully offline?" prose when off. Regenerate has no UI (a support remediation only).

**System.** Three chapters split by two dividers: how Sentient runs (the overnight story as prose, the
launch-at-login toggle with a keep-Sentient-alive confirm on the way off, the Updates group with the
version and Check for Updates Now), privacy (the two toggles: crash reports → Sentry, analytics →
TelemetryDeck, each applying live; the always-on core-tier disclosure appears under the analytics
toggle when it is off; How We Protect Your Data → the `PrivacyPolicyView` sheet), and behind a
red-tinted hairline the exit door: **Reset Sentient…** (the shared `FactoryReset`, which rewinds to the
start of onboarding and dismisses Settings; locked while `PipelineActivity` reports a run) and
**Uninstall Sentient…** (the farewell sheet).

**Permissions & Health.** The health board: a "Checking your Sentient…" line during the first probe
(the codex login check shells out), then rows cascading in. ON-DEVICE INTELLIGENCE: Full Disk Access
(fix = the drag panel with Sentient as the card + a relaunch link), Overnight wake (green only when the
daemon answers over XPC; `notSetUp` fixes with the password installer, `disabled` gets a Turn On… into
Login Items), Launch at login (needs-approval gets the guide's instruction panel). SIDEKICK & PROACTIVE:
Microphone & Speech (one row, native prompts; only an explicit denial goes red), Screen Recording
(Sentient's own, optional, amber; drag panel), Notifications. SET UP CODEX: Codex CLI, ChatGPT account
(or, on a custom backend, a Frontier model row that deep-links to that pane), ChatGPT plan (amber on
free/go with a Re-check that re-mints the token), Computer use; the fixes drive the shared `CodexSetup`
engine INLINE (amber = working on it; the browser login is auto-noticed by a 2 s poll; the bootstrap
streams its progress under the row). CODEX PERMISSIONS: the helper's Accessibility and Screen Recording,
shown once computer use exists (drag panel with the helper as the card). When the whole codex stack is
green it collapses to one summary line. The Automation grant has no row: it self-heals ~0.5 s after the
pane opens. Statuses re-probe on every foreground.

## The Uninstall sheet (`UninstallView`)

Four phases: the farewell ("Before you go.", the founders' note, the mono-caps manifest of what gets
removed, the Keep / Uninstall pill pair, Email the founders, the GitHub mark) → working (the
`Uninstall.Stage` whispers over a quiet spinner) → the helper-password interstitial (only if the admin
prompt is declined: Enter Password / Skip / Cancel) → gone (drag Sentient to the Trash, then Quit via
`Uninstall.finishAndQuit`). The teardown itself is `System/Uninstall.swift`.

## Copy rules learned here

No em dashes; commas, semicolons, colons, or line breaks. Guilt-trip confirms on the toggles that keep
Sentient alive. Info tips are short and trust-first (who the grant belongs to, what it unlocks, what
stays on the Mac), and a tip that appears on several surfaces carries the same copy everywhere.

## Related docs

`Sources/Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md`, `Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md`, `Cloud/Documentation - Cloud - Plan Gate (CodexAuth).md`, `Cloud/Documentation - Cloud - MCP Mirror.md`, `System/Documentation - System (Permissions, Health, Uninstall).md`, `Views/Permissions/Documentation - Permission Gate & Guide.md`, `Updates/Documentation - Auto-Update (Sparkle) & Release Pipeline.md`.
