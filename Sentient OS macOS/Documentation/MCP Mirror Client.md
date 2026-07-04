# MCP Mirror Client — the app side of the hosted mirror

`MirrorClient.swift` mirrors the local vault to our one persistent backend (the FastMCP
server at `mcp.sentient-os.ai`, Arch §8) so the user's ChatGPT/Claude can read it over MCP.
Opt-in, opt-out, one-click delete. The Mac's vault is always canonical; the mirror is a
disposable copy.

## API

```swift
let mirror = MirrorClient.shared
await mirror.isEnabled                 // is mirroring ON? (the toggle flag — NOT just "token exists")
let url = await mirror.enable()        // opt in → mints token if absent → returns the share URL
await mirror.shareURL                  // the "Copy MCP Link" value, or nil
try await mirror.push()                // zip the vault + replace the mirror (call after any change)
let s = try await mirror.stats()       // {notesRead24h, toolCalls24h, lastAccess} for "Connect AIs"
try await mirror.deleteRemote()        // delete the cloud copy (keeps the token → stable URL)
await mirror.disable()                 // opt out: flip OFF + delete remote, but KEEP the token (stable link)
let u2 = try await mirror.regenerateToken()  // leak remediation: delete old copy, mint NEW token, re-push
```

## The single token

No accounts, ever (Invariant 4). Each vault has ONE minted token, in the Keychain. It lives
in the share URL (`/u/<token>/mcp`) and authorizes everything — MCP reads AND push/delete/stats
(no `Authorization` header). Tradeoff: anyone who sees the share URL can also overwrite or
delete the vault; mitigated by no accounts, the 30-day lease, one-click delete, and the vault
being PII-stripped.

**Identity ≠ on/off.** The token is the durable identity: minted once and kept across OFF→ON, so
the share URL is **stable** (it's what the user pasted into ChatGPT/Claude — toggling must never
reroll it and break their connectors). Whether mirroring is currently ON is a *separate* flag
(`mcp.mirror.enabled`, UserDefaults) that `isEnabled` reads and the toggle flips — NOT "does a token
exist". `disable()` flips OFF and deletes the cloud copy but keeps the token. (Builds before this
flag equated enabled with token-exists; `isEnabled` migrates that state on first read.)

A lost token is a non-event: mint a new one, re-push; the orphaned cloud copy expires on its
30-day lease.

## Sync

Whole-vault **zip-replace**: `push()` zips `VaultGenerator.vaultRoot` and `POST`s it. A vault is
~KBs of markdown. The zip is built by shelling to `/usr/bin/zip` from **inside** the vault dir
(`zip -r -X -q … .`) so entries are **root-relative** (`README.md`, `Career/Job.md`) — the server's
contract. (We deliberately do *not* use `NSFileCoordinator.forUploading`: it wraps everything under
the vault folder name, which breaks the README-portrait bundling in `get_structure`. The server
also defensively unwraps a lone wrapper dir, so old clients still sync correctly.)

**When pushes happen.** `VaultCloud.create()`/`update()` mark the vault dirty
(`VaultActivity.vaultDirty`, persisted); the actual pushes ride:
- **every full cycle** — `ProactiveCycle` calls `VaultCloud.pushIfDirty()` right after the
  knowledge-base step (Analyze Now real mode + the 3am run),
- **Knowledge-editor changes** — `VaultActivity.markChanged()` debounces ONE push 30s after the
  last save/create/delete (a spree coalesces; the timer survives window close),
- **app launch** — a `pushIfDirty()` catch-up (a `.task` on the main window) for a push a quit
  interrupted, and
- the dev **MCP SYNC** button — a forced push.

`pushIfDirty()` pushes iff the mirror is enabled AND the vault is dirty, clearing the flag only on
success — a failed push just stays pending and retries on the next trigger.

## Turning the mirror on (today)

The user-facing opt-in is **Settings → Connect AIs to Knowledge** (`Views/Settings/YourAIsPane.swift`): the
value/privacy story, the share toggle (ON = `enable()` + a first push; OFF = a confirm dialog,
then `disable()`), the glowing **Connect your AIs** hero → `ConnectAIsView`, the REAL guided
setup (masked link + Copy · Copy-the-system-prompt · the "what do you know about me?" closer),
and live `stats()` activity. **Regenerate is backend-only** (`regenerateToken()` stays as the
support remediation if a link leaks; the UI button was removed — it bricks every connector the
user set up). The onboarding opt-in moment is still to build.

