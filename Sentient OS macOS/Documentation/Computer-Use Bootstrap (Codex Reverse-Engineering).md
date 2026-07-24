# Computer-Use Bootstrap — Reverse-Engineering Codex & the Copy Logic

**What this is:** the canonical reference for how Sentient makes Codex **computer use** work on a *plain
Codex CLI* — with no Codex desktop app install — and, more importantly, **how that was reverse-engineered
and how to re-derive it when OpenAI changes things.** If the copy-in logic ever breaks, start here.

Implementation: `ComputerUseSetup.swift` (the bootstrap), `CodexSetup.swift` (step 3 of the flow),
`CodexSetupView.swift` (the dev button). Onboarding usage: `Codex Setup Handoff (Onboarding).md`.

> Values like the DMG size, plugin version, and sha256s in this doc are **snapshots from the June 2026
> teardown** (Codex.app 26.623.42026, computer-use plugin 1.0.857), updated for the **July 2026
> ChatGPT-app rename** (§1.5) and the **late-July pure-MCP restructure** (§1.6). They WILL drift. The
> *method* is what stays true — §4 and §5 are the parts that matter long-term.

---

## 1. The central discovery (read this first)

**Computer use is NOT downloaded from any standalone OpenAI endpoint.** OpenAI ships the *entire*
computer-use payload — the plugin **and** the native `Codex Computer Use.app` helper — **bundled inside the
Codex desktop app**, at `Codex.app/Contents/Resources/plugins/openai-bundled/`. The desktop app's "enable
computer use" toggle is just a **local file copy** into `~/.codex` + a few lines in `config.toml`.

Proven two ways during the teardown:
- **Byte-identical:** the `SkyComputerUseService` binary that lands in `~/.codex` has the *same sha256* as
  the copy already inside the installed `/Applications/Codex.app`.
- **Zero network:** a full TLS-intercepting capture (mitmproxy) + raw `tcpdump` during the toggle showed
  **no download of the payload** — and the string `computer-use` appeared in **zero** network response
  bodies. `fs_usage` caught a `Python` helper copying the files straight out of the app bundle.

**Consequence:** the only OpenAI-hosted source of the computer-use bits is the **Codex desktop app DMG
itself**. So Sentient downloads that DMG, lifts the bundled payload out, and lays it into `~/.codex` —
exactly what the desktop toggle does, just without making the user install the desktop app. Nothing is
hosted by us.

```
Official, public, no-auth CDN URL (found in the codex CLI binary's strings):
    https://persistent.oaistatic.com/codex-app-prod/Codex.dmg
    (≈535 MB · Cloudflare · application/x-apple-diskimage · override via `codex app --download-url`)
```

---

## 1.5 The July 2026 update: the ChatGPT app rename, skill variants, and the two runtimes

OpenAI merged the Codex desktop app into the new **ChatGPT desktop app** (2026-07). Same DMG URL,
but four things changed — all verified against a real desktop-app install on 2026-07-09 and re-verified
end-to-end after a full wipe:

1. **The app at the DMG root is now `ChatGPT.app`** (was `Codex.app`). The bootstrap no longer
   hardcodes the name: `marketplace(inMount:)` scans the DMG root for any `.app` and keys on the
   payload's shape (`Contents/Resources/plugins/openai-bundled` existing), so the next rename can't
   break it.

2. **The plugin shipped skill VARIANTS** *(transition era — superseded by §1.6)*. The
   `skills/computer-use/SKILL.md` inside the payload is a policy-only stub; a node-repl skill
   (runtime bootstrap + API docs + the confirmation policy) sits beside the manifest as
   `.codex-plugin/computer-use-node-repl.md`. The desktop app's enable flow **swapped the variant in**
   as `SKILL.md` (in BOTH the plugin-cache and marketplace trees) and stamped
   `"bundledContentVariant": "node-repl"` into both `plugin.json` copies; our bootstrap reproduced
   that byte-for-byte until 2026-07-24 (`selectNodeReplVariant`, since deleted). On node_repl-era
   CLIs a plain ditto without the swap left codex with no runtime instructions and it flailed
   (`js_add_node_module_dir` roulette in the logs). **Since §1.6 the stub IS the correct CLI skill —
   don't reintroduce the swap.**

