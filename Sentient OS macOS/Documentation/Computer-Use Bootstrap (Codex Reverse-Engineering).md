# Computer-Use Bootstrap — Reverse-Engineering Codex & the Copy Logic

**What this is:** the canonical reference for how Sentient makes Codex **computer use** work on a *plain
Codex CLI* — with no Codex desktop app install — and, more importantly, **how that was reverse-engineered
and how to re-derive it when OpenAI changes things.** If the copy-in logic ever breaks, start here.

Implementation: `ComputerUseSetup.swift` (the bootstrap), `CodexSetup.swift` (step 3 of the flow),
`CodexSetupView.swift` (the dev button). Onboarding usage: `Codex Setup Handoff (Onboarding).md`.

> Values like the DMG size, plugin version, and sha256s in this doc are **snapshots from the June 2026
> teardown** (Codex.app 26.623.42026, computer-use plugin 1.0.857). They WILL drift. The *method* is what
> stays true — §4 and §5 are the parts that matter long-term.

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
    (≈505 MB · Cloudflare · application/x-apple-diskimage · override via `codex app --download-url`)
```

---

## 2. What we copy, where, and why (the bootstrap spec)

Everything comes from one source subtree in the mounted DMG:
`/<mount>/Codex.app/Contents/Resources/plugins/openai-bundled/`

| Dest under `~/.codex/` | Source (inside `…/openai-bundled/`) | Why it's needed |
|---|---|---|
| `computer-use/Codex Computer Use.app` | `plugins/computer-use/Codex Computer Use.app` | The native helper. Referenced by the `notify` line in `config.toml` (the turn-ended `SkyComputerUseClient`). |
| `plugins/cache/openai-bundled/computer-use/<version>/` | `plugins/computer-use/` | **The runnable plugin.** Its `.mcp.json` launches the MCP server that *is* computer use. `<version>` = the `version` field in `plugins/computer-use/.codex-plugin/plugin.json` (e.g. `1.0.857`). |
| `.tmp/bundled-marketplaces/openai-bundled/` | the whole `openai-bundled/` tree | Registers the marketplace so `codex plugin list` recognises the plugin as installable/installed. Must contain `.agents/plugins/marketplace.json`. |

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

### Why the plugin is portable (important)
The plugin's `.mcp.json` launches the helper with a **relative** command and `cwd: "."`:
```json
{ "mcpServers": { "computer-use": {
    "command": "./Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient",
    "args": ["mcp"], "cwd": "." } } }
```
There are **zero `/Applications/Codex.app` references** inside the plugin or the native app. That's why a
copy-into-`~/.codex` works with no path rewriting. **Re-verify this if things change** (§5) — if OpenAI
switches to absolute paths, the copy alone won't be enough.

### What we deliberately DON'T copy
- **`cua_node/`** (`Codex.app/Contents/Resources/cua_node`) — the Node runtime for the **browser/chrome**
  plugins (the `[mcp_servers.node_repl]` block). Computer use does **not** need it; we omit that block
  entirely. (Only vendor `cua_node/` + rewrite its two paths if we ever want browser control too.)
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
is onboarding UX). The bootstrap intentionally writes no TCC.

---

## 3. How we copy (implementation: `ComputerUseSetup.swift`)

`install(force:onLine:)` runs the whole flow, streaming human-readable progress:
1. **Download** the DMG via `URLSession` (a small `URLSessionDownloadDelegate` reports % progress).
2. **Mount** read-only: `hdiutil attach <dmg> -nobrowse -readonly -mountpoint <tmp>`.
3. **Extract** each of the 3 trees with **`ditto`** (not `cp`) — `ditto` preserves the code signatures and
   extended attributes of the signed `.app` bundles. Each dest is removed first, then copied (clean replace).
4. **Patch** `config.toml` idempotently (prepend `notify`, append the two tables, each only if its marker
   is absent).
5. **Clean up:** `hdiutil detach` and delete the 505 MB DMG — both via `defer`, so they run on every exit
   path (success or throw). The only thing left on disk is the ~300 MB of extracted files in `~/.codex`.

**Idempotency / repair:** `ComputerUseSetup.isInstalled` is a 3-part AND — (a) the native Mach-O exists
(`…/SkyComputerUseService`, not just the `.app` dir → catches a half-copy), (b) a plugin version dir with
its `plugin.json` exists, (c) `config.toml` contains the enable block. All true → skip (no wasteful
re-download), including an install done by the *real* desktop app. Any missing → it re-runs and repairs.
`force: true` (the "Re-install" button) bypasses the skip for a clean replace.

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
2. Inspect `Codex.app/Contents/Resources/plugins/openai-bundled/` — has the structure moved? Is
   `plugins/computer-use/` still there? Is `Codex Computer Use.app` still inside it? Is the plugin's
   `.mcp.json` still using **relative** paths (`cwd:"."`)? Note the new `plugin.json` `version`.
3. Update the constants in **`ComputerUseSetup.swift`** to match — they're all in one place:
   - `dmgURL` (if the CDN path changed),
   - `marketplaceInDMG` (the in-DMG source path),
   - the three dest paths in `install(...)` and the `isInstalled` checks,
   - the `config.toml` blocks in `patchConfig()`.

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

---

## 7. Reference data — June 2026 teardown (will drift)

| Thing | Value |
|---|---|
| DMG URL | `https://persistent.oaistatic.com/codex-app-prod/Codex.dmg` |
| DMG size / type | 529,667,527 B (≈505 MB) · `application/x-apple-diskimage` · Cloudflare |
| DMG sha256 | `80f026121b623d3b5f317239aa202605d90c0fe0e459ec27c859ba236923cdbb` |
| Codex.app version | `26.623.42026` |
| computer-use plugin | `1.0.857` |
| `SkyComputerUseService` (computer-use) sha256 | `9fb6b35012117308f65c…` |
| codex CLI tested | `0.142.3` (npm) |

---

## 8. Code map

- **`ComputerUseSetup.swift`** — the bootstrap (download → mount → ditto → patch → cleanup), `isInstalled`,
  `install(force:onLine:)`, the `Downloader` (URLSession progress).
- **`CodexSetup.swift`** — the shared setup engine; step 3 = `setupComputerUse(force:)` +
  `computerUseReady`/`refreshComputerUse()`; `whatsNeeded()` for the onboarding driver.
- **`CodexSetupView.swift`** — the dev "CODEX SETUP" window; the "Set up computer use" / "Re-install" button.
- **`Permissions.swift`** — `grantComputerUseAutomation()` + helper detection (TCC; separate concern).
- **`CodexCLI.swift`** — the `codex exec` wrapper (how computer use is actually *driven* once installed).

Onboarding wiring guidance: **`Codex Setup Handoff (Onboarding).md`**.
