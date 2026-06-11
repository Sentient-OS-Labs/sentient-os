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

Whole-vault **zip-replace**: `push()` zips `VaultGenerator.vaultRoot` via the OS's coordinated
`.forUploading` read (no shelling out, no deps) and `POST`s it. A vault is ~KBs of markdown.
Call `push()` after initial generation, each daily update, and any user edit (the editor-idle
guard + change trigger are the scheduler's job).

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

UI surfaces (Copy MCP Link in the menu bar, the "Your AIs" satellite, the MCP opt-in
onboarding screen) and the auto-push triggers (after vault changes, editor-idle-gated) are
Phase-5 / scheduler work that calls into this client.