3. **The client shipped TWO runtimes, and the CLI picked at launch** *(transition era — superseded
   by §1.6)*. `SkyComputerUseClient` carries `CODEX_COMPUTER_USE_MCP_RUNTIME_NODE_REPL` and
   `…_LEGACY_MCP` flags:
   - **node_repl mode** (seen on codex v0.142.5): the MCP server exposes a generic JavaScript REPL
     (`node_repl/js`, `js_reset`, `js_add_node_module_dir`); the model imports the plugin's wrapper
     (`scripts/computer-use-client.mjs` → `setupComputerUseRuntime()`) and drives a `sky.*` JS API.
     The JS is hosted **in-process via WebKit** — no node binary needed on the Mac (measured: works
     on a machine with zero node installs).
   - **legacy/direct mode** (seen on codex v0.144.1): the classic direct MCP tools
     (`computer-use/get_app_state`, `click`, …) — faster for simple commands (no bootstrap round trips).
   The runtime choice was the CLI's, independent of the static skill file — v0.144.1 even ignored the
   `bundledContentVariant` stamp, and both runtimes were verified working with our bootstrap output.
   §1.6 resolved the split by surface: the CLI is direct-tools only now; node_repl became the desktop
   app's arm.

4. **macOS re-asks for the helper's Screen Recording after updates.** The TCC grant itself survives
   (same bundle id `com.openai.sky.CUAService`, same signing), but replacing the helper binary triggers
   macOS's screen-capture **re-approval popup** (the `replayd` layer) on the next capture. It's invisible
   to TCC reads — the health rows show granted while capture silently waits — undetectable and
   unpreventable by us; the user clicks Allow once. Don't chase this ghost.

The confirmation-policy patch also changed shape with this update — see
`Computer-Use Skill Patch (Confirmation Policy).md` (now section-scoped and automated).

---

## 1.6 The late-July 2026 update: the pure-MCP plugin + the relocated helper

Plugin **1.0.1000502** (seen 2026-07-24; same DMG URL) resolved §1.5's runtime split by SURFACE —
and moved a file the bootstrap copies. All four changes below were verified against the live DMG and
end-to-end on hardware (2026-07-24):

1. **The native helper moved out of the plugin folder.** `Codex Computer Use.app` now ships inside
   the bundled `@oai/sky` node module:
   `<app>.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app`.
   The bootstrap resolves it by shape (`nativeHelper(app:pluginSrc:)`): the old in-plugin location
   first, then the `@oai/sky` location — so both DMG generations install. (Field signature of the
   old hardcoded path meeting the new DMG: `ditto: Cannot get the real path for source
   …/plugins/computer-use/Codex Computer Use.app` at the "Copying native helper" step.)

2. **The plugin is pure MCP on the CLI.** It now ships `.mcp.json` + `bin/computer-use-client-launcher`
   + `scripts/computer-use-client.mjs`. `.mcp.json` registers a `computer-use` MCP server whose
   command is the launcher — a 12-line sh script that execs the INSTALLED helper's client,
   `$CODEX_HOME/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/
   Contents/MacOS/SkyComputerUseClient mcp` — and the client serves the direct tools natively
   (`list_apps`, `get_app_state`, `click`, `type_text`, `press_key`, `scroll`, `drag`, `select_text`,
   `set_value`, `perform_secondary_action`). **No node runtime exists anywhere in the CLI chain** —
   proven by speaking MCP over stdio to the launcher with ONLY the helper staged under `CODEX_HOME`:
   full handshake, all 10 tools served.

