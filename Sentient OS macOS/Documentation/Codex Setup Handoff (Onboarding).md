# Codex Setup Handoff (Onboarding)

How onboarding should drive the three Codex setup steps. All of it runs through **one shared engine**,
`CodexSetup.shared` — the dev "CODEX SETUP" window and the real onboarding flow call the *exact same code*,
so there's never a divergent copy. (Deep dive on step 3's internals: `Computer-Use Bootstrap (Codex
Reverse-Engineering).md`.)

## The three steps
1. **Install** the Codex CLI — `installCodex()`
2. **Log in** (browser OAuth) — `startLogin(force:)` then `confirmLogin()`
3. **Computer use** — `setupComputerUse(force:)`

## Two kinds of function (this is the key bit)
- **Detection (no side effects):** `installed`, `loggedIn`, `computerUseReady` (Bool state), refreshed by
  `refreshInstalled()`, `refreshLoginStatus()` (async — runs `codex login status`), `refreshComputerUse()`.
- **Actions (each self-guards / idempotent):** `installCodex()`, `startLogin()`, `setupComputerUse()` —
  every one **no-ops when its step is already done**, so they're safe to call blindly.

Plus one driver helper: **`whatsNeeded() async -> [Step]`** — does a *fresh* check of all three and returns
the steps still pending, in order.

## Recommended onboarding flow (smart driver)
Use `whatsNeeded()` to decide what to show/run; don't make the user redo finished steps:

```swift
let codex = CodexSetup.shared
for step in await codex.whatsNeeded() {        // e.g. [.computerUse] if 1 & 2 already done
    switch step {
    case .install:     await codex.installCodex()
    case .login:       codex.startLogin(); /* wait for the browser, then: */ await codex.confirmLogin()
    case .computerUse: await codex.setupComputerUse()
    }
}
```
- Render a step's UI only if it's in `whatsNeeded()`; show the rest as already ✓.
- The order matters: install → login → computer use (login needs the binary; computer use is independent of
  login for the *file* bootstrap, but you want login done so it can actually run).

## Things to know
- **Login is interactive.** `startLogin()` opens the browser and returns immediately; the user finishes
  there, then you call `confirmLogin()` (which checks `codex login status`). It can't fully auto-complete —
  but it *will* be skipped entirely when already logged in.
- **`force` = redo on purpose.** `startLogin(force: true)` (re-login) and `setupComputerUse(force: true)`
  (clean re-install) bypass the self-guard. Default (no force) skips when done. Use force only for explicit
  "do it again" buttons.
- **Dumb sequential also works.** If you'd rather just call `installCodex()` → login → `setupComputerUse()`
  in order without `whatsNeeded()`, that's safe — every action self-guards. `whatsNeeded()` just lets you
  skip rendering finished steps.
- **Computer use is ~505 MB + a few minutes** (downloads OpenAI's DMG). Stream `computerUseStatus` to the
  UI (it carries live "Downloading… 42%", "Copying plugin…", "✓ ready" lines). Gate it behind step 1 (it
  refuses if codex isn't installed).
- **No TCC here.** Accessibility / Screen-Recording consent for the helper is a separate UX step — the
  bootstrap writes none.

## Who drives it today
- **Dev Tools → CODEX SETUP** (`Views/CodexSetupView.swift`) — the three step cards.
- **Settings → Permissions & Health** — the SET UP CODEX rows' fix buttons open the same
  `CodexSetupView` sheet; statuses re-probe when it closes.
- **Onboarding** (to build) presents its own polished screens over this same engine.

## Status
Engine + both UIs are built and working; the computer-use bootstrap is proven end-to-end (the plain
CLI + DMG-extracted files drive real computer use — see the bootstrap doc).
