# Overnight Scheduler — the 3am Wake

The overnight scheduler wakes the Mac at 3am (lid shut), runs the exact same pipeline as the home's
Analyze Now (`IterativeRun .auto` + the Gmail/Calendar legs → `ProactiveCycle`), then sleeps — so a
fresh "For You" briefing is waiting when you open the lid. This doc is the whole scheduler story:
the proven wake mechanism, the root privilege model, the nightly run, and the production wiring
(install · login item · enable flags · the 18h auto-enable).

The in-app scheduler lives in `Scheduling/OvernightScheduler.swift` (owned by `AppState`); it only
runs while Sentient is open. Everything logs to `~/Library/Logs/SentientOS/scheduler.log`
(persistent, flushed per line — the "black box" for diagnosing an empty morning); the root helper
logs to `/Library/Logs/SentientOS-wakehelper.log`.

## The wake mechanism — proven on real hardware (June 23, lid shut)

The Mac woke at exactly **03:00:00** on a scheduled wake, kept itself awake, ran `.initial` over the
enabled connector (46 Documents items → 33 kept / 13 junk / 0 failed in ~2¼ min), released the
keep-awake, and slept again. Overnight processing is the approach — it superseded the old "~5s
after the morning wake" (`NSWorkspace.didWakeNotification`) fallback plan; there is still
deliberately **no daytime / "3 PM" idle trigger**.

What the experiment established (the physics the design rests on):
- **Gemma/Metal runs with the lid shut** — the scariest unknown; a clean pass (every on-device
  inference succeeded during a lid-closed run).
- **A userspace `IOPMAssertion` does NOT hold a closed lid.** `PreventUserIdleSystemSleep` blocks
  *idle* sleep only; closing the lid is a forced (clamshell) sleep that overrides it. On AC with
  the lid shut and only an assertion, the Mac sleeps and self-wakes in ~43-second maintenance
  bursts (the GPU still works inside them) — not continuous.
- **Root `pmset disablesleep 1` DOES hold it** — lid shut, fully awake, no gaps, charging, thermals
  nominal. It's the one knob that gives a single continuous overnight run, and it needs root.
- A scheduled `pmset` wake fires reliably, and the already-running app process survives sleep and
  resumes to handle it (the waiting Task freezes with the Mac and thaws on the scheduled wake).

## The privilege model — the root wake helper

The ONLY code that runs as root is a tiny wake helper: the SAME app binary relaunched by launchd
with `--wake-helper` (no separate Xcode target — `App/main.swift` branches into helper mode before
SwiftUI, which is why `@main` moved off the app struct). It exposes six XPC ops — `armWake` /
`cancelWake` / `cancelAllWakes` / `beginAwake` / `heartbeat` / `endAwake` — gated by a client
code-signing check. Files: `Scheduling/WakeHelper.swift` (root side) · `WakeHelperClient.swift`
(app side — every call is reply/error/timeout-guarded, so it can never hang at 3am) ·
`WakeHelperProtocol.swift` (the shared contract).

- **The deadman (load-bearing safety):** `beginAwake` starts a timer the app must feed via
  `heartbeat`; if the app crashes and stops feeding it, the helper itself runs `disablesleep 0` —
  so a bug can never leave the Mac awake all day. The helper also resets defensively on launch.
  This safety lives OUTSIDE the app on purpose: an app-side timer dies with the app (the lesson
  from a manual test where an un-reset `disablesleep` kept a Mac awake).
- **Stale-wake hygiene:** the helper persists the armed wake spec, cancels it when the app's XPC
  connection drops (quit / crash / force-quit — a Mac with Sentient closed never wakes on a stale
  schedule), and the loop wipes all wakes (`cancelAllWakes`) before arming exactly one.
