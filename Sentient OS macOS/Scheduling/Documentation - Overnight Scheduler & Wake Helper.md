# The Overnight Scheduler & the Wake Helper (Scheduling/)

At 3 AM the Mac wakes itself (lid shut is fine), reads what is new, updates the knowledge base,
prepares the morning cards, and goes back to sleep. This folder is the whole story: the in-app
scheduler, the tiny root helper that can wake and hold the Mac awake, its installer and XPC client,
the go/no-go gates, launch at login, and the classification of a failed night into an honest morning
banner. There is no scheduler-specific processing path: the run uses the same source selection, the
same `IterativeRun`, and the same `ProactiveCycle` as a hand-pressed Analyze Now.

## Files

| File | Job |
|---|---|
| `OvernightScheduler.swift` | The in-app scheduler (owned by `AppState`): the arm-wait-run loop, the 14 h auto-enable state machine, the night's stall watchdog (`runNight` + `NightPulse`), `runProcessing`, and `SchedulerLog`. |
| `WakeHelper.swift` | The root side: the LaunchDaemon (the app binary relaunched with `--wake-helper`), its six XPC ops, the deadman timer and the absolute awake ceiling, the code-signing gate. |
| `WakeHelperProtocol.swift` | The XPC contract and the shared names (`WakeHelperConfig`). |
| `WakeHelperClient.swift` | The app side: the XPC calls (each reply/error/timeout-guarded), liveness probing (`isReachable`, `healthProbe`), and the SMAppService plumbing the dev cockpit uses. |
| `WakeHelperInstaller.swift` | The production installer: one native password prompt writes the daemon plist into `/Library/LaunchDaemons` and bootstraps it. Also the uninstaller. |
| `OvernightCaution.swift` | Cycle-failure classification (signed out · no internet · usage limit · input too large · disk full · stalled) and the persisted morning-after caution. |
| `PowerState.swift` | The go/no-go gates: on AC (or on battery above a 40% charge floor when the user opted in), not Low Power Mode, not thermally critical. Also the battery charge read. |
| `LoginItem.swift` | Launch at login via `SMAppService.mainApp`. |

Logs: `~/Library/Logs/SentientOS/scheduler.log` (the app; flushed per line, the black box for an empty
morning) and `/Library/Logs/SentientOS-wakehelper.log` (root).

## The wake mechanism

Established on real hardware: a userspace power assertion does NOT hold a closed lid (a clamshell
sleep overrides idle-sleep prevention; the Mac then self-wakes in ~43 s maintenance bursts). Root
`pmset -a disablesleep 1` DOES hold it, continuously, and Gemma/Metal runs fine with the lid shut. A
scheduled `pmset` wake fires reliably, and the running app process survives sleep: the scheduler's
waiting Task simply freezes with the Mac and thaws at the wake.

## The root helper

The ONLY code that runs as root. It is the same app binary, relaunched by launchd with `--wake-helper`
(`main.swift` branches before SwiftUI). Six XPC ops: `beginAwake` (disablesleep 1 + start the deadman),
`heartbeat` (feed the deadman; the app calls it every 60 s during a run), `endAwake` (disablesleep 0;
the deadman is stood down only if the pmset call succeeded), `armWake` (a `pmset schedule wake`,
idempotent per time; the armed spec is persisted so a restarted helper can still cancel it),
`cancelWake`, `cancelAllWakes`.

- **The deadman timer** lives in the helper, outside the app: if the app crashes mid-run and stops heartbeating, the helper restores normal sleep itself, so a bug can never leave a Mac awake all day. The helper also resets `disablesleep` defensively at launch.
- **The awake ceiling** is the deadman's sibling for the opposite failure: armed once per `beginAwake` for `WakeHelperConfig.maxAwakeSeconds` (6 hours) and deliberately never fed by heartbeats. The deadman catches a dead app (heartbeats stopped); the ceiling catches an alive but stuck one (still heartbeating, making no progress): when it fires, the helper restores normal sleep unconditionally. A successful `endAwake` stands both down together, and either one firing cancels the other.
- **Stale-wake hygiene:** when the app's XPC connection drops (quit, crash, force-quit) the helper cancels the armed wake, so a Mac with Sentient closed never wakes on a stale schedule; the loop wipes all wakes before arming exactly one.
- **The client gate:** `setCodeSigningRequirement` with the daemon's OWN designated requirement ("signed exactly like me"; the app and the daemon are one binary), enforced by the system on every message in every build configuration. Signer-agnostic, so it holds for the Developer ID release, a dev's Apple Development build, and an OSS self-build alike. A static identifier + anchor requirement is the fallback if self-inspection fails.

