# Overnight Scheduler — Production Wiring & 18h Auto-Enable

The overnight scheduler wakes the Mac at 3am (lid shut), runs the exact same pipeline as the home's
Analyze Now (`IterativeRun .auto` → `ProactiveCycle`), then sleeps — so a fresh "For You" briefing is
waiting when you open the lid. The wake *mechanism* was already proven on real hardware; this doc
covers the **production wiring** that turns it from a dev toggle into something that arms itself:

1. **A** — the root helper installs via **SMAppService** (one-click System Settings approval).
2. **B** — the app registers as a **login item** so it's alive at 3am to host the run.
3. **C** — a **production enable flag** (separate from the dev toggle).
4. **D+E** — the app **auto-enables the scheduler 18 hours after the first full cycle**.

The in-app scheduler lives in `OvernightScheduler` (owned by `AppState`); it only runs while Sentient
is open. Everything logs to `~/Library/Logs/SentientOS/scheduler.log`.

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
  - **Gates on prerequisites** — only flips production ON once the root helper is **approved** *and*
    launch-at-login is on. If the 18h has elapsed but prerequisites aren't met, it sets
    `needsSchedulerSetup` (published, for the setup UX) and retries on the next tick — it never
    silently half-enables.
- **The wait is 18h** (`defaultAutoEnableDelay`); a dev key (`autoEnableDelaySeconds`) shortens it for testing.

## A — SMAppService daemon (production install)

The root wake helper is the same app binary relaunched with `--wake-helper` (main.swift branches
before SwiftUI). Production installs it via **`SMAppService.daemon`** instead of the old
admin-password path:

- A LaunchDaemon plist is **bundled** at `Contents/Library/LaunchDaemons/jesai.Sentient-OS-macOS.WakeHelper.plist`
  (repo file at the project root, copied in by a "Copy wake-helper daemon plist" build phase). It uses
  `BundleProgram` (the bundle-relative main executable) + `ProgramArguments` to pass `--wake-helper`,
  and `MachServices` for the XPC name. Label/service name match `WakeHelperConfig`.
- `WakeHelperClient.register()` registers it; `.status`/`.isReady` read the live state
  (`.enabled` = approved & ready · `.requiresApproval` = registered, awaiting the user ·
  `.notRegistered`/`.notFound` = not yet / not bundled / unsigned build).
  `openLoginItemsSettings()` deep-links to where the user approves.
- `OvernightScheduler.ensureHelperReady()` gates every arm: `.enabled` → go; `.requiresApproval` →
  flag setup and bail (approval is async + user-driven). **DEBUG dev builds** (unsigned → `.notFound`)
  fall back to the proven admin-password `WakeHelperInstaller`, so testing works without a signed build.

> ⚠️ SMAppService approval only works on a **signed Developer ID build launched from `/Applications`** —
> not an unsigned dev binary. The registration *logic* is complete and gated; the approval round-trip
> lights up once the app is signed + distributed.

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

DevToolsView → **OVERNIGHT PROCESSING** section (folds in the old scheduled-run time control):
- Scheduled run toggle + wake time + status.
- **Root wake helper** — Register/Approve, Open Login Items, live status, Refresh.
- **Launch at login** — toggle + live status.
- **18h auto-enable** — a live readout (initial-done time, fire time, fired/needs-setup), plus dev
  buttons: *Simulate initial done*, *Run check now*, *Reset*, and a delay override (seconds, 0 = 18h).

This is the dev cockpit; the shipping onboarding/Settings UX (Jesai) binds to the same seams.

## Verification

- The daemon plist **bundles correctly** at `Contents/Library/LaunchDaemons/` and passes `plutil -lint`.
- The **auto-enable state machine** was driven headlessly (11/11 checks): stamp-once, delay math, the
  "not yet" hold, the prerequisite gate (unmet → flags setup, does not flip, does not latch → retries),
  the "user already enabled" latch, and latch-blocks-re-enable.
- What needs a **signed build** to exercise (not verifiable on an unsigned dev binary): the actual
  System Settings approval of the daemon and the login-item registration round-trip.

## Files

- `Scheduling/OvernightScheduler.swift` — the scheduler, the 18h auto-enable state machine, `ensureHelperReady`.
- `Scheduling/LoginItem.swift` — launch-at-login via `SMAppService.mainApp`.
- `Scheduling/WakeHelperClient.swift` — daemon register/status/deep-link + the four XPC ops.
- `Scheduling/WakeHelperInstaller.swift` — DEBUG admin-password fallback installer.
- `jesai.Sentient-OS-macOS.WakeHelper.plist` (project root) — the bundled SMAppService daemon plist + its Copy Files phase.
- `Ingestion/ProactiveCycle.swift` — stamps "initial finished".
- `AppState.swift` / `Views/RootView.swift` — call `maybeAutoEnable()` at launch / after each cycle.
- `Views/DevToolsView.swift` — the OVERNIGHT PROCESSING dev section.
