# Settings (Views/Settings/)

The two-pane Settings window (windowID `settings`, opened from the home's gear): a quiet sidebar of seven
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
| `ConnectorsSection.swift` · `ConnectorConnectSheet.swift` | Connector catalog and account popups. Notion and Granola connect after browser sign-in and a native account check. Tool classification waits until use, and curated knowledge selection is available immediately. |
| `FrontierModelPane.swift` | Frontier Model Choice (a thin wrapper over the shared `FrontierEnginePicker`). |
| `DoubleTapPane.swift` | Drafting provider, endpoint/model, custom reply instructions, one-time writing examples and privacy information. |
| `ProactivePane.swift` | Proactive & Sidekick. |
| `ShareKnowledgePane.swift` | Give AIs Knowledge. |
| `SystemPane.swift` | System. |
| `HealthPane.swift` | Permissions & Health. |
| `PrivacyCopy.swift` | Shared privacy explanations for Settings, onboarding, permissions and the full in-app policy. Keep feature-specific data paths consistent across surfaces. |
| `UninstallView.swift` · `PrivacyPolicyView.swift` | The farewell sheet and the full in-app privacy policy. |

## The panes

**Knowledge Sources.** The shared picker uses the same preferences as onboarding, the home,
Dev Tools, and scheduled runs (`SourceSelection`, `CustomRoots`). Email & Calendar groups Gmail,
Google Calendar, Apple Mail, Apple Calendar, and curated Outlook connections. Chats opens the shared WhatsApp
and iMessage pickers; More of your world includes Apple Notes and other curated connections. Folders
provides standard-folder toggles and persistent custom roots through an `NSOpenPanel`. Hosted
connection sheets follow the chosen frontier engine and its availability. A fix-it line appears when
Full Disk Access is missing. The shared four-selection minimum guards direct toggle-offs in Settings
and the onboarding ready step; enabled Apple Mail and Apple Calendar selections each count as one source.

Apple Mail opens `Views/AppleMailPicker.swift` to select accounts already synced in Mail. It needs
Full Disk Access and processes downloaded bodies through the on-device model. It works with every
supported frontier backend. Its local read does not add addresses to the founder-feedback list.

Apple Calendar appears in the shared **Email & Calendar** group and opens
`Views/AppleCalendarConnectSheet.swift`. The sheet requests native permission only after the user
presses Allow Calendar Access, then saves an explicit per-calendar selection. It supports refresh,
clear, missing-calendar recovery, and a System Settings link after denial. Saving is disabled during
analysis. The local source works on every frontier backend and does not require Full Disk Access.
The permission explanation clarifies that Sentient only reads the calendars the user chooses.

**Frontier Model Choice.** Which AI organizes knowledge, prepares suggestions and powers Sidekick: the shared engine pills and per-engine
panels (`FrontierEnginePicker`, layout `.settingsGrid`); Settings' own ChatGPT panel activates with Use
ChatGPT and points at Permissions & Health for login and plan; the Claude panel is self-contained
(lazy install on "Sign in with Claude", the plan chip, Use Claude). Shared Codex CLI and native
computer-use setup start at app launch; commitment actions join or retry that work as needed.
Browsing tabs starts no additional installation. See the BYOM and ClaudeCLI docs.

**Double Tap.** Independent drafting-provider selection: covered Sentient route, OpenAI, OpenRouter,
Ollama, LM Studio, or another compatible endpoint. Custom endpoints expose API format and model
controls; API keys are stored in Keychain. Custom reply instructions shape the draft.
**Show writing examples in Finder** opens the editable one-time `writingstyle.md` snapshot.
The info explanation leads with fast, covered drafts and explains the default OpenAI API Zero Data
Retention route, the screenshot/knowledge context and the unsent result. See the Double Tap guide.

**Proactive & Sidekick.** The user's standing proactive instructions (`proactive.instructions`, fed to
both proactive prompts), the Sidekick key (right ⌘ / right ⌥; toggling posts `.sidekickHotkeyChanged`
and re-keys the live monitor), the standing Sidekick context (`sidekick.context`, fed to the command
prompt), and the **Speed vs Intelligence** slider (`ComputerUseSpeed`, read fresh per computer-use
run: on Codex, Faster / Medium / Smarter → GPT-6 Sol low / GPT-6 Astra low / GPT-6 Astra medium; on the Claude engine the tier
picks the model too — sonnet·low / sonnet·medium / opus·medium, with the honest model named in the readout;
dimmed with a hover explanation on a custom backend, where the model's single reasoning level lives in
Frontier Model Choice). All live,
no restart; `sidekick.speed` and its existing stored values remain stable. The slider controls computer-use runs, including a routed task's computer-use fallback; successful MCP-only tasks retain their existing model policy. The standing-instruction keys live in `CustomInstructions`.

