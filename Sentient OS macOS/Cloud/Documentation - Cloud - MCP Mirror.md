# The MCP Mirror (Cloud/)

The app side of the hosted mirror: the knowledge base, offered to the user's ChatGPT and Claude (phone
apps included) over MCP at `mcp.sentient-os.ai`. Optional and off by default. It lets the AIs you choose start with useful context about your
projects, people and plans, including when you use those AIs on your phone. Your Mac's knowledge
folder remains the primary copy.

**Encrypted on your Mac. No decryption key persisted by the relay.** The relay stores ciphertext
and decrypts in memory to serve authorized requests through your private link. This describes the
storage protection precisely; it does not claim the running service cannot access plaintext while
serving a request. The AIs you grant access process the knowledge under their own policies.

## Files

`MirrorClient.swift`: `MirrorCrypto` (the key schedule and envelope), the `MirrorClient` actor, and the
small `Keychain` helper (service `ai.sentient-os.app`) the app uses for its few secrets. The UI is
`Views/ConnectAIsView.swift` (the guided setup window), `Views/Settings/ShareKnowledgePane.swift`,
and the home's `ShareKnowledgePopover`. The server lives in the `sentient-os-mcp` repo (open source).

## One password, no accounts

Each mirror has ONE minted **password**: 18 random bytes → base64url (24 chars), in the Keychain
(`mcp.mirror.password`), minted on first opt-in and never rerolled by turning sharing off and on (the
share URL is what the user pasted into their AIs). Everything is derived from it:

- `userID = base64url(HKDF-SHA256(password))[:20]`: a public, non-secret label. Because it is a one-way function of the password, the server verifies statelessly that a URL's userID belongs to its password; that binding authorizes reads AND push/delete/stats with no stored credential.
- `encKey = HKDF-SHA256(password)` (a different info label): the AES-256 key.
- The share URL: `https://mcp.sentient-os.ai/u_<userID>/p_<password>/mcp`.

The password rides in the URL, so anyone holding the full link can read, overwrite, or delete that
mirror. Treat the full link as a password, not as a public profile URL. Local triage helps filter
common sensitive identifiers, but the knowledge is personal and is not guaranteed to be de-identified.
If the link needs replacing, `regenerateToken()` mints a new one (persisted
BEFORE the old copy is deleted, so a write failure can never strand the user with no cloud copy) and the
orphaned copy expires on its lease. Regenerate is a support remediation only; there is no UI button
because it breaks every connector the user set up.

`mintPassword` throws if `SecRandomCopyBytes` fails (never a weak or all-zero key), and `Keychain.set`
reports failure so `enable()` never hands out a URL for a password that did not persist.

## Encryption (`MirrorCrypto`)

`push()` zips the whole knowledge folder, including `writingstyle.md` and files the user adds, and
encrypts it with **AES-256-GCM** before upload:

```
blob = [1 byte version = 1] + AES-GCM.combined(nonce(12) ‖ ciphertext ‖ tag(16)),  AAD = userID
```

The userID as AAD means a blob cannot be replayed under another identity; the version byte leaves room
to migrate. The salt, both HKDF info labels, the userID length, and the layout MUST match the server's
`crypto.py` byte for byte (cross-language verified). A seal failure throws; the code never falls back to
uploading plaintext.

## Sync

Whole-vault encrypted-blob replace: `POST /u_<uid>/p_<pw>/vault`. The zip is built by shelling to
`/usr/bin/zip` from INSIDE the vault directory so entries are root-relative (`README.md`,
`Career/Job.md`), which is the server's contract (`NSFileCoordinator.forUploading` wraps everything in
the folder name and breaks the README bundling). Pushes happen:

- after every full cycle (`ProactiveCycle` → `VaultCloud.pushIfDirty()`),
- 30 s after the last Knowledge-editor change (`VaultActivity.markChanged()`, debounced; the timer survives closing the window),
- once at app launch (the catch-up for a push a quit interrupted),
- and from Dev Tools' MCP SYNC (a forced push).

`pushIfDirty()` pushes only if the mirror is enabled AND `VaultActivity.vaultDirty`; the flag clears
only on success, so a failed push stays pending and retries on the next trigger. A non-HTTP response
(captive portal, transparent proxy) counts as failure, never success. A failed push emits
`mirror.push_failed` (HTTP status only). Every push renews the **30-day lease**.