## Installing the helper (`WakeHelperInstaller`)

The decided production path: ONE native "enter your password" dialog (osascript admin) writes the plist
into `/Library/LaunchDaemons`, `chown root:wheel`, `chmod 644`, `launchctl bootstrap`. Users are never
sent into System Settings. Two hardening properties:

- **Verified launch.** The daemon does not point at the app binary directly (a drag-installed app is user-writable, which would let any same-user process get code run as root). Its `ProgramArguments` are `/bin/sh -c "codesign --verify -R='<app's designated requirement>' '<app>' && exec '<binary>' --wake-helper"`: root-owned `codesign` verifies the bundle is genuine and untampered before `exec`; any tamper or foreign signature blocks it. The requirement is captured at install via `WakeHelper.selfDesignatedRequirement()`, so it survives same-team Sparkle updates and rejects any other signer.
- **No install-time race.** Root decodes the plist straight from an in-memory base64 blob embedded in the privileged command; there is no user-writable temp file to swap.

The plist carries `AssociatedBundleIdentifiers` so the System Settings background item reads "Sentient
OS", not the signer's name. `isInstalledAndCurrent()` answers "are the files right for THIS binary and
signature" (a moved app or a re-signed build reads stale and reinstalls); it does NOT answer "is it
alive". `uninstallAsync()` is the mirror image behind the same one prompt.

## Liveness is the only honest status

System Settings' App Background Activity toggle boots a disabled daemon OUT of launchd while leaving
its plist on disk, so every file check reads green on a dead helper (and unprivileged `launchctl print`
cannot tell either). `WakeHelperClient.isReachable()` sends a real `heartbeat` over XPC (harmless in
every state), and `healthProbe()` classifies: **ready** (answers) · **disabled** (unreachable, files
correct → the toggle is off; only the user flipping it back on helps) · **notSetUp** (stale or missing
plist → the installer fixes it). The scheduler, Settings → Health, onboarding's permissions step, and
the home's health banner all gate on this probe, never on files alone.

## The nightly run

The loop: ensure the helper is ready (`healthProbe`; DEBUG builds self-install via the password
installer, Release flags `needsSchedulerSetup` for the setup UI) → `cancelAllWakes` → arm ONE wake for
the configured time (3:00 AM by default; a dev key can override) → wait, re-arming every ~5 min so the
helper's record stays fresh → run → re-arm for tomorrow.

`runProcessing`: read the selected sources through the shared `SourceSelection.current` (persistent
custom folders included) and the Gmail/Calendar flags and curated MCP KB selections for the active subscription engine → skip if nothing is
enabled or the model is missing → **the go/no-go gates** (`PowerState.overnightBlockReason`: on battery
without the opt-in, on battery below the 40% charge floor with it, Low Power Mode on AC, or thermally
critical → log, `Scheduler.gated`, try again tomorrow; thermal is a start condition only) →
`beginAwake(1800)` + a 60 s heartbeat task → `IterativeRun(.auto)` over the connectors → the Gmail,
Calendar, and curated MCP iterative legs → **`ProactiveCycle.run(scheduled: true)`** → cancel the heartbeat → `endAwake`
→ the Mac idle-sleeps.

**Battery nights are an opt-in.** The default is AC-only. The home's Analysis dropdown carries a quiet
"Run on battery too" switch (`scheduler.allowBattery`; hidden on desktop Macs). With it on, a night
starts on battery when the charge is at or above `PowerState.batteryFloorPercent` (40%: a heavy night
can drain 15 to 30 percent, and the floor keeps the morning Mac usable). An opted-in battery night also
ignores Low Power Mode, which is commonly set to "Only on Battery" and would otherwise silently block
every battery night; the run just goes slower. The power log line records the charge either way.

