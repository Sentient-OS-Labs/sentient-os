# MCP Mirror Client — the app side of the hosted mirror

`MirrorClient.swift` mirrors the local vault to our one persistent backend (the FastMCP
server at `mcp.sentient-os.ai`, Arch §7) so the user's ChatGPT/Claude can read it over MCP.
Opt-in, opt-out, one-click delete. The Mac's vault is always canonical; the mirror is a
disposable copy.

## API

```swift
let mirror = MirrorClient.shared
await mirror.isEnabled                 // is mirroring ON? (the toggle flag — NOT just "token exists")
let url = await mirror.enable()        // opt in → mints token if absent → returns the share URL
await mirror.shareURL                  // the "Copy MCP Link" value, or nil
try await mirror.push()                // zip the vault + replace the mirror (call after any change)
let s = try await mirror.stats()       // {notesRead24h, toolCalls24h, lastAccess} for "Your AIs"
try await mirror.deleteRemote()        // delete the cloud copy (keeps the token → stable URL)
await mirror.disable()                 // opt out: flip OFF + delete remote, but KEEP the token (stable link)
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

**Sync is currently a SEPARATE manual step (dev decision — trivially re-couplable).**
`VaultCloud.create()` and `VaultCloud.update()` only **mark the vault dirty** (`VaultActivity.vaultDirty`)
— they no longer auto-push. The push happens via:
- the **MCP SYNC** button in DEV TOOLS — a forced `MirrorClient.push()` that clears the dirty flag, and
- **`VaultCloud.pushIfDirty()`** on app launch (a `.task` on `RootView`) — the durable catch-up that
  pushes iff the mirror is enabled AND the vault is dirty, clearing the flag only on success.

`vaultDirty` is persisted in `UserDefaults`, so a deferred sync survives a relaunch. To restore
auto-push-after-KB-update, call `await Self.pushIfDirty()` from `VaultCloud.markDirty()`.

## Turning the mirror on (today)

The opt-in is "mint a token" — `enable()`. The real onboarding/Settings opt-in UI is Phase 5, so
ahead of that the **DEV TOOLS** panel (`DevToolsView`) exposes, while the mirror is ON:
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

Runs enable → push → stats → delete → disable. Needs a vault on disk (`~/Sentient OS -- The Vault/`).

## Not built here (downstream)

The production opt-in surfaces — the MCP opt-in onboarding screen (step ⑨) with the
no-account/token/30-day-lease explainer, the "Your AIs" satellite (access-log line), and the
menu-bar Copy MCP Link — are Phase-5 work that calls into this client (the DEV TOOLS MCP TOGGLE is
the interim dogfood stand-in). Auto-push *after vault changes* is now wired (see Sync above); the
editor-idle gate (`VaultActivity.editorBusy`) still awaits the Phase-5 vault editor.
