# The Cua Driver (Driver/): the hands and eyes of computer use

How Sentient acts on the Mac. The driver is [cua-driver](https://github.com/trycua/cua) (MIT, by Cua
AI): one self-contained binary that clicks, types, scrolls, reads accessibility trees, and takes
per-window screenshots IN THE BACKGROUND — per-window input with no cursor warp and no focus steal,
plus a typed route into Chromium pages over CDP and a visible agent-cursor overlay so the user can see
where their agent is working. Sentient runs it as its own long-lived daemon and lets each computer-use
run drive it — codex or claude, whichever engine is live (FrontierRun dispatches; the daemon, socket,
shim, and skill are identical for both). The frontier model is the brain; this folder is the body.

## Files

| File | Job |
|---|---|
| `CuaDriver.swift` | The driver as Sentient sees it: the pinned release (version, tarball URL, SHA-256, signing team), the install location, the MCP tool subset (`mcpTools`), the per-engine wiring (codex `-c` overrides · claude `--mcp-config` JSON + the named deny list), the CLI shim + screenshot paths, and the full tool allowlist (`enabledTools`). |
| `CuaDriverHost.swift` | The daemon's lifecycle: spawn, readiness, liveness, replacement on permission changes, teardown. Also writes the per-generation CLI shim and screenshot drop-box. |
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
  `--permission-mode standard`, `--grant existing-profile` (the one launch grant the driver accepts:
  binding to the user's already-logged-in Chrome; a tool call can never ask for it, which is exactly
  why it must be decided here), `--no-permissions-gate` (Sentient owns the permission UX), and a
  420 ms cursor glide so the overlay reads as motion.
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
  call with the screenshot arriving inline as a real image, and the schema cost is ~3k tokens —
  the expensive schemas belong to the action tools, which never load. The proxy executes nothing
  itself; `required=true` fails the run rather than leaving the model blind, and the tool timeout is
  raised to 120 s (a big window's snapshot outlives codex's 60 s default). The Claude engine
  registers the SAME proxy via `CuaDriver.claudeMcpConfig` (`--mcp-config` + `--strict-mcp-config`);
  Claude Code has no per-server `enabled_tools` filter, so the trim is
  `claudeDisallowedMcpTools` — every non-vision MCP tool denied by name, version-pinned like the
  skill — and the timeouts ride env vars (`MCP_TIMEOUT`, `MCP_TOOL_TIMEOUT`).
- **The hands ride the CLI.** Every action and the entire browser family run as one-shot shell calls,
  `<shim> <tool> '<json>'` — upstream's own default transport — at zero schema cost. The shim lives
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

## The skill (`CuaDriverSkill`)

With no action schemas in context, the model's only teaching is `CuaDriverSkill.rules`: an operating
manual curated from cua-driver's own MIT-licensed agent skill pack (SKILL.md + MACOS.md + BROWSER.md
in the upstream repo), adapted for Sentient — the two-channel transport, a fixed `"session"` label on
every shell call, the snapshot → act → verify loop, element-token staleness, the ax/px addressing
model, the background-first delivery ladder, the no-foreground law with its forbidden-command list,
Electron/Catalyst text-input truth, and the typed browser route. Both computer-use prompts (Sidekick's
command prompt and the executor's computer wrapper) splice it in. `skillVersion` must equal
`CuaDriver.version` — an assert trips at build time if the pin bumps without re-curating the text.

## Install and pinning (`CuaDriverSetup`)

The release is PINNED (upstream ships breaking changes at a high cadence, so "latest" is never an
option; each Sentient release carries the one driver version it was tested against). Setup downloads
the bare-binary tarball straight from Cua's GitHub release (~40 MB — deliberately not their installer,
which drops a CuaDriver.app into /Applications, edits the shell PATH, and fires install telemetry),
then verifies harder than upstream does: SHA-256 against our pin, a codesign requirement naming Cua
AI's Apple Developer team (so we run their signature or nothing), a `--version` smoke run, and an
atomic move into `~/Library/Application Support/SentientOS/CuaDriver/<version>/` before older versions
are swept. Any failure leaves the previous install untouched.

It rides as step 3 of the Codex setup engine (`CodexSetup.setupCuaDriver`; onboarding arms it in the
background two minutes into the first analysis), with `ensureCuaDriver()` as the fire-time self-heal.
Macs updating from the 1.x codex-helper era get the one-time `ComputerUseUpgrade` window instead of a
silent download (see the Permission Gate doc).

## Sharp edges (each one field-found; do not re-learn them)

- **Bumping the pin is a three-part edit:** the version + fresh `tarballSHA256` in `CuaDriver.swift`,
  a re-curated `CuaDriverSkill` (the upstream skill pack changes with the binary), and a real test
  pass. The `skillVersion` assert exists to make forgetting impossible.
- **The browser family is single-transport by design.** Browser targets, tabs, and refs are
  session-scoped, and the daemon deliberately namespaces a named session per transport kind — refs
  minted over MCP would be foreign to a CLI `browser_click`. Everything browser therefore stays on
  the CLI, sharing one `"session"` label. Do not move `get_browser_state` onto MCP.
- **The MCP eyes refuse a `session` argument** ("session is not available to this transport") — the
  skill text tells the model to omit it there, and to pass it on every shell call.
- **A capability manifest cannot replace the tool allowlist.** A manifest also origin-pins
  `browser_navigate` in every permission mode, and Sentient's tasks go to arbitrary URLs. The
  `enabledTools` trim is therefore prompt-enforced, same posture as the old MCP `enabled_tools`.
- **Screenshot output paths must not sit under the `/tmp` symlink** — the driver's output-path check
  refuses a symlinked ancestor. The shots drop-box lives under the app's caches dir (a real
  directory), which also puts it inside Uninstall's existing sweep; the host wipes it every
  generation because the frames are content-bearing.
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

## Related docs

`Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md` and
`Cloud/Documentation - Cloud - ClaudeCLI (the claude -p engine).md` (the runs that drive this),
`Cloud/Documentation - Cloud - Codex Setup.md` (the setup flow this is step 3 of),
`Views/Permissions/Documentation - Permission Gate & Guide.md` (how the two grants are acquired),
`System/Documentation - System (Permissions, Health, Uninstall).md` (probes, health, teardown),
`Notch Magic/Documentation - Sidekick - General.md` · `Proactive/Documentation - Proactive Intelligence.md` (the two callers).