**Every night races a stall watchdog** (`runNight`). The run rides its own Task and touches a shared
`NightPulse` on every sign of progress (each device item, each leg start and end, MCP ingestion events, every proactive
phase); the watchdog reads the pulse once a minute. After 70 minutes with no progress (the one failure
no error, timeout, or crash covers: the app alive and heartbeating, but nothing moving) the watchdog
cancels the run, restores sleep itself, records the `.stalled` morning caution, and sends a
structure-only Sentry warning; the loop then re-arms tomorrow's wake as usual. The 70 minutes sits
deliberately just past the longest single CLI timeout (1 hour), so the watchdog can never end a healthy
call that is about to finish or time out cleanly on its own. Before cancelling, the watchdog latches
"sleep already restored" on the pulse; every leg boundary checks for cancellation and exits through a
latch-aware `releaseAwake`, so a stuck run that thaws hours later neither starts fresh cloud legs into
the user's morning nor touches the helper while a later night may be holding the Mac awake.

Full Disk Access can read false when the app is launched from Terminal (TCC attribution), which silently
excludes the database sources; the run's log lines surface it.

The watchdog receives a one-shot outcome from the processing task or its timer. It never waits on a
task-group child that is itself waiting for a wedged run. Parent cancellation cancels the owned run and
ends the wait without recording a stall. The heartbeat stops after the watchdog releases sleep; late
completion checks cancellation before another device/cloud leg or completion telemetry. MCP reads
contribute progress pulses and retain connector-auth/usage-limit cautions alongside the stalled kind.

## The 14 h auto-enable

Right after the first big analysis, everything is caught up; a 3 AM run five hours later would find
almost nothing and produce an empty morning. So the scheduler turns itself on **14 hours after the first
full `ProactiveCycle` finishes** (`noteFirstCycleCompleted` stamps that once). `maybeAutoEnable()` runs
at launch, after every cycle, and from a one-shot timer armed for the 14 h mark. It is idempotent,
latches so it acts at most once, never fights a user who turned the scheduler off, returns early in
knowledge-base-only mode (not latched, so an upgrade plus reset starts the clock fresh), and only flips
the production flag on when the helper is installed and launch at login is on; otherwise it sets
`needsSchedulerSetup` and retries on the next tick.

Two enable keys, either one runs the loop: `dbg.scheduler.enabled` (the dev toggle) and
`scheduler.enabled` (production, written by auto-enable). Only the production flag latches, so a dev
testing the toggle never burns the one-shot.

## The morning-after caution (`OvernightCaution`)

`classify(error)` turns a cycle failure into a kind the user can act on or should simply know about:
the typed usage-limit errors from every cloud stage → `usageLimit`; the typed `inputTooLarge` canary;
on the ChatGPT backend a 401/unauthorized marker in codex's own output (a token invalidated server-side
still reads logged-in locally) or a failing local `codex login status` → `loggedOut`; a failing network
snapshot → `noInternet`; anything else → nil (the UI only ever states what was verified). Three kinds are
recorded directly rather than classified: `.diskFull` (device storage failure), `.connectorAuth`
(a selected connector needs sign-in), and `.stalled` (the watchdog ended a night without progress). The scheduled
run persists the kind (`overnight.caution`, `Scheduler.caution` analytics) and the home shows a quiet
amber capsule with a first-person message; a later fully successful cycle, or the banner's ✕, clears it.
The watched takeover shows the same kind live on its failed screen instead.

## Rules

- Never gate scheduler readiness on file checks; use `healthProbe`.
- The helper's surface must stay tiny; nothing else may run as root.
- Every XPC call must stay reply/error/timeout-guarded so nothing can hang at 3 AM.
- Change the daemon plist only through the installer; both `WakeHelper.clientRequirement` and the plist's codesign requirement derive from the same designated requirement.
- The awake ceiling must never be fed by heartbeats; feeding it would turn it back into the deadman and reopen the alive-but-stuck hole it exists to close.
- Once the watchdog has restored sleep for a night, no exit path of that night may call `endAwake` again (the `NightPulse` latch enforces this): a later night could legitimately be holding the Mac awake.

## Related docs

`Proactive/Documentation - Proactive Intelligence.md` (the cycle the run executes), `Ingestion/Documentation - Ingestion Pipeline.md`, `System/Documentation - System (Permissions, Health, Uninstall).md` (`HealthCaution` and the health rows), `Views/Dev/Documentation - Dev Tools.md` (`OvernightDevView`).
