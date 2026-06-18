# MCP Mirror Client — the app side of the hosted mirror

`MirrorClient.swift` mirrors the local vault to our one persistent backend (the FastMCP
server at `mcp.sentient-os.ai`, Arch §7) so the user's ChatGPT/Claude can read it over MCP.
Opt-in, opt-out, one-click delete. The Mac's vault is always canonical; the mirror is a
disposable copy.

## API

```swift
let mirror = MirrorClient.shared
await mirror.isEnabled                 // tokens exist in the Keychain?
let url = await mirror.enable()        // opt in → mints tokens → returns the share URL
await mirror.shareURL                  // the "Copy MCP Link" value, or nil
try await mirror.push()                // zip the vault + replace the mirror (call after any change)
let s = try await mirror.stats()       // {notesRead24h, toolCalls24h, lastAccess} for "Your AIs"
try await mirror.deleteRemote()        // one-click delete (keeps the token → stable URL on re-enable)
await mirror.disable()                 // full opt-out: delete remote + forget the token
```

## The single token

No accounts, ever (Invariant 4). Each vault has ONE minted token, in the Keychain. It lives
in the share URL (`/u/<token>/mcp`) and authorizes everything — MCP reads AND push/delete/stats
(no `Authorization` header). Tradeoff: anyone who sees the share URL can also overwrite or
delete the vault; mitigated by no accounts, the 30-day lease, one-click delete, and the vault
being PII-stripped.

A lost token is a non-event: mint a new one, re-push; the orphaned cloud copy expires on its
30-day lease.

## Sync

Whole-vault **zip-replace**: `push()` zips `VaultGenerator.vaultRoot` and `POST`s it. A vault is
~KBs of markdown. The zip is built by shelling to `/usr/bin/zip` from **inside** the vault dir
(`zip -r -X -q … .`) so entries are **root-relative** (`README.md`, `Career/Job.md`) — the server's
contract. (We deliberately do *not* use `NSFileCoordinator.forUploading`: it wraps everything under
the vault folder name, which breaks the README-portrait bundling in `get_structure`. The server
also defensively unwraps a lone wrapper dir, so old clients still sync correctly.)

**The sync happens automatically after every knowledge-base change.** `VaultCloud.create()` and
`VaultCloud.update()` each end with `markDirtyAndPush()`, which sets `VaultActivity.vaultDirty`
then calls **`VaultCloud.pushIfDirty()`** — the single push orchestrator: push only if the mirror
is enabled AND the vault is dirty, clearing the dirty flag only on a successful push. A failure
leaves `vaultDirty` set so the next trigger retries. `SentientOSApp` also calls
`VaultCloud.pushIfDirty()` once on launch (a `.task` on `RootView`) — the **durable catch-up** for
a push that failed or never ran (e.g. the app quit between a KB update and its push). `vaultDirty`
is persisted in `UserDefaults`, so a deferred sync survives a relaunch. (This restores the retry
the retired `DaysEndJob.pushIfDirty()` used to provide; future vault-editor saves hook in the same
way.)

## Turning the mirror on (today)

The opt-in is "mint a token" — `enable()`. The real onboarding/Settings opt-in UI is Phase 5, so
ahead of that there's a **MCP TOGGLE** button in **DEV TOOLS** (`DevToolsView`): ON mints the token
and pushes the current vault; OFF deletes the cloud copy and forgets the token. Detailed actions
(copy share link, force a Sync now, read access stats) sit under **More** while the mirror is ON.
Use this to dogfood end-to-end sync on a real INITIAL/ITERATIVE cloud run.

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
