# Codex Setup & the Computer-Use Bootstrap (Cloud/)

How Sentient gets a working Codex CLI with computer use onto the user's Mac, with no OpenAI desktop app
installed. Three steps, one shared engine that onboarding, Settings → Permissions & Health, and Dev
Tools all drive:

1. **Install** the Codex CLI (OpenAI's official installer; it doubles as the updater).
2. **Log in** (`codex login`, browser OAuth).
3. **Computer use**: lay OpenAI's own computer-use payload into `~/.codex`, lifted straight out of
   OpenAI's desktop-app DMG.

## Files

| File | Job |
|---|---|
| `CodexSetup.swift` | The `@Observable` setup engine (`CodexSetup.shared`): detection flags, the three actions, the install retry policy, `whatsNeeded()`. |
| `ComputerUseSetup.swift` | Step 3: download the DMG, mount it, locate the payload by shape, `ditto` three trees into `~/.codex`, patch `config.toml`. `isInstalled` is the three-part check. |
| `ComputerUseSkillPatch.swift` | Relaxes the confirmation policy inside the plugin's `SKILL.md` (section-scoped, idempotent, self-healed before every computer-use run). |
| `ComputerUseSpeed.swift` | The Speed vs Intelligence slider value (documented in the CodexCLI doc). |

The install and login mechanics themselves live in `CodexCLI` (`install`, `startLogin`, `loginStatus`).

## The engine (`CodexSetup`)

Two kinds of members:

- **Detection (no side effects):** `installed`, `loggedIn`, `computerUseReady`, refreshed by `refreshInstalled()` (off-main; `locateBinary` can spawn a login shell, so it must never run inside the singleton's initializer), `refreshLoginStatus()` (`codex login status`), `refreshComputerUse()`.
- **Actions (self-guarding):** `installCodex()` ALWAYS runs the installer (update in place; auth and config untouched; a failed update over a working codex reads as "present, update skipped", never an error). `ensureInstalled(attempts: 3)` is the single retry policy (10 s between attempts) and flips `installGaveUp` when the budget is spent so onboarding can show the manual-install panel; both the launch kick in `AppState` and the onboarding screen call it. `startLogin(force:)` opens the browser and returns; the login is noticed by polling `loginStatus` (onboarding and Health both do this; only the dev window keeps a "Finished" button). `setupComputerUse(force:)` no-ops when already bootstrapped and re-probes the disk for the binary first, so a user who installed codex themselves still gets computer use.
- `whatsNeeded()` re-checks all three and returns the pending steps in order.
- Right after a successful computer-use bootstrap, the engine pre-grants the Automation right (Sentient → the helper over Apple Events) via `Permissions.selfHealComputerUseAutomation` (see the System doc), so the first fire never waits on it.

Failures emit `codex_setup.step_failed` (error type only). While the bootstrap runs, `RootView` shows a
quiet "Setting up Codex computer use in the background." whisper on whatever screen is up.

**Where each step runs today:** the CLI installs silently from launch during onboarding; login is the
ChatGPT panel of onboarding's frontier-model step (or Health's inline fix); computer use bootstraps
silently two minutes into onboarding's first analysis (armed when the analysis takeover appears, so its
~535 MB download never races the model download), or from Health → Set up… (which streams its progress
under the row).

## The central discovery behind step 3

Computer use is not downloadable from any standalone endpoint. OpenAI ships the ENTIRE payload (the
plugin AND the native "Codex Computer Use.app" helper) inside their desktop app, and the desktop app's
"enable computer use" toggle is a local file copy into `~/.codex` plus a few `config.toml` lines. This
was established with a filesystem diff of `~/.codex` before/after the toggle, a network capture that
showed no download during it, and a byte-identical hash of the helper against the copy inside the app.
So Sentient downloads the desktop app's public DMG and does the same copy. Nothing is hosted by us.

DMG: `https://persistent.oaistatic.com/codex-app-prod/Codex.dmg` (public CDN, ~535 to 566 MB depending
on release; the app at the DMG root was renamed Codex.app → ChatGPT.app in July 2026, so the bootstrap
locates it by shape, never by name).

## What the bootstrap copies (`ComputerUseSetup.install`)

Source: `<app>.app/Contents/Resources/plugins/openai-bundled/` inside the mounted DMG.

