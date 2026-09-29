# The Cua Driver (Driver/): the hands and eyes of computer use

CUA powers computer use for Claude and custom endpoints. It is the pinned open-source driver from
[trycua/cua](https://github.com/trycua/cua), embedded as Sentient's own daemon. Its background native
window input, cursor overlay, four MCP vision tools, CLI shim and manual remain shared by those two
CLI paths. ChatGPT uses the separate OpenAI helper described in `Documentation - Native Computer Use.md`.

## Files

| File | Job |
|---|---|
| `CuaDriver.swift` | The driver as Sentient sees it: the pinned release (version, tarball URL, SHA-256, signing team), the install location, the MCP tool subset (`mcpTools`), the per-engine wiring (codex `-c` overrides · claude `--mcp-config` JSON + the named deny list), the CLI shim + screenshot paths, the full tool allowlist (`enabledTools`), and versioned installation history. |
| `CuaDriverHost.swift` | The daemon's lifecycle: spawn, readiness, liveness, replacement on permission changes, teardown. Also writes the per-generation CLI shim. |
| `CuaDriverSetup.swift` | Puts the pinned binary on disk: download → SHA-256 → extract → codesign verify → smoke run → atomic install. |
| `CuaDriverSkill.swift` | The operating manual spliced into every computer-use prompt — the model's teaching for the whole tool surface. |

## Why Sentient hosts the daemon itself

macOS TCC attributes Accessibility and Screen Recording to the *responsible process* — the app at the
top of the launch chain. `CuaDriverHost` spawns `cua-driver serve --embedded` as a DIRECT child (never
through `open` or NSWorkspace, which would hand the daemon to LaunchServices and its own identity), so
macOS answers the daemon's permission checks with **Sentient's own grants**. The user grants
Accessibility and Screen Recording twice, to the app they already trust, and no second helper ever
appears in System Settings. The daemon also owns the AppKit runloop that renders the agent cursor —
the reason this shape is worth its lifecycle code over a per-run `mcp --direct` process.

Daemon shape (one per app lifetime, an actor so racing fires can't spawn two):

- `serve --embedded --socket <fresh per-generation path in the temp dir>` with a curated environment.
  `--permission-mode standard` and no launch grant (the only grant the driver accepts unlocks its
  typed browser route, which is off; without it the daemon refuses that attachment outright),
  `--no-permissions-gate` (Sentient owns the permission UX), and a 420 ms cursor glide so the
  overlay reads as motion.
- `--parent-liveness-stdio` + a held stdin pipe: if Sentient dies, the daemon dies with it — no orphan
  ever left holding the user's grants.
- stdout and stderr both use `FileHandle.nullDevice`. Shutdown logging stays writable after the parent exits, so EOF cleanup can finish. There is no parent-owned stderr drain or recent-lines buffer; host lifecycle logs remain, raw daemon stderr is discarded.
- The environment pins the driver's product telemetry and its daily update check OFF. Not optional:
  neither belongs on a user's machine on our behalf.
- The socket appearing on disk is the readiness signal; liveness is a real `status` probe over the
  socket (a wedged daemon that still holds a pid must read as dead). When the user's grants change,
  the daemon is REPLACED, not re-probed — macOS caches TCC answers per process.

## Shutdown and orphan cleanup

The stdin lifeline remains the primary shutdown signal; stderr stays attached to the null device so
shutdown logging can finish after the parent exits. Two additional backstops handle a daemon whose
AppKit runloop outlives its server. A normal process exit sends SIGTERM to the last owned daemon after
checking its executable path. Launch-time `sweepOrphans()` recognizes managed daemon commands and the
host PID in their socket names, spares live Sentient hosts and standalone CuaDriver installations,
and removes orphan processes and stale sockets. The sweep uses TERM, a short grace, then KILL.

This startup work stays behind `SENTIENT_SELFTEST`. Lifecycle tests must use an isolated install root,
temporary directory, and owned process receipts; never exercise a global sweep against user processes.

## The hybrid transport: MCP eyes, CLI hands

A computer-use codex run reaches the daemon over two channels against the same socket:

- **The eyes ride MCP.** `CuaDriver.codexOverrides` registers a thin `cua-driver mcp --embedded
  --socket …` proxy with codex, filtered by `enabled_tools` to exactly the four vision tools
  (`mcpTools`: `get_window_state`, `get_desktop_state`, `zoom`, `verify_state`). Every look is one
  call with the screenshot arriving inline as a real image, and only four schemas load. Action schemas stay out of the initial context. The proxy executes nothing
  itself; `required=true` fails the run rather than leaving the model blind, and the tool timeout is
  raised to 120 s (a big window's snapshot outlives codex's 60 s default). The Claude engine
  registers the SAME proxy via `CuaDriver.claudeMcpConfig` (`--mcp-config` + `--strict-mcp-config`);
  Claude Code has no per-server `enabled_tools` filter, so the trim is
  `claudeDisallowedMcpTools` — every non-vision MCP tool denied by name, version-pinned like the
  skill — and the timeouts ride env vars (`MCP_TIMEOUT`, `MCP_TOOL_TIMEOUT`).
- **The hands ride the CLI.** Every action runs as a one-shot shell call,
  `<shim> <tool> '<json>'` — upstream's own default transport — without loading action schemas up front. The shim lives
  at a deliberately SPACE-FREE path under the app's caches dir (the real binary sits under
  "Application Support", a per-call quoting hazard for an LLM writing shell), bakes in the current
  generation's `--socket` (placed first, so it always wins), and pins the same privacy environment.
  `CuaDriverHost` rewrites it on every daemon generation; the path itself is stable, so prompts can
  reference it before the run starts.

The two channels share one engine: the element cache is daemon-owned and keyed on `(pid, window_id)`,
so an `element_token` read over MCP fires directly in a CLI `click`. Codex runs hermetic
(`--ignore-user-config`) and with the sandbox bypassed — the Seatbelt profile would block the daemon's
Unix socket, and a headless run has no one to answer approvals; safety rides the app's own layers
(one declared task, user-fired only, live streaming, a universal STOP).

## The inlined manual (`CuaDriverSkill`)

`CuaDriverSkill.rules` is curated from the pinned release's MIT-licensed SKILL.md and MACOS.md.
`FrontierRun` adds it once to CUA tasks after capturing the selected engine.
It identifies the skill as already loaded, so the model does not fetch another copy through MCP
resources or read a skill file. Action schemas remain available through CLI `describe` only when
needed.

The manual teaches the two transports, snapshot-bound targets, background delivery, browsers as
native windows, and verification. In code-mode clients, the model must expose `structuredContent` handles and
the inline image together, omitting the duplicate Markdown tree. A shell exit code of zero does not
prove an action succeeded: structured refusals and action facts must be read before continuing.
The pinned 0.20.0 snapshot always walks accessibility; it does not support the newer
`include_accessibility_tree` switch. Visual outcomes are verified from a fresh image.

The driver pin, `skillVersion`, and `toolCatalogVersion` must match. Every Debug and Release build runs
`Scripts/check_cua_contract.py`, which also checks the four-tool MCP boundary and allowlist membership.
The manual retains a runtime precondition. These checks enforce version consistency; updating the
text and checking the live release's behavior remain part of reviewing a pin change.

## Installation and ordinary updates

Each Sentient release selects one tested CUA release, currently **0.20.0**. It downloads that exact
bare-binary tarball from Cua's release assets into a staging directory under
`~/Library/Application Support/SentientOS/CuaDriver/`. CUA is not bundled in the app, and Sentient does
not use Cua's standalone installer or change the user's shell PATH.

Installation checks SHA-256, Cua's signing identity, and the exact `--version` response before an atomic
rename into `<version>/cua-driver`. Only then are previous installed versions swept. A failed or
interrupted download leaves the previous binary intact. Local verification processes have deadlines
and honor cancellation; telemetry and upstream update checks are disabled there too.

`ComputerUseSetup` owns the shared CUA installation task for Claude and custom endpoints. Existing CUA users whose
required version is missing get a background update after launch. The home's top-right notice shows
actual download progress, an indeterminate verification phase, completion, or a retry action. The rest
of Sentient remains usable. Computer-use commands join the same download; STOP cancels their wait
without canceling the background update. The new app requires its pinned runtime and does not silently
pair the new manual with an older binary. Uninstall cancels and drains an installer before deleting its
files.

The required pin is authoritative in both directions: a deliberate rollback from 0.28.2 to 0.20.0
uses the same verified background installation, completion notice, and receipt. It does not replay
the Codex-to-CUA migration. The 0.20.0 rollback restores its original curated tool contract while
retaining the explicit inlined-skill notice, safe shell quoting, structured MCP handles, final-result
verification, and the host-owned lifecycle confirmed against that binary. The independent Debug
Sparkle guard remains in place.

A `.installed-version` receipt, plus detection of earlier installed version directories, distinguishes
an existing CUA setup from the legacy Codex helper. Launch adopts older installations that predate the
receipt. The receipt survives a missing binary and Factory Reset, and Uninstall removes it with the
managed directory. Fresh users retain onboarding. Users with the old Codex helper and no CUA history
retain the explicit migration window described in the Permission Gate doc.

## Per-command lifecycle

Both CUA-backed CLI paths ask `CuaDriverHost` to start or revive the CLI label `sentient` before running
the model. They await its cleanup after success, failure, or STOP before releasing the command. This
releases the action cursor owned by that run. The host checks the
structured lifecycle result, not just the subprocess exit code. The model never manages sessions.
Pending cleanup is polled with a deadline before the task lock is released. If cleanup cannot finish, only the owned daemon is stopped so the next task starts a fresh generation. The daemon otherwise stays warm across commands.

For pinned 0.20.0, explicitly named CLI calls share their daemon's CLI namespace. Anonymous one-shot
calls are disposable. The separate MCP connection provides the native vision tools.

## Browsers are native windows

A browser window is driven like any other app: `get_window_state` returns the page's accessibility
tree and screenshot, and the model acts through the same ax/px ladder, in the user's own logged-in
browser. The driver's typed browser route (`browser_prepare`, `get_browser_state`, `browser_*`) is
deliberately off: no launch grant on the daemon, none of those tools in the allowlist, and the
manual teaches the native route instead (2026-09-20).

The reason is Chrome's own design. Chrome 136 and later ignores the remote-debugging flag on the
user's real profile, so the only way into a logged-in Chrome over CDP is the per-instance toggle at
`chrome://inspect/#remote-debugging`, which the driver flips by opening a tab in the user's browser
and typing into it. In that mode Chrome activates its window and shows an "Allow remote debugging?"
dialog on every new debugging connection, with no way to remember the answer and no policy to
silence it, and it adds the "controlled by automated test software" bar while a connection is open.
The toggle also persists in Chrome's Local State despite its label. On the pinned release the
dialog's Allow button is not matched on current Chrome (its title and description repeat the same
word; upstream #3705), so the dialog is left for the user. None of that belongs in a run the user
did not ask to watch, so the route stays off regardless of driver version.

What the manual teaches for web pages: open URLs with `launch_app` + `urls` (a new tab, no focus
steal; never the address bar or ⌘L / ⌘T), bound big page trees with `query` / `max_elements`,
re-snapshot once when Chrome's first page tree is sparse, click links and buttons by element token,
type into web fields with the px form of `type_text` (the driver never trusts an accessibility
write into web content), and treat page dialogs, permission bubbles, and the address bar as native
surfaces of the same window. What is lost: exact page refs and the semantic page outline, which
matter mostly on very dense pages.

## Sharp edges (each one field-found; do not re-learn them)

- **Bump the release as one reviewed change:** update version, tarball checksum/size, the curated
  manual, and the captured MCP catalog/version. Compare `cua-driver list-tools` with
  `python3 Scripts/check_cua_contract.py . --tool-list <capture.txt>`, then exercise the native ladder
  on an ordinary app and on a browser window, plus the existing-user update paths. A matching version string alone is
  not a compatibility test.
- **The typed browser route stays off** (see "Browsers are native windows"): no `--grant` on the
  daemon, no `browser_*` tool in `enabledTools`. `Scripts/check_cua_contract.py` fails the build on
  either. A future driver version that handles Chrome's dialog better does not change this: the
  dialog itself is the problem.
- **The MCP eyes refuse a `session` argument** ("session is not available to this transport") — the
  skill text tells the model to omit it there, and to pass it on every shell call.
- **A capability manifest is not an allowlist.** It is the driver's bounded permission mode with its
  own review burden. The `enabledTools` trim is prompt-enforced, same posture as the old MCP
  `enabled_tools`; the one hard gate that matters (the profile attachment) is the missing launch
  grant.
- **A sandboxed shell cannot reach the daemon's socket** — one more reason computer-use runs require
  the bypass flag.

## Rules

- The daemon is the ONLY runtime owner: never `mcp --direct`, never `open`/NSWorkspace for any driver
  process, never a second daemon.
- Nothing is ever written into the user's own `~/.codex` config; the MCP registration is per-run `-c`
  overrides.
- The driver's telemetry and update checks stay off in every spawned process (daemon, proxy, shim).
- `mcpTools` is the vision set and nothing else; action tools are taught by the skill, not loaded as
  schemas.
- No launch grant on the daemon and no `browser_*` tool in the allowlist: web pages are native
  windows.

## Related docs

`Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md` and
`Cloud/Documentation - Cloud - ClaudeCLI (the claude -p engine).md` (the runs that drive this),
`Cloud/Documentation - Cloud - Codex Setup.md` (the setup flow this is step 3 of),
`Views/Permissions/Documentation - Permission Gate & Guide.md` (how the two grants are acquired),
`System/Documentation - System (Permissions, Health, Uninstall).md` (probes, health, teardown),
`Notch Magic/Documentation - Sidekick - General.md` · `Proactive/Documentation - Proactive Intelligence.md` (the two callers).
