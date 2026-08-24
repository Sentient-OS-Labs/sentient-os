# Codex Setup (Cloud/): install, login, driver

How Sentient gets a working cloud spine plus computer use onto the user's Mac. Three steps, one shared
engine that onboarding, Settings → Permissions & Health, and Dev Tools all drive — never a second,
divergent copy:

1. **Install** the Codex CLI (OpenAI's official installer; it doubles as the updater).
2. **Log in** (`codex login`, browser OAuth).
3. **Driver**: download and verify the pinned cua-driver binary, the hands of computer use (the
   mechanics live in `Driver/CuaDriverSetup.swift`; this step needs neither the codex binary nor the
   login, so it can run in parallel with anything).

## Files

| File | Job |
|---|---|
| `CodexSetup.swift` | The `@Observable` setup engine (`CodexSetup.shared`): detection flags, the three actions, the install retry policy, `whatsNeeded()`, and the keep-current updater. |
| `ComputerUseSpeed.swift` | The Speed vs Intelligence slider value (documented in the CodexCLI doc). |

The install and login mechanics themselves live in `CodexCLI` (`install`, `startLogin`,
`loginStatus`); the driver install lives in `CuaDriverSetup` (see the Driver doc). This file owns the
flow and the one source of truth both UIs render.

## The engine (`CodexSetup`)

Two kinds of members:

- **Detection (no side effects):** `installed`, `loggedIn`, and the driver's `CuaDriver.isInstalled`,
  refreshed by `refreshInstalled()` (off-main; `locateBinary` can spawn a login shell, so it must
  never run inside the singleton's initializer) and `refreshLoginStatus()` (`codex login status`).
- **Actions (self-guarding):** `installCodex()` ALWAYS runs the installer (update in place; auth and
  config untouched; a failed update over a working codex reads as "present, update skipped", never an
  error). `ensureInstalled(attempts: 3)` is the single retry policy (10 s between attempts) and flips
  `installGaveUp` when the budget is spent so the panels can show the manual-install fallback.
  **Lazy install (decided 2026-08-21, tightened 2026-08-22): nothing installs at first launch, and
  browsing engine tabs downloads nothing** — the only callers are the COMMITMENT actions: ChatGPT's
  sign-in button (onboarding), Settings' "Use ChatGPT", a custom tab's Test & Select (codex runs the
  vision probe even for custom endpoints), and Health's explicit Install pill. The Claude engine has
  its own sibling (`ClaudeSetup.ensureInstalled`, kicked by "Sign in with Claude") — a user who picks
  Claude never downloads codex, and vice versa. `startLogin(force:)` opens the browser
  and returns; the login is noticed by polling `loginStatus` (onboarding and Health both do this; only
  the dev window keeps a "Finished" button). `setupCuaDriver()` streams the driver install's progress
  lines; `ensureCuaDriver()` is the fire-time self-heal — a computer-use run whose driver is missing
  gets the 2–3 s pinned download here (waiting on an in-flight install rather than racing it) instead
  of a dead fire.
- `whatsNeeded()` re-checks all three and returns the pending steps in order.

Failures emit `codex_setup.step_failed` (error type only).

## Keeping the CLI current

The managed install (`~/.local/bin/codex`) is Sentient's to keep fresh — a stale client eventually
starts failing against the backend. `updateIfDue(trigger:)` makes at most one update attempt a day,
skips when already the newest release (a 1 KB version check), and skips entirely while Claude is the
backend (an engine out of service earns no background downloads; chatgpt AND custom both run through
codex, so only `.claude` skips). `startKeepingCurrent(isBusy:)` drives it every 15 minutes when the
user is away and nothing is running — the same tick also drives `ClaudeSetup.updateIfDue`, which
self-guards symmetrically (managed binary only, Claude backend only, once a day). Two reactive paths tighten the
loop: `repairStaleClient()` (a run just FAILED on the stale-client signature: update now, flag the
health rung until it lands) and `noteStaleSignal()` (the signature appeared on a run that still
succeeded: pull the next daily update forward, no banner). A codex the user installed themselves is
never touched — the updater only manages the managed copy.

## Where each step runs today

The CLI installs lazily, at the user's engine commitment on the frontier-model surfaces (never at
launch — see the lazy-install note above); login is the ChatGPT panel of onboarding's frontier-model
step (or Health's inline fix); the driver downloads silently **two minutes into
onboarding's first analysis** (armed when the analysis takeover appears, so it never races the model
download's tail; ~40 MB, an unstructured task, so pausing the analysis never cancels it), or from
Settings → Health's fix, or — on Macs updating from the 1.x computer-use era — through the one-time
`ComputerUseUpgrade` window (see the Permission Gate doc). While a setup step runs, `RootView` shows a
quiet whisper on whatever screen is up.

## Rules

- Detection first: never install over a user's own codex, never re-download an existing driver.
- The setup writes no TCC. macOS grants are the permission gate's job.
- One engine, two UIs: onboarding and the dev tools render the same shared state; never fork the flow.

## Related docs

`Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md`,
`Cloud/Documentation - Cloud - ClaudeCLI (the claude -p engine).md` (`ClaudeSetup`, the two-step sibling),
`Driver/Documentation - Driver (cua-driver).md` (step 3's mechanics and the daemon it feeds),
`Views/Permissions/Documentation - Permission Gate & Guide.md`,
`Views/Onboarding/Documentation - Onboarding.md`.