3. **The node-repl variant is the desktop app's arm now — the swap is RETIRED.** The desktop app
   spawns a `node_repl` MCP server out of its own bundled `cua_node/` runtime (paths aimed into its
   app bundle, used in place — extracted from its app.asar) and still swaps the variant in for its
   own sessions. Current CLIs (0.145.0+) carry **no node_repl runtime at all**, so a swapped-in
   node-repl skill would point codex at a tool that doesn't exist. The bootstrap keeps the shipped
   policy-only stub (`selectNodeReplVariant` deleted), and `isInstalled` keys on the MCP shape —
   manifest + `.mcp.json` + launcher — so a node-repl-era install reads "not installed" ON PURPOSE
   and the existing Health → Set up flow migrates it to the new payload.

4. **`ditto` runs with `--noqtn`** — matching the desktop app's own copy call (it does exactly
   `ditto --noqtn <source> ~/.codex/computer-use/Codex Computer Use.app`), so no quarantine xattrs
   ride into `~/.codex`.

---

## 2. What we copy, where, and why (the bootstrap spec)

Everything comes from one source subtree in the mounted DMG:
`/<mount>/<app>.app/Contents/Resources/plugins/openai-bundled/` (the app is `ChatGPT.app` since
2026-07, `Codex.app` before — located by shape, never by name; §1.5)

| Dest under `~/.codex/` | Source | Why it's needed |
|---|---|---|
| `computer-use/Codex Computer Use.app` | in-plugin (pre-1.0.1000502) **or** `<app>/Contents/Resources/cua_node/lib/node_modules/@oai/sky/` (since) — resolved by shape, §1.6 | The native helper. The plugin's launcher execs its client (`SkyComputerUseClient mcp` — the MCP server), and the `notify` line in `config.toml` points at the same client. |
| `plugins/cache/openai-bundled/computer-use/<version>/` | `…/openai-bundled/plugins/computer-use/` | **The runnable plugin.** Its `.mcp.json` registers the MCP server that *is* computer use. `<version>` = the `version` field in `plugins/computer-use/.codex-plugin/plugin.json` (e.g. `1.0.1000502`). |
| `.tmp/bundled-marketplaces/openai-bundled/` | the whole `…/openai-bundled/` tree | Registers the marketplace so `codex plugin list` recognises the plugin as installable/installed. Must contain `.agents/plugins/marketplace.json`. |

