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
  login and computer-use **no-op when their step is already done**, so they're safe to call blindly.
  ⚠️ Exception (since 2026-07-09): `installCodex()` **always runs** — OpenAI's install script doubles as
  the CLI updater (update-in-place; auth/config untouched), and setup should hand the latest CLI to the
  computer-use step. It's still safe to call blindly (a failed update over a working codex reads as
  "present, update skipped", never a ✗); the onboarding codex screen kicks it once per launch via
  `ranInstallerThisLaunch`.

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
  refuses if codex isn't installed — and it re-probes the DISK for the binary, not the cached flag, so a
  user who installed codex themselves mid-onboarding still gets computer use). While it runs, RootView
  shows the screen-agnostic whisper ("Setting up Codex computer use in the background.") bottom-left of
  whatever screen is up — keyed to the live `settingUpComputerUse` flag, so dev/Settings-triggered setups
  surface it too.
- **Detection-first is the law, both steps.** A user's own codex is never installed over
  (`locateBinary` covers brew/npm/nvm/standalone + a login-shell `which`), and an existing computer use —
  including one set up by OpenAI's real desktop app — is never re-downloaded (`ComputerUseSetup.isInstalled`
  checks all three markers before a single byte moves). Has codex but no computer use → just computer use
  installs. The only `force: true` lives on the dev window's explicit re-install button.
- **No TCC here.** Accessibility / Screen-Recording consent for the helper is a separate UX step — the
  bootstrap writes none.

## Who drives it today
- **Dev Tools → CODEX SETUP** (`Views/CodexSetupView.swift`) — the three step cards.
- **Settings → Permissions & Health** — the SET UP CODEX rows' fix buttons open the same
  `CodexSetupView` sheet; statuses re-probe when it closes.
- **Onboarding** (`Views/Onboarding/`) — REAL now: the CLI installs silently in the background from
  launch (`AppState`'s kick, with retries; the login screen's poll re-kicks as a net), the login
  screen notices the finished browser sign-in on its own (a 2s `codex login status` poll + a
  foreground re-check — no "I'm done" button), and computer use bootstraps silently two minutes
  into the first analysis (no screen of its own). **Right after login comes the plan crossroads**
  (`OnboardingPlanView`): the fresh auth.json's plan claim decides — free/go accounts choose
  upgrade-vs-knowledge-base-only, full plans skip it before it renders. See `Plan Gate (CodexAuth
  & Knowledge-Base-Only).md`.

## Status
Engine + all three UIs are built and working; the computer-use bootstrap is proven end-to-end (the
plain CLI + DMG-extracted files drive real computer use — see the bootstrap doc).