## API

`isEnabled` (the on/off flag, `mcp.mirror.enabled`, independent of the password's existence) ·
`enable()` (mint if absent, flip on, return the share URL) · `shareURL` · `maskedURL(_:)` (shows the
public userID, masks the password to 4 chars; searches `/mcp` backwards because the host itself
contains it) · `push()` · `deleteRemote()` (requests deletion; keeps the password) · `disable()`
(off + delete, keeps the password) · `stats()` (`GET …/stats` → `{notes_read_24h, tool_calls_24h,
last_access}`) · `regenerateToken()` · `destroyKeychainIdentity()` (uninstall only) · `lastPush`
(the synced stamp) · `systemPrompt` (the coached instructions the user pastes into their AI: name the
connector, call `get_structure` first, then `get_files`).

`MirrorClient.baseURL` can be overridden with `SENTIENT_MIRROR_BASE` in DEBUG builds only (a Release
build must never let an environment variable redirect a push).

## The server contract (so app work never needs the server repo open)

- Hosted on Render (one uvicorn worker, a persistent disk). One multi-tenant FastAPI + FastMCP app; a token router sends `/u_…/p_…/mcp` to the MCP app and everything else to REST. Stateless per request. On disk: `vaults/<userID>/vault.enc` (ciphertext only) and `meta/<userID>/` (lease + access log). Plaintext markdown never touches the server's disk; it decrypts in memory per request.
- Every endpoint verifies the binding (constant-time). A bad binding, a bad password, and a missing vault all return the same neutral response, so a guessed userID leaks nothing.
- **Two MCP tools only:** `get_structure` (the folder tree PLUS the README portrait in one response, so one round trip answers "what do you know about me?") and `get_files` (a JSON array of paths; 50 per call, 256 KB response cap, "did you mean" on misses).
- Sync guards on the decrypted content: 60 MB upload / 200 MB unpacked (measured on actual extracted bytes) / 5,000 files, path-traversal rejection, UTF-8 filename recovery (macOS `zip` omits the flag). Rate limits per userID (tool calls ~60/min, pushes ~20/hour). An hourly sweeper reaps expired vaults and any directory without a `vault.enc`.
- The access log stores salted-hashed note paths, never clear titles.
- **Invariant: request paths are never logged** (the password rides in the URL). The uvicorn access log is disabled at import time in the server, guarded by a regression test, and the deploy command carries `--no-access-log` as well. The app mirrors this on its side: the Sentry SDK's URL-capturing defaults are forced off (see the Diagnostics doc).
- Field lessons from real ChatGPT/Claude sessions: clients lazy-load connector tools behind a search gate, so naming the connector in the prompt ("check my Sentient knowledge…") reliably triggers it; the coached system prompt teaches that. In-note guardrails survive the round trip.

## Turning sharing off

`disable()` stops syncing and attempts remote deletion while keeping the private link for a later
opt-in. Deletion is a network request and can fail when offline; the client does not guarantee
immediate remote removal. The server's 30-day lease and periodic cleanup are the expiry backstop.
Reset and uninstall also attempt mirror deletion. They do not erase records already held by an AI
provider that read the knowledge. The local folder is independent of the hosted copy.

## Turning it on

The guided `ConnectAIsView` window owns the sharing lifecycle: off = a consent veil with the trust
pillars and a "Yes, use the cloud MCP" glow (enable + first push); on = per-AI tabs (ChatGPT's three
video steps, Claude's two, a text-only Other AIs) with deep links into each AI's settings, the masked
link + Copy, the system prompt + Copy, and a quiet MCP pill that turns sharing off behind a
confirm-and-delete alert. Settings → Give AIs Knowledge and the home popover are doors into it and show
live `stats()`. Details in the Views docs.

## Related docs

`Vault/Documentation - Knowledge Base (Vault).md` (`VaultActivity`, `pushIfDirty`), `Views/Documentation - Views - Home, Processing & Shared UI.md` (`ConnectAIsView`), `Diagnostics/Documentation - Diagnostics (Sentry & TelemetryDeck).md`.