Plus three `config.toml` blocks (paths are absolute, built from the user's real home):

```toml
# top-level key — MUST come before any [table], so it's PREPENDED
notify = ["<home>/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient", "turn-ended"]

[marketplaces.openai-bundled]
source_type = "local"
source = "<home>/.codex/.tmp/bundled-marketplaces/openai-bundled"

[plugins."computer-use@openai-bundled"]
enabled = true
```

**The toggle's *exact* delta is tiny:** in the teardown, clicking "enable computer use" added only the
`[plugins."computer-use@openai-bundled"] enabled = true` block — everything else (`notify`,
`[marketplaces.openai-bundled]`, the `computer-use/` native app) was written earlier, at desktop-app
**install/first-launch**, not at the toggle. We do it all in one shot.

**No variant swap (retired 2026-07-24, §1.6):** the shipped policy-only `SKILL.md` is the correct CLI
skill — the node-repl variant is the desktop app's arm. After the copies, only the confirmation-policy
patch is applied (`ComputerUseSkillPatch.ensureApplied()` — its own doc).

### Why the plugin is portable (important)
Since 1.0.1000502 the plugin's `.mcp.json` runs a **relative** launcher that resolves the helper via
`CODEX_HOME` (default `~/.codex`):
```json
{ "mcpServers": { "computer-use": {
    "command": "./bin/computer-use-client-launcher",
    "args": ["mcp"], "cwd": ".", "env_vars": ["CODEX_HOME"] } } }
```
(The pre-1.0.1000502 `.mcp.json` execed the client relatively from INSIDE the plugin dir — the helper
shipped in the plugin then.) There are **zero `/Applications/…` references** inside the plugin or the
native app. That's why a copy-into-`~/.codex` works with no path rewriting. **Re-verify this if things
change** (§5) — if OpenAI switches to absolute paths, the copy alone won't be enough.

### What we deliberately DON'T copy
- **`cua_node/`** (`<app>.app/Contents/Resources/cua_node`) — the desktop app's own bundled Node 24
  runtime (`@oai/sky`, playwright, tesseract, a `node_repl` binary), used in place from its bundle for
  the desktop's node_repl sessions. The CLI's computer use does **not** need it (§1.6 — the MCP chain
  is fully native, proven with only the helper staged). We lift ONLY the `Codex Computer Use.app`
  nested inside it.
- **`~/.codex/tmp/`** (no dot) — volatile execve-wrapper scratch (symlinks to the codex binary). Transient.
- **`plugins/cache/openai-curated-remote/…`** (gmail, gcal, github, …) — unrelated, network-installed plugins.

### What we DON'T touch (safety)
We only remove-and-replace the three OpenAI-namespaced paths above, and we **append** to `config.toml`
(never overwrite). A user's other plugins, `~/.codex/skills/`, other marketplaces, `auth.json`, sqlite
state, and existing config are all preserved. If the user already set their own top-level `notify`, we
skip ours rather than clobber it.

### macOS permissions (out of scope here)
Copying files does **not** grant Accessibility / Screen Recording. The native helper needs them at runtime;
the desktop app uses an `Installer.app` / `CodexComputerUseAuthorizationPlugin` for that. In Sentient this
is handled separately (`Permissions.grantComputerUseAutomation()` writes the Automation TCC row; the rest
is onboarding UX). The bootstrap intentionally writes no TCC. (Since 2026-07 the SETUP ENGINE self-heals the Automation grant right after install — `CodexSetup` → `Permissions.selfHealComputerUseAutomation` — still via Permissions, never in the bootstrap itself.)

---

## 3. How we copy (implementation: `ComputerUseSetup.swift`)

`install(force:onLine:)` runs the whole flow, streaming human-readable progress:
1. **Download** the DMG via `URLSession` (a small `URLSessionDownloadDelegate` reports % progress).
2. **Mount** read-only: `hdiutil attach <dmg> -nobrowse -readonly -mountpoint <tmp>`.
3. **Locate** the payload by shape (`payloadSource(inMount:)` — any `.app` at the DMG root carrying
   `Contents/Resources/plugins/openai-bundled`; name-agnostic since the ChatGPT rename) and the native
   helper by shape too (`nativeHelper(app:pluginSrc:)` — in-plugin first, then `@oai/sky`; §1.6).
4. **Extract** each of the 3 trees with **`ditto --noqtn`** (not `cp`) — `ditto` preserves the code
   signatures and extended attributes of the signed `.app` bundles; `--noqtn` matches the desktop app's
   own copy. Each dest is removed first, then copied (clean replace).
5. **Apply the confirmation-policy patch** (`ComputerUseSkillPatch.ensureApplied()`). No variant swap
   (§1.6).
6. **Patch** `config.toml` idempotently (prepend `notify`, append the two tables, each only if its marker
   is absent).
7. **Clean up:** `hdiutil detach` and delete the ~566 MB DMG — both via `defer`, so they run on every exit
   path (success or throw).

**Idempotency / repair:** `ComputerUseSetup.isInstalled` is a 3-part AND — (a) the native Mach-O exists
(`…/SkyComputerUseService`, not just the `.app` dir → catches a half-copy), (b) a plugin version dir with
its `plugin.json` AND the MCP shape (`.mcp.json` + an executable `bin/computer-use-client-launcher` — a
node-repl-era install lacks these and reads "not installed" ON PURPOSE, so it self-migrates; §1.6),
(c) `config.toml` contains the enable block. All true → skip (no wasteful re-download), including an
install done by the *real* desktop app. Any missing → it re-runs and repairs. `force: true` (the
"Re-install" button) bypasses the skip for a clean replace.

**Idempotent config-patch detail:** the top-level `notify` key must precede any `[table]` in TOML, so it's
*prepended*; the two tables are *appended*. Each is guarded by a `contains`/regex check so re-runs don't
duplicate or corrupt the file.

---

## 4. How it was reverse-engineered (the methodology) — **the part that matters most**

The whole thing was derived with a **two-pronged "snitch" setup**: watch the network, and diff the
filesystem, while the desktop app's toggle runs. The filesystem diff is the source of truth; the network
capture was used to *prove there was no download* (and would find the endpoint if there ever is one).

### The toolkit (built on Aditya's Mac at `~/codex-cu-capture/`)
Re-creatable from scratch; here's what each piece is:
- **`cucap.py`** — `snapshot <root> <out>` writes `sha256<TAB>size<TAB>relpath` for every file under a dir;
  `diff <before> <after>` prints ADDED / MODIFIED / DELETED, separating real signal from churn
  (sqlite/wal/cache/`.tmp`).
- **`analyze.py`** — groups a snapshot diff by top-level folder (file counts + sizes), and can list every
  added/modified file under a given prefix. This is what revealed "the toggle adds `plugins/` + a transient
  `tmp/`, and `computer-use/` appeared at app-install."
- **`arm.sh` / `disarm.sh` / `report.sh` / `flowdump.py`** — the network capture rig: trusts a
  **mitmproxy** CA, routes Wi-Fi through `mitmproxy` (full TLS interception → real URLs + bodies), plus a
  raw **`tcpdump`** SNI capture as insurance, plus **`fs_usage`**. `report.sh` parses captured flows and
  saves response bodies. ⚠️ These rewrite the system proxy + trust a root CA — `disarm.sh` restores
  everything; **never pipe `disarm.sh` through `head`** (SIGPIPE killed it mid-restore once and left the
  proxy pointing at a dead mitmproxy → no internet until manually reset).

### The protocol (3-snapshot method — re-run this verbatim to re-derive)
1. **Cold slate:** fully remove Codex CLI + `Codex.app` + `~/.codex`; install **only the plain Codex CLI**
   and `codex login`.
2. **`before`** snapshot: `cucap.py snapshot ~/.codex before.snap` (also save a copy of `config.toml`).
3. Install the **Codex desktop app** + log in; navigate to the computer-use toggle but **don't click**.
   Take the **`mid`** snapshot. (This isolates "what the app install does" from "what the toggle does".)
4. Start `fs_usage` (filesystem trace). Click **enable computer use**; let it finish. Take the **`after`**
   snapshot; stop `fs_usage`.
5. **Diff:** `analyze.py mid.snap after.snap` = the toggle-only delta; `analyze.py before.snap after.snap` =
   the full plain-CLI→working delta. `diff mid.config.toml after.config.toml` = the exact config change.
6. **Read the helper:** grep `fs_usage` for writes into `~/.codex/computer-use` and
   `plugins/cache/openai-bundled/computer-use` to see *which process* copied them and *from where* (it
   reads out of `/Applications/Codex.app/Contents/Resources/plugins/openai-bundled`). Also catches transient
   files the snapshot misses.
7. **Confirm "bundled, not downloaded":** (a) `shasum -a256` the landed `SkyComputerUseService` and the one
   inside `/Applications/Codex.app` → identical; (b) check the network capture / `tcpdump` SNI for any
   OpenAI CDN hit during the toggle → none; (c) `grep -r computer-use` the captured response bodies → none.
8. **Find the DMG URL:** `strings` the codex CLI binary for `oaistatic`/`dmg`/`download` — the app-install
   URL + the `--download-url` override flag live there.

### Lessons / gotchas (so future-you doesn't repeat them)
- The native `Codex Computer Use.app` exists in **3 places** post-install (the `computer-use/` copy, the
  plugin cache copy, and the marketplace copy) — all **byte-identical** for the *computer-use* plugin.
  Note: the **record-and-replay** plugin ships a *different* `SkyComputerUseService` (different sha) — don't
  confuse them.
- The marketplace dir must contain `.agents/plugins/marketplace.json` or `codex plugin list` won't see it.
- The desktop-app `config.toml` hardcodes `/Applications/Codex.app/...` paths for `cua_node` and
  `CODEX_CLI_PATH` (browser plugins). We drop that block; the **computer-use plugin itself uses relative
  paths**, so it survives the move.
- Running Claude/CLI as **root**: artifacts get root-owned — `chown -R <user>:staff` after, and remember
  the user's `~` is `/Users/<user>` (here `HOME` was preserved; as bare root it'd be `/var/root`).