| Destination under `~/.codex/` | Source | Why |
|---|---|---|
| `computer-use/Codex Computer Use.app` | the native helper. It has lived in two places: inside the plugin folder (older payloads) and inside the bundled `@oai/sky` node module (`Contents/Resources/cua_node/lib/node_modules/@oai/sky/`, since plugin 1.0.1000502). `nativeHelper(app:pluginSrc:)` tries both. | The plugin's launcher execs its client, which serves the MCP tools; `config.toml`'s `notify` points at the same client. |
| `plugins/cache/openai-bundled/computer-use/<version>/` | `…/openai-bundled/plugins/computer-use/` (`<version>` from `.codex-plugin/plugin.json`) | The runnable plugin. Its `.mcp.json` registers the `computer-use` MCP server (a 12-line launcher that execs `SkyComputerUseClient mcp` from `$CODEX_HOME`); the tools (`list_apps`, `get_app_state`, `click`, `type_text`, …) are served natively, no node runtime anywhere in the chain. |
| `.tmp/bundled-marketplaces/openai-bundled/` | the whole `openai-bundled` tree | Registers the local marketplace so `codex plugin list` recognizes the plugin. |

Plus three idempotent `config.toml` edits: a top-level `notify = ["<client>", "turn-ended"]` (prepended;
skipped if the user has their own `notify`), `[marketplaces.openai-bundled]` (local source), and
`[plugins."computer-use@openai-bundled"] enabled = true` (appended). Copies use `ditto --noqtn`
(signature- and xattr-preserving, no quarantine), each destination removed first. Only these three
OpenAI-namespaced paths are ever touched; the user's other plugins, skills, `auth.json`, and config
survive.

`isInstalled` requires all three: the helper's Mach-O on disk, a plugin version dir carrying
`plugin.json` + `.mcp.json` + an executable launcher, and the enable block in `config.toml`. Any missing
piece reads "not installed" and gets repaired on the next setup pass; a payload the real desktop app
installed counts too. `force: true` (the dev re-install) replaces everything.

## The confirmation-policy patch (`ComputerUseSkillPatch`)

The plugin's stock `SKILL.md` policy makes the agent stop and ask before everyday actions (sending the
message you dictated, filling the form). A headless run cannot answer, so the action stalls. The human
is already in the loop at the app level: they authored the task, fired it, watch the notch, and hold a
real STOP. So `ensureApplied()` replaces ONLY the policy tail of each real `SKILL.md` (every installed
version's copy plus the marketplace copy), from the anchor heading `# Computer Use Confirmations Policy`
to end of file, with the relaxed policy in the Swift file. It keeps every high-stakes guardrail
verbatim (deleting data, accounts and API keys, installing software, payments and subscriptions,
system settings, medical actions, sensitive-data transmission, and the anti-prompt-injection rule) and
moves "send the message or email the user asked for" to "do it yourself", dropping the CAPTCHA and
browser-safety-barrier rows. Detection is by phrases that exist only in the stock policy; a patched
file contains none, so it is never re-patched; markers present but no anchor means OpenAI restructured
again, and the file is left stock (stricter than wanted beats broken). It runs at install and before
every computer-use run, so a plugin update landing a fresh stock file self-heals on the next command.
The exact policy text is the `relaxedPolicy` constant; the code is the source of truth.

## If OpenAI changes the payload again

Symptoms: the setup fails at "Copying …", `codex plugin list` no longer shows computer-use enabled, or a
real computer-use call errors. Playbook: download and mount the current DMG, look at what moved
(`plugins/openai-bundled`, the helper's location, whether `.mcp.json` still uses relative paths and
`CODEX_HOME`), note the new `plugin.json` version, and update `ComputerUseSetup.swift` (the shape
lookups, the three destinations, `isInstalled`, `patchConfig`). The reliable shortcut is to install the
current desktop app once, enable computer use, and diff its `~/.codex` output against ours; the desktop
app's output is the ground truth we mirror. The plugin's MCP server can also be smoke-tested without
codex by piping `initialize` → `tools/list` JSON-RPC into `bin/computer-use-client-launcher mcp` with
`CODEX_HOME` pointed at a staging dir holding just the helper.

macOS re-asks for the helper's Screen Recording after a helper update (the TCC grant survives, but the
capture layer wants a fresh Allow once). Invisible to our status reads; the user clicks Allow.

## Rules

- Detection first: never install over a user's own codex, never re-download an existing computer use.
- Never overwrite the whole `SKILL.md`; the head of the file must survive.
- The bootstrap writes no TCC. macOS grants are `System/Permissions.swift` and the permission gate's job.

## Related docs

`Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md`, `System/Documentation - System (Permissions, Health, Uninstall).md` (the Automation grant and the helper's TCC status), `Views/Permissions/Documentation - Permission Gate & Guide.md`, `Views/Onboarding/Documentation - Onboarding.md`.