**Give AIs Knowledge** (pane title "ChatGPT & Claude"). The value blurb and four privacy pillars
(local knowledge ownership, on-Mac encryption with no persisted relay key, no separate Sentient login, and an open-source relay), the
Cloud Sync group with the "Set up in 2 minutes" / "Configure" CTA into `ConnectAIsView` (which owns
sharing on/off; the pane carries no toggle), live `stats()` activity when sharing is on, and the
local-folder access explanation when off. A local tool can read the folder directly; whether inference is local depends on that tool’s model. Regenerate has no UI (a support remediation only).

**System.** Three chapters split by two dividers: how Sentient runs (the overnight story as prose, the
launch-at-login toggle with a keep-Sentient-alive confirm on the way off, the Updates group with the
version and Check for Updates Now), privacy (the two toggles: crash reports → Sentry, analytics →
TelemetryDeck, each applying live; the always-on core-tier disclosure appears under the analytics
toggle when it is off; Read More → the `PrivacyPolicyView` sheet), and behind a
red-tinted hairline the exit door: **Reset Sentient…** (the shared `FactoryReset`, which rewinds to the
start of onboarding and dismisses Settings; locked while `PipelineActivity` reports a run) and
**Uninstall Sentient…** (the farewell sheet). Reset removes local knowledge/analysis and attempts
mirror deletion; uninstall also clears local setup and credentials. Both preserve the founder-feedback
list and invitation/lifetime-access records. There is no saved-address management pane.

**Permissions & Health.** The health board: a "Checking your Sentient…" line during the first probe
(the codex login check shells out), then rows cascading in. ON-DEVICE INTELLIGENCE: Full Disk Access
(fix = the drag panel with Sentient as the card + a relaunch link), Overnight wake (green only when the
daemon answers over XPC; `notSetUp` fixes with the password installer, `disabled` gets a Turn On… into
Login Items), Launch at login (needs-approval gets the guide's instruction panel). SIDEKICK &
PROACTIVE: Microphone & Speech, Sentient Screen Recording, and Notifications. A shared Computer Use
group shows the native helper's Accessibility and Screen Recording grants for every model backend;
visible setup handles Automation consent through the macOS prompt.

The engine group follows the frontier choice. ChatGPT shows Codex CLI, ChatGPT account and plan.
Claude shows Claude Code CLI, the Claude account, and Codex CLI for computer use, with no ChatGPT
sign-in requirement. Custom endpoints show Codex CLI and the configured frontier model. All variants
end with the signed native helper's installation status and shared progress.

Fixes run inline through the existing setup engines. Claude health checks both CLIs while retaining
Claude's own login status. A healthy engine group collapses to one summary line; foreground changes
refresh its state. CLI compatibility and native permissions also gate the first computer task.

## The Uninstall sheet (`UninstallView`)

Four phases: the farewell ("Before you go.", the founders' note, the mono-caps manifest of what gets
removed, the Keep / Uninstall pill pair, Email the founders, the GitHub mark) → working (the
`Uninstall.Stage` whispers over a quiet spinner) → the helper-password interstitial (only if the admin
prompt is declined: Enter Password / Skip / Cancel) → gone (drag Sentient to the Trash, then Quit via
`Uninstall.finishAndQuit`). The teardown itself is `System/Uninstall.swift`.

## Shared privacy copy

`PrivacyCopy.swift` is the shared wording source. Lead with **Personal AI. Privacy at its core.**
Explain the relevant stage: local source analysis, chosen-model inference, Double Tap drafting, or
optional MCP sharing. Do not turn a local-analysis statement into a promise that all task context
always stays on the device. Mirror wording must distinguish encrypted storage and a non-persisted
key from in-memory decryption for authorized requests.

## Copy rules learned here

No em dashes; commas, semicolons, colons, or line breaks. Explain the practical effect of changing background-run settings. Info tips are short and trust-first (who the grant belongs to, what it unlocks, what
stays on the Mac), and a tip that appears on several surfaces carries the same copy everywhere.

## Related docs

`Sources/Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md`, `Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md`, `Cloud/Documentation - Cloud - Plan Gate (CodexAuth).md`, `Cloud/Documentation - Cloud - MCP Mirror.md`, `System/Documentation - System (Permissions, Health, Uninstall).md`, `Views/Permissions/Documentation - Permission Gate & Guide.md`, `Updates/Documentation - Auto-Update (Sparkle) & Release Pipeline.md`.

All engines show the native helper's Accessibility and Screen Recording grants, with Automation consent handled by the macOS prompt. Changing engines prepares the selected dependency without rewriting Codex configuration or login.
