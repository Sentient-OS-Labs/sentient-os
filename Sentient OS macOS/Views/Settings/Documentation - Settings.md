# Settings (Views/Settings/)

The two-pane Settings page in the main window (opened from Home's gear or ⌘,): a scrollable sidebar of eight
pages grouped under App, Personalization, and Support, with an About footer
(a quiet Invite friends row, followed by version/build and a heart-marked Open source link),
the selected pane on the right, and the trust ribbon riding only the two panes where the files story is
the message (Knowledge Sources, Permissions & Help). Design philosophy: form encodes content. Prose
for stories, hairline toggle lines for switches, chips for sources, status LEDs for health, bordered
surfaces only for real input. Pane titles in the SF display voice, mono-caps group labels, a 640 pt
measure, one green.

The footer omits repeated app branding. Report an issue lives in Permissions & Help →
Troubleshooting. The Open source link opens GitHub; the version retains its build number.

Home ↔ Settings uses one reversible SwiftUI transition. The gear emits an anchor preference;
`RootView` resolves it in the current canvas, so the capsule-to-page mask follows real layout and
window resizing. Content scales subtly and unblurs while the surface expands, then returns to the
same gear on Home. The source glyph briefly bridges the endpoints. `HomePageLayer` shares the reveal
with Knowledge, which uses its own icon/label anchor and retains its content. Direct Settings/Knowledge
switches remain immediate; only routes to/from Home morph. Missing/offscreen anchors fall back to a fade,
Reduce Motion uses a short fade, and external Settings pane links preserve their normal route.

Home stays mounted behind the surface with input/accessibility disabled and its composer unfocused.
Draft, transcript and card state remain app-owned. SwiftUI manages interruption and removal without
navigation timers. `MainNavigation` records actual route pairs and fences pending Knowledge approval
callbacks across reset, so a stale prompt cannot reopen a page after reset. The mandatory update
gate remains above the transition.

## Files

| File | Job |
|---|---|
| `SettingsView.swift` | Sidebar + detail and `Pane`; selection/deep links use `MainNavigation`. |
| `SettingsPageTransition.swift` · `SettingsTransitionGeometry.swift` | Gear anchor, scoped reversible reveal and bounded geometry. `RootView` owns the page overlay. |
| `SettingsComponents.swift` | The shared pieces: `SettingsPane`, `SettingsGroup`, `SettingsProse`, `SettingToggleLine`, `SettingsPillButton`, `ChipFlow`, `SettingsChip`, `StatusLine` + `HealthDot`, `InfoTip`, `SettingsTextBox`, `SettingsHairline`, `LockedChipTip`. |
| `SourcesPane.swift` | Knowledge Sources. |
| `ConnectorsSection.swift` · `ConnectorConnectSheet.swift` | Connector catalog and account popups. Notion and Granola connect after browser sign-in and a native account check. Tool classification waits until use, and curated knowledge selection is available immediately. |
| `../ModelSelectionDesign.swift` | Shared animated capsule selectors, centered headings, and atmospheric account panels. |
| `FrontierModelPane.swift` | AI Models & Accounts: Main AI / Double Tap sections, provider choice and sign-in. |
| `DoubleTapPane.swift` | Double Tap activation, writing instructions/examples, and the shared `DoubleTapModelSettings` editor used in AI Models & Accounts. |
| `ProactivePane.swift` | Sidekick activation, instructions, and speed. |
| `OvernightPane.swift` | Overnight timing, wake readiness, suggestion instructions, and notifications. |
| `NotificationPermissionSetting.swift` | Shared notification status and permission actions. |
| `ShareKnowledgePane.swift` | Knowledge Sharing. |
| `SystemPane.swift` | System: updates, privacy, reset, and uninstall. |
| `HealthPane.swift` | Permissions & Help. |
| `PrivacyCopy.swift` | Shared privacy explanations for Settings, onboarding, permissions and the full in-app policy. Keep feature-specific data paths consistent across surfaces. |
| `UninstallView.swift` · `PrivacyPolicyView.swift` | The farewell sheet and the full in-app privacy policy. |

## The panes

**Knowledge Sources.** The shared picker uses the same preferences as onboarding, the home,
Dev Tools, and scheduled runs (`SourceSelection`, `CustomRoots`). Email & Calendar groups Gmail,
Google Calendar, Apple Mail, Apple Calendar, and curated Outlook connections. Messages opens the shared WhatsApp
and iMessage pickers; Apps & notes includes Apple Notes and other curated connections. Folders
provides standard-folder toggles and persistent custom roots through an `NSOpenPanel`. Hosted
connection sheets follow the chosen frontier engine and its availability. New setups start with all
folders off. Personal setup requires three usable selected sources; unavailable or disconnected
sources do not count. Settings always allows removing a source, including below this minimum.
Full Disk Access is explained only after choosing a protected local app. Cloud-only setup has no FDA
gate. Permission grants never opt in other sources, and the source-specific relaunch action waits
until active tasks have finished. Existing saved source choices and opt-outs survive setup resumption. The
source-access sheet uses a single Enable access action to open the floating Full Disk Access drag
guide with Sentient’s own app bundle. Returning from Settings checks only the chosen source’s
readability, without selecting it or advancing automatically. Continue checks again before opening
the chat/account picker (or enabling the explicitly chosen Notes source). Restart is offered only
after an unsuccessful check, remains guarded by SafeAppRelaunch, and never happens automatically.
Closing the sheet closes only its own drag guide. Existing selections retain Stop reading.

Apple Mail opens `Views/AppleMailPicker.swift` to select accounts already synced in Mail. It needs
Full Disk Access and processes downloaded bodies through the on-device model. It works with every
supported frontier backend. Its local read does not add addresses to the founder-feedback list.

Apple Calendar appears in the shared **Email & Calendar** group and opens
`Views/AppleCalendarConnectSheet.swift`. The sheet requests native permission only after the user
presses Allow Calendar Access, then saves an explicit per-calendar selection. It supports refresh,
clear, missing-calendar recovery, and a System Settings link after denial. Saving is disabled during
analysis. The local source works on every frontier backend and does not require Full Disk Access.
The permission explanation clarifies that Sentient only reads the calendars the user chooses.

**AI Models & Accounts.** `ModelChoiceBar` provides the same custom capsule treatment for
Main AI / Double Tap and the provider selector. Its white selection highlight animates between
items, respects Reduce Motion, and scrolls horizontally on narrow widths. `ModelSelectionPanel`
reuses the permission window's edge lighting; each account shows one combined connection/plan
status. There is no native segmented-control accent or separate grid of provider tiles.

Two sections distinguish the Main AI (knowledge, suggestions and
Sidekick) from the independent Double Tap drafting model. Main AI uses the shared
`FrontierEnginePicker` provider panels. ChatGPT embeds `OnboardingCodexLoginPanel(settingsStyle: true)`
so sign-in owns and cancels only its own pending login attempt; the account plan and refresh control
are on this page. Claude keeps its existing inline sign-in panel. Browsing providers does not select
them or start installation. Double Tap contains its existing provider, API key, model and endpoint
editor. Credentials still save to the same Keychain accounts and preferences retain their old keys.

`Scripts/render_model_selection.py` renders the production Settings and onboarding model views
with offline display-state fixtures. Account and installer services are inert; unrelated onboarding
privacy chrome is omitted. Captures cover signed-in, signed-out, and narrow endpoint states.
Onboarding shows only the main-provider selector, never Double Tap model controls.

`MainNavigation.modelSettingsSection` is session-only. Explicit Main AI deep links select Main AI;
Double Tap's Change model action opens the Double Tap section. Reset clears that selection.

**Double Tap.** Activation exposes the same shared shortcut as Sidekick, followed by writing
instructions and examples. Change model opens AI Models & Accounts → Double Tap. Its independent
drafting-provider selection supports: covered Sentient route, OpenAI, OpenRouter,
Ollama, LM Studio, or another compatible endpoint. Custom endpoints expose API format and model
controls; API keys are stored in Keychain. Custom reply instructions shape the draft.
**Show writing examples in Finder** opens the editable one-time `writingstyle.md` snapshot. When no
snapshot exists, **Collect examples** explicitly retries collection from eligible selected sources.
No eligible examples leaves the file absent. Double Tap remains available with conversation, knowledge
and custom instructions; existing files, including deliberately empty ones, are never replaced.
The info explanation leads with fast, covered drafts and explains the default OpenAI API Zero Data
Retention route, the screenshot/knowledge context and the unsent result. See the Double Tap guide.

**Sidekick.** Activation (the shared shortcut and notch toggle), custom instructions, and speed.
The key (right ⌘ / right ⌥ / another modifier) is shared with Double Tap and edits the same preference
from either page, posting `.sidekickHotkeyChanged` to re-key the live monitor. Controls retain
the standing Sidekick context (`sidekick.context`, fed to the command
prompt), and the **Speed vs Intelligence** slider (`ComputerUseSpeed`, read fresh per computer-use
run: on Codex, Faster / Medium / Smarter → GPT-6 Sol low / GPT-6 Astra low / GPT-6 Astra medium; on the Claude engine the tier
picks the model too — sonnet·low / sonnet·medium / opus·medium, with the honest model named in the readout;
dimmed with a hover explanation on a custom backend, where the model's single reasoning level lives in
AI Models & Accounts). All live,
no restart; `sidekick.speed` and its existing stored values remain stable. The slider controls computer-use runs, including a routed task's computer-use fallback; successful MCP-only tasks retain their existing model policy. The standing-instruction keys live in `CustomInstructions`.

**Knowledge Sharing.** Embeds the existing `ConnectAIsView(presentation: .settings)` directly
in the right-hand pane. Sharing off shows the same explicit consent and privacy explanation;
sharing on shows the same ChatGPT, Claude, and Other AIs connection guides and confirmed
Stop & Delete Cloud Copy action. No separate setup-launch card or duplicated explanation panels.

The embedded presentation scrolls within the available pane and wraps video steps into an adaptive
grid, without imposing the standalone window's minimum size. While sharing is off, that guide remains
blurred and dimmed behind the scrollable consent introduction; it cannot receive clicks or accessibility
focus until sharing is enabled. Enabling sharing reveals the guide in place. The standalone window remains
available from Knowledge's sharing popover. Its Not now action only appears in that window;
in Settings, the sidebar remains available to leave the page. Returning to either window refreshes
the current sharing state. Merely opening Settings never enables or disables sharing.

A quiet local-storage note includes an Open folder link to `VaultGenerator.vaultRoot` in Finder.
When sharing is off, it sits below the consent button with equal space above and below it down to
the pane's bottom. The layout grows and scrolls at short heights rather than overlapping content.
When sharing is on, the note remains in the guide header; there is no separate footer. A missing folder is explained without creating an empty vault. Regenerate remains a
support-only operation with no UI.

**System.** The second-last sidebar item, above Permissions & Help under Support. Updates appear first, followed by privacy
controls and the danger-zone Reset and Uninstall controls.
Crash reports and extended analytics retain their saved preferences, live callbacks, core-analytics
disclosure, and Privacy Policy sheet.
Invite friends is a persistent sidebar-footer action with the existing invitation controls in a sheet.
Diagnostic export lives in Permissions & Help. Reset removes local
knowledge/analysis and attempts mirror deletion; uninstall also clears local setup and credentials.
Both preserve the founder-feedback list and invitation/lifetime-access records.

**Overnight & Suggestions.** Two compact neutral cards: Overnight time, and Morning
suggestions. The first combines the time picker with a single Setup & requirements disclosure
for wake-helper access and the Permissions & Help → Startup link. It opens by default after a passive
readiness check when wake setup is incomplete, even if analysis is off; a manual expand/collapse
choice is preserved while the page is open. Its label highlights
Finish wake setup only when overnight processing is requested and the helper needs attention.
The second keeps the instructions (`proactive.instructions`) and notification permission on one
surface. Helper copy has no individual cards, and the long overnight explanation is not repeated.
Visiting or editing the page does not enable the scheduler. Notification controls use the same
component as Permissions & Help; permission prompts occur only on the explicit Allow action.

The **overnight wake time** defaults to 3 AM and uses local wall-clock time. It retains the existing
`dbg.scheduler.minutes` key so earlier configured times survive. Edits re-arm the enabled production
or developer schedule through the existing loop, never interrupt an active overnight analysis, and
do not enable scheduling when it is off. The Analysis popover reflects the selected time.

Under **Sidekick**, **Open Sidekick by clicking the notch** controls only the idle hover
and click affordance (`sidekick.notchClickEnabled`, default true). Turning it off immediately releases
an idle hover and leaves the notch available to other apps. Keyboard shortcuts and active Sidekick
panels, questions and messages keep their normal behavior; no restart is needed.

**Permissions & Help.** A compact Startup card keeps the Launch at login toggle available,
including its disable confirmation and macOS approval guidance. The Permissions card shows only
missing required access and unverified computer-use access initially. Already granted access is
under **Granted permissions**, and ungranted voice/notification permissions are under **Optional
permissions**. Both disclosures start collapsed. Unused protected sources and inactive overnight
setup are omitted, not claimed as grants. The shared notification row reports status changes back
to the page so it moves to the correct group after permission changes.

`PermissionsOverview` derives these groups from passive capability observations. Full Disk Access
means readability of the selected protected sources, not a demand for a universal grant. Unknown
helper proof stays **Not checked yet**, never granted or denied by inference. On opening this page,
completed setup with granted Automation and Sentient screen access is verified automatically when
the computer-use runtime is idle. This uses the existing helper read-and-capture check without
installing or taking over another helper. Existing grants normally complete quietly; if helper
access has changed, its own setup UI can appear. First-time or failed setup retains the explicit
Review access action. Leaving the page cancels its automatic check.

**Troubleshooting** is one collapsed disclosure by default. A known connection/runtime/source
problem opens it and adds a Needs attention label; optional denied permissions and unknown helper
proof do not open it. The user may collapse it again. Its contents retain source retry notices,
provider-aware runtime/account checks, and the explicit Test & repair computer use action.

**Help** combines Report an issue and Export support file. A short always-visible explanation
mentions recent prompts/replies and review-before-sharing; the full export inventory remains under
What’s in the support file? Exporting only saves to the selected file and never sends it automatically.

`Scripts/test_permissions_overview.py` checks granted/optional/unverified/revoked/unused states
and troubleshooting triggers.

Home's matching health ladder delays selected protected-source checks until personal setup is complete
or that source has a previous successful read. Its copy names unavailable selected sources and preserves
the availability of other sources. `Scripts/test_health_requirements.py` compiles the production ladder
against in-memory fixtures for fresh Home, cloud-only setup, source drift, optional overnight setup,
and unknown/confirmed native evidence, without accessing user data or requesting permissions.

The engine group follows the frontier choice. ChatGPT shows Codex CLI and ChatGPT account status. Account repair links to AI Models & Accounts.
Claude shows Claude Code CLI, the Claude account, and Codex CLI for computer use, with no ChatGPT
sign-in requirement. Custom endpoints show Codex CLI and the configured frontier model. All variants
end with the signed native helper's installation status and shared progress.

Runtime and permission fixes run inline through the existing setup engines; account sign-in lives in AI Models & Accounts. Claude health checks both CLIs while retaining
Claude's own login status. Foreground changes refresh state even while the disclosures are closed. CLI compatibility and native permissions also gate the first computer task.

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

All engines show the native helper's Accessibility, Screen Recording, and Automation status.
Automation consent uses the macOS prompt; an explicit denial has an Open Settings action and
directions to Privacy & Security → Automation → Sentient OS → ChatGPT/Codex Computer Use.

Permissions & Help also offers **Test & repair computer use**. The shared checkup window uses
actual native tools on its own marked controls and reports observed results, separately from
permission/account checks. Only a completed successful check from this exact binary gets a dated
success note. Interrupted focus/Space checks remain retryable. Report review, local save, and an
explicit Supabase send are available afterward; no upload occurs just by running the check.
Permission checks never reset TCC or automatically regrant access. Changing engines prepares
the selected dependency without rewriting Codex configuration or login.