The **DEV TOOLS** panel (`DevToolsView`) keeps its own controls, while the mirror is ON:
- **MCP TOGGLE** — ON mints the token (if absent) + pushes the current vault; OFF deletes the cloud copy but **keeps the token**, so re-enabling reuses the same share link.
- **Copy MCP Link** / **Copy System Prompt** — the share URL and the coached connector prompt to paste into ChatGPT/Claude.
- **MCP SYNC** — force-push the current vault to the mirror (sync is a separate manual step now; see Sync above).
- **Stats** (under **More**) — the access-log summary.

Use these to dogfood end-to-end sync on a real INITIAL/ITERATIVE cloud run.

## Keychain

`MirrorClient` is the app's first Keychain user; the small `Keychain` enum at the bottom of the
file is the shared generic-password helper (service `ai.sentient-os.app`).

## Self-test

```sh
SENTIENT_SELFTEST=mirror "<app>/Contents/MacOS/Sentient OS"          # against production
SENTIENT_MIRROR_BASE=http://127.0.0.1:8901 SENTIENT_SELFTEST=mirror …  # against a local server
```

Runs enable → push → stats → delete → disable. Needs a knowledge base on disk (`~/Sentient OS - Knowledge Base/`).

## The server — the contract this client relies on

The backend lives in the private `sentient-os-mcp` repo (AGPL license inside; goes public at
launch); this section records the contract + hosting so app-side work doesn't need that repo open.

- **Hosting: Render.** Service `sentient-os-mcp`, 1 GB persistent disk, auto-deploys on push to
  `main`. DNS: `CNAME mcp → …onrender.com` (managed on Vercel, Jesai's account); Render-issued TLS.
  (Deliberately NOT Railway/Heroku — reliability / ephemeral-filesystem reasons. Aditya isn't in
  the Render workspace yet.)
- **One multi-tenant FastAPI + FastMCP app.** A `TokenRouter` front door routes `/u/<token>/mcp`
  to the MCP app and everything else to REST. Stateless — every request self-contained. On disk:
  `vaults/<token>/` = the mirrored markdown · `meta/<token>/` = lease + access log (deleted with
  the vault).
- **Two MCP tools only.** `get_structure` returns the folder tree PLUS the README portrait in the
  same response (one round-trip answers "what do you know about me?"; the tool description names
  the trigger phrases and forbids the "I have no memory" disclaimer). `get_files` takes a **JSON
  array of paths** (note titles contain commas — a comma-separated string literally couldn't fetch
  them); strings are still accepted defensively with greedy comma-reassembly. Caps: 50 paths/call,
  256 KB response; not-found errors carry "did you mean…" matches.
- **Sync endpoints.** `POST /u/<token>/vault` (the zip) whole-replaces via staging + atomic
  rename; `DELETE` is the one-click nuke; every push renews the **30-day lease**; an hourly
  sweeper deletes expired vaults. Zip guards: 50 MB zipped / 200 MB unpacked / 5,000 files,
  path-traversal rejection, and UTF-8 filename recovery (macOS `zip` omits the UTF-8 flag —
  em-dashes arrived as mojibake before this).
- **Abuse guards:** ~60 tool-calls/min, ~20 pushes/h (one uvicorn worker by design).
- **Stats:** every tool call is logged; `GET /u/<token>/stats` → `{notes_read_24h, tool_calls_24h,
  last_access}` — what the Connect-AIs surfaces show.
- **Field lessons (real ChatGPT/Claude sessions):** clients lazy-load connector tools behind a
  search gate — naming the connector in the prompt ("check my Sentient knowledge — …") reliably
  triggers it, so onboarding/demo copy must teach that phrasing. Schemas permit what descriptions
  only request — make every accepted input shape unbreakable. In-note guardrails survive the round
  trip (a connected Claude obeyed an in-note "do not assert X") — a real control surface.
- **Tests:** a pytest suite + a 13-check live contract script that runs against local AND prod.
  Still to verify end-to-end: real ChatGPT + both mobile apps.

## Not built here (downstream)

The onboarding MCP opt-in moment (the no-account/token/30-day-lease pitch after the first
knowledge base exists) and post-launch proper OAuth. ⚠️ The Settings pane's copy claims E2E
encryption ahead of the code — the "mcp encryption" backlog item MUST ship before launch.