- ⚠️ **The code-sign gate is DEBUG-permissive** (allows-and-logs on a failed check so dev testing
  isn't blocked); Release MUST enforce it — pin the Developer ID team before launch.

## The nightly run (`OvernightScheduler.runProcessing`)

Detect the enabled connectors via **`SourceSelection.current(...)`** — the exact same reader the
dev UI and Analyze Now use, so a 3am run processes precisely what's toggled on (persistent custom
folders included) → check the **go/no-go gates** (`PowerState`: on AC · not Low Power Mode · not
thermally critical — else log + emit `overnight.gated{reason}` and skip; the loop is already
re-armed for tomorrow; thermal is start-only) → `beginAwake` + a 60s heartbeat loop →
`IterativeRun(.auto)` + the Gmail/Calendar legs → the SAME **`ProactiveCycle`** tail as Analyze Now
(knowledge base → mirror push → proactive decide/research/prepare → wipe summaries) → `endAwake` →
the Mac idle-sleeps (lid shut) → re-arm for the next night. Production default is **3:00 AM**
(`defaultMinutes`; the dev UI can override).

⚠️ Known caveat: **Full Disk Access can read `false` when the app is launched from Terminal** (TCC
attribution) — which silently excludes the DB sources. The arm-time `DETECTED …` / `FDA granted:`
log lines surface it.

## The 18h auto-enable — why, and how

Right after the first big **initial** processing run, everything is caught up — there's nothing new
to chew on. If we armed the 3am wake immediately and initial finished at, say, 10pm, the run five
hours later would find almost nothing → a wasted wake and an **empty morning briefing**. So we wait
**18 hours after the first full cycle finishes**, by which point a full day of real life has piled up,
and *then* turn the scheduler on. The very first automatic overnight run has something worth surfacing.

- **"Initial finished" = the first full `ProactiveCycle`.** `ProactiveCycle.run()` calls
  `OvernightScheduler.noteFirstCycleCompleted()` on its success path, which stamps
  `firstCycleCompletedAt` **once** (later calls are ignored, so the clock starts at the true first finish).
- **The checker — `maybeAutoEnable()`** runs at launch (`AppState.init`), after every cycle
  (`RootView`'s processing `onDone`), and from a one-shot timer it arms for the 18h mark (so it fires
  even if the app just sits open). It is idempotent and:
  - **Latches** (`autoEnableFired`) so it acts at most once and never re-enables after a user turns it off.
  - **Never fights the user** — if the scheduler is already on (dev or prod flag), it just latches.
  - **Knowledge-base-only mode (free/go plans) early-returns before everything** — no timer, no
    production flag, no 3am runs (those plans have no quota for nightly codex work). Deliberately
    NOT latched, so an upgrade + reset starts the 18h clock fresh. See `Plan Gate (CodexAuth &
    Knowledge-Base-Only).md`.
  - **Gates on prerequisites** — only flips production ON once the root helper is **approved** *and*
    launch-at-login is on. If the 18h has elapsed but prerequisites aren't met, it sets
    `needsSchedulerSetup` (published, for the setup UX) and retries on the next tick — it never
    silently half-enables.
- **The wait is 18h** (`defaultAutoEnableDelay`); a dev key (`autoEnableDelaySeconds`) shortens it for testing.

## A — Installing the root daemon

**[DECIDED 2026-07-04] The admin-password installer IS the production install path** —
`WakeHelperInstaller` (`Scheduling/WakeHelperInstaller.swift`): one native "enter your password"
dialog (osascript admin) that writes the LaunchDaemon plist (pointing at THIS binary) into
`/Library/LaunchDaemons`, chowns/chmods it, and `launchctl bootstrap`s it. It's measured-and-working
on real hardware, self-heals when the binary path goes stale (`isInstalledAndCurrent()` checks the
plist points at the running executable), and — the UX line we hold — never sends the user into
System Settings. **Settings → Permissions & Health's "Overnight wake" fix button runs exactly this.**
The SMAppService.daemon migration (a Login Items approval toggle) was considered and rejected.

**SMAppService plumbing survives for the dev cockpit only:**
- A LaunchDaemon plist is still bundled at `Contents/Library/LaunchDaemons/…WakeHelper.plist` (repo
  file at the project root, a "Copy wake-helper daemon plist" build phase) so
  `WakeHelperClient.register()` / `.status` / `openLoginItemsSettings()` keep working for
  experiments (`OvernightDevView` step ①).