- The "≈700 MB transient in `~/.codex/tmp/`" seen in a raw snapshot was **not** a download — it was
  transient staging/scratch; the stable footprint is `computer-use` 57M + `plugins` ~308M + `.tmp` ~260M.

### Codex's own plugin machinery (useful context)
The CLI has `codex plugin {add,list,remove,marketplace}`. Marketplaces can be **local** or **git**
(`codex plugin marketplace add`). Computer use is installed from a **local** marketplace (`openai-bundled`)
that the desktop app stages from its bundle. After our bootstrap, `codex plugin list` shows
`computer-use@openai-bundled   installed, enabled   <version>`. (Note: do not assume `codex plugin add
computer-use` works standalone — in testing the CLI treated the bundled computer-use specially; the
file-copy + config approach is what's proven.)

---

## 5. If OpenAI changes something — the re-derivation playbook

**Symptoms it broke:** the button fails; `codex plugin list` doesn't show computer-use enabled; the MCP
server won't launch; or a real `codex exec` computer-use call errors.

**Fast path (just the layout changed):**
1. Download the *current* DMG and mount it (or install the current desktop app once).
2. Inspect the payload — has the structure moved? Is `plugins/computer-use/` still under
   `…/Resources/plugins/openai-bundled/`? Is `Codex Computer Use.app` still in one of its two known
   homes (in-plugin, or `cua_node/lib/node_modules/@oai/sky/` — §1.6)? Is the plugin's `.mcp.json`
   still launcher-based with **relative** paths (`cwd:"."`, `CODEX_HOME` env)? Note the new
   `plugin.json` `version`.
3. Update **`ComputerUseSetup.swift`** to match — it's all in one place:
   - `dmgURL` (if the CDN path changed),
   - `payloadSource(inMount:)` / `nativeHelper(app:pluginSrc:)` (the shape-based lookups),
   - the three dest paths in `install(...)` and the `isInstalled` checks,
   - the `config.toml` blocks in `patchConfig()`.
   A useful shortcut for "how does the desktop app itself install it now": its logic is readable in
   `ChatGPT.app/Contents/Resources/app.asar` (grep for `cua_node` / `computer-use`); and the plugin's
   MCP server can be smoke-tested WITHOUT codex by piping JSON-RPC (`initialize` → `tools/list`) into
   `bin/computer-use-client-launcher mcp` with `CODEX_HOME` pointed at a staging dir holding just the
   helper — that's how §1.6 was pinned down.
4. **The reliable shortcut:** install the current desktop app once, enable computer use, and diff its
   `~/.codex` output against our bootstrap's — the desktop app's output is the ground truth we mirror
   (that's exactly how the 2026-07 variant swap was derived).

**Full path (behaviour changed — e.g. it now downloads, or pins, or uses absolute paths):** re-run the
**§4 protocol** end-to-end against the current desktop app. If the 3-snapshot diff shows a network fetch,
arm the network rig (`arm.sh`) during the toggle, read `report.sh`, and capture the new endpoint(s) +
auth — then teach the bootstrap to fetch them (Sentient already has the user's `~/.codex/auth.json` token
if auth is needed).

---

## 6. Verification (how we proved the bootstrap actually works)

End-to-end, on a **plain npm Codex CLI** (no desktop app), with the files laid in *purely from the DMG*:
- `codex plugin list` → `computer-use@openai-bundled   installed, enabled   1.0.857`.
- `codex exec --dangerously-bypass-approvals-and-sandbox "use computer use to screenshot my screen and
  describe it"` → it loaded the plugin's `SKILL.md`, invoked the MCP tools `computer-use/list_apps` and
  `computer-use/get_app_state` (real screenshot + accessibility tree), and accurately described the screen.

**To re-verify** after any change, repeat those two commands. (`codex exec` needs network for the model
call; the computer-use action needs Accessibility/Screen-Recording granted — handled outside the bootstrap.)

**Re-verified for the pure-MCP payload (2026-07-24, plugin 1.0.1000502 / CLI 0.145.0):**
- **Codex-free:** MCP over stdio to `bin/computer-use-client-launcher mcp` with only the helper staged
  under `CODEX_HOME` → full handshake, all 10 direct tools served (§1.6).
- **End-to-end on hardware:** the app's Settings → Set up… repaired a half-failed install (the §1.6
  field signature) through the new code path, and a live computer-use command fired through the app
  drove real actions to completion.

---

## 7. Reference data — snapshots (will drift)

**June 2026 teardown:**

| Thing | Value |
|---|---|
| DMG URL | `https://persistent.oaistatic.com/codex-app-prod/Codex.dmg` |
| DMG size / type | 529,667,527 B (≈505 MB) · `application/x-apple-diskimage` · Cloudflare |
| DMG sha256 | `80f026121b623d3b5f317239aa202605d90c0fe0e459ec27c859ba236923cdbb` |
| Codex.app version | `26.623.42026` |
| computer-use plugin | `1.0.857` |
| `SkyComputerUseService` (computer-use) sha256 | `9fb6b35012117308f65c…` |
| codex CLI tested | `0.142.3` (npm) |

**July 2026 (the ChatGPT-app rename, §1.5):**

| Thing | Value |
|---|---|
| DMG URL | unchanged |
| DMG size | 560,958,016 B (≈535 MB) |
| App at DMG root | `ChatGPT.app` |
| computer-use plugin | `1.0.1000366` |
| Helper bundle id / version | `com.openai.sky.CUAService` · `26.708.1000366` (unchanged id + signing → TCC grants survive) |
| codex CLI verified | `0.142.5` (node_repl runtime) · `0.144.1` (legacy/direct runtime) — both working |

**Late July 2026 (the pure-MCP restructure, §1.6):**

| Thing | Value |
|---|---|
| DMG URL | unchanged |
| DMG size / sha256 | 593,891,632 B (≈566 MB) · `ff6e8ac9985aec44caa30578…` |
| computer-use plugin | `1.0.1000502` (now ships `.mcp.json` + launcher; helper NOT inside) |
| Helper location | `Contents/Resources/cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app` |
| Helper bundle id / version | `com.openai.sky.CUAService` · `1000502` (id + signing unchanged → TCC grants survive) |
| codex CLI verified | `0.145.0` (direct MCP tools only — no node_repl support in the binary) |

---

## 8. Code map

- **`ComputerUseSetup.swift`** — the bootstrap (download → mount → shape-locate → ditto → patch →
  cleanup), `isInstalled`, `install(force:onLine:)`, the `Downloader` (URLSession progress).
- **`ComputerUseSkillPatch.swift`** — the confirmation-policy relaxation (section-scoped, automated;
  its own doc).
- **`CodexSetup.swift`** — the shared setup engine; step 3 = `setupComputerUse(force:)` +
  `computerUseReady`/`refreshComputerUse()`; `whatsNeeded()` for the onboarding driver.
- **`CodexSetupView.swift`** — the dev "CODEX SETUP" window; the "Set up computer use" / "Re-install" button.
- **`Permissions.swift`** — `grantComputerUseAutomation()` + helper detection (TCC; separate concern).
- **`CodexCLI.swift`** — the `codex exec` wrapper (how computer use is actually *driven* once installed).

Onboarding wiring guidance: **`Codex Setup Handoff (Onboarding).md`**.