- `OvernightScheduler.ensureHelperReady()` still checks SMAppService first (`.enabled` → go) and, in
  DEBUG, falls back to the password installer when SMAppService reports `.notFound`/`.notRegistered`.
  Since the production install path is the installer (via the Health pane), a user who set up through
  Settings passes the DEBUG fallback's `isInstalledAndCurrent()` check without any SMAppService state.

> **Signing note (SMAppService, dev only):** approval works on any validly-signed build — a standard
> Apple Development Debug build is enough; only a fully unsigned `CODE_SIGNING_ALLOWED=NO` CLI build
> returns `.notFound`.

## B — Launch at login

`LoginItem.swift` wraps `SMAppService.mainApp`: `enable()` / `disable()` / `isEnabled` / `status`.
Load-bearing because the scheduler lives inside the running app — no app open at 3am, no wake.
`enable()` is silent (no approval); auto-enable calls it as part of flipping the scheduler on.

## C — Production enable flag

Two keys, either one runs the scheduler (`reevaluate()` ORs them):
- `dbg.scheduler.enabled` — the DEV toggle (hand-flipped in DevToolsView for testing).
- `scheduler.enabled` — the PRODUCTION flag, written by auto-enable and (later) a Settings toggle.

Keeping them separate means a dev testing the toggle never trips the production auto-enable latch.

## Dev UI

DEV TOOLS → **Overnight Processing…** opens `OvernightDevView` in its **own window** — a simple
top-to-bottom checklist (not a cramped inline panel). A live status panel (helper + login item polled
every 2s, so approving in System Settings updates without a refresh) sits above four steps:
- **① Approve the root helper** — one "Approve helper" button that registers the daemon *and* jumps to
  System Settings to flip it on; shows `enabled ✓` when done.
- **② Launch at login** — a single toggle.
- **③ Test the 18h auto-enable** — a plain-language readout of what will happen, a **Wait** picker
  (18h real / 10s / 60s) to shorten the delay, and *Simulate first analyze done* / *Run check now* / *Reset*.
- **④ Manual arm (bypass)** — the time picker + on/off for a direct end-to-end wake test.

This is the dev cockpit; the shipping onboarding/Settings UX (Jesai) binds to the same seams
(`WakeHelperClient` / `LoginItem` / `OvernightScheduler`).

## Verification

- The daemon plist **bundles correctly** at `Contents/Library/LaunchDaemons/` and passes `plutil -lint`.
- The **auto-enable state machine** was driven headlessly (11/11 checks): stamp-once, delay math, the
  "not yet" hold, the prerequisite gate (unmet → flags setup, does not flip, does not latch → retries),
  the "user already enabled" latch, and latch-blocks-re-enable.
- The **approval round-trip** is confirmed working on a normal Xcode Debug build (`enabled ✓`) — it
  just isn't reachable from the *unsigned* headless CLI verify (that returns `.notFound`).

## Files

- `Scheduling/OvernightScheduler.swift` — the scheduler, the 18h auto-enable state machine, `ensureHelperReady`.
- `Scheduling/LoginItem.swift` — launch-at-login via `SMAppService.mainApp`.
- `Scheduling/WakeHelperClient.swift` — daemon register/status/deep-link + the four XPC ops.
- `Scheduling/WakeHelperInstaller.swift` — the PRODUCTION admin-password installer (decided 2026-07-04); also the DEBUG fallback in `ensureHelperReady`.
- `jesai.Sentient-OS-macOS.WakeHelper.plist` (project root) — the bundled SMAppService daemon plist + its Copy Files phase.
- `Proactive/ProactiveCycle.swift` — stamps "initial finished".
- `AppState.swift` / `Views/RootView.swift` — call `maybeAutoEnable()` at launch / after each cycle.
- `Views/Dev/OvernightDevView.swift` — the standalone dev window (checklist + live status).
- `Views/Dev/DevToolsView.swift` — the "Overnight Processing…" button that opens it.
- `Sentient_OS_macOSApp.swift` — the `OvernightDevView` window scene.
