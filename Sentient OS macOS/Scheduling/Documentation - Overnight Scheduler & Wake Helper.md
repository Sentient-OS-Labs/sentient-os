# The Overnight Scheduler & the Wake Helper (Scheduling/)

**Your Mac does the understanding while you sleep.** With Sentient running in the menu bar,
launch at login enabled, and overnight wake configured, the scheduler arms the next local wake
(3:00 AM by default; editable in Settings → System). Analysis may run on battery within the limits
below. Cloud models and connected services need their corresponding network access.

Scheduling owns the wake, not analysis. `ProcessingCoordinator` owns one analysis task for the app,
independent of Home, onboarding, or the progress window. `ProcessingPlan` persists the user's timing
choice and status; `ProcessingRun` executes the same selected-source and proactive pipeline for
manual and scheduled work. Sidekick readiness does not depend on completing that initial analysis.
Overnight preparation does not send proposed replies or execute card actions; the user starts those.

## Files

| File | Job |
|---|---|
| `OvernightScheduler.swift` | The in-app arm-wait loop, setup enablement and migration, configurable local wake time, serialized schedule replacement, and `SchedulerLog`. Delegates analysis to the shared coordinator. |
| `../Ingestion/ProcessingCoordinator.swift` | Owns the analysis task, admission checks, progress, pause/cancellation draining, awake lease, heartbeat, and stall/ceiling monitor. |
| `../Ingestion/ProcessingPlan.swift` | Durable timing intent and status, relaunch recovery, and the initial-analysis milestone. |
| `../Ingestion/ProcessingRun.swift` | Shared local, Gmail, Calendar, and curated MCP reads followed by `ProactiveCycle`. |
| `WakeHelper.swift` | The root LaunchDaemon (the app binary relaunched with `--wake-helper-managed`), narrow XPC operations, deadman timer, absolute awake ceiling, and code-signing gate. |
| `WakeHelperProtocol.swift` | The XPC contract and the shared names (`WakeHelperConfig`). |
| `WakeHelperClient.swift` | App-side XPC calls (reply/error/timeout-guarded), `SMAppService` registration/removal, and readiness probes (`isReachable`, `healthProbe`). |
| `WakeHelperMaintenance.swift` | Fixed-scope privileged cleanup: retires the legacy daemon after native approval and removes only Sentient helper state during uninstall. |
| `OvernightCaution.swift` | Cycle-failure classification (signed out · no internet · usage limit · input too large · disk full · stalled) and the persisted morning-after caution. |
| `PowerState.swift` | Shared thermal protection and unattended battery limits: 50% initial start, 30% update start, and 20% reserve. Also reads AC/battery state. |
| `LoginItem.swift` | Launch at login via `SMAppService.mainApp`. |

Logs: `~/Library/Logs/SentientOS/scheduler.log` (the app; flushed per line, the black box for an empty
morning) and `/Library/Logs/SentientOS-wakehelper.log` (root).

## The wake mechanism

Prior hardware testing of the wake mechanism established: a userspace power assertion does NOT hold a closed lid (a clamshell
sleep overrides idle-sleep prevention; the Mac then self-wakes in ~43 s maintenance bursts). Root
`pmset -a disablesleep 1` DOES hold it, continuously, and Gemma/Metal runs fine with the lid shut. A
scheduled `pmset` wake fires reliably, and the running app process survives sleep: the scheduler's
waiting Task simply freezes with the Mac and thaws at the wake. Those observations concern the wake
mechanism; they are not a hardware validation claim for the current shared processing pipeline.

## The root helper

The ONLY code that runs as root. It is the same app binary, relaunched by launchd with
`--wake-helper-managed` (`main.swift` branches before SwiftUI). Its wake operations are: `beginAwake` (disablesleep 1 + start the deadman),
`heartbeat` (feed the deadman; the app calls it every 60 s during a run), `endAwake` (disablesleep 0;
the deadman is stood down only if the pmset call succeeded), `armWake` (a `pmset schedule wake`,
idempotent per time; the armed spec is persisted so a restarted helper can still cancel it),
`cancelWake`, and the retained `cancelAllWakes` API (not used for ordinary scheduling). Additional
fixed-scope operations prepare readiness, remove helper state, cancel incomplete removal, and
synchronize the signed GUI client's diagnostics consent; callers cannot supply arbitrary paths or commands.

- **The deadman timer** lives in the helper, outside the app: if the app crashes mid-run and stops heartbeating, the helper restores normal sleep itself, so a bug can never leave a Mac awake all day. The helper also resets `disablesleep` defensively at launch.
- **The awake ceiling** is the deadman's sibling for the opposite failure: armed once per `beginAwake` for `WakeHelperConfig.maxAwakeSeconds` (6 hours) and deliberately never fed by heartbeats. The deadman catches a dead app (heartbeats stopped); the ceiling catches an alive but stuck one (still heartbeating, making no progress): when it fires, the helper restores normal sleep unconditionally. A successful `endAwake` stands both down together, and either one firing cancels the other.
- **Stale-wake hygiene:** when the app's XPC connection drops (quit, crash, force-quit) the helper cancels the armed wake, so a Mac with Sentient closed never wakes on a stale schedule; the loop cancels only Sentient's tracked wake before arming its replacement. It never clears other applications' scheduled wakes.
- **The client gate:** `setCodeSigningRequirement` with the daemon's OWN designated requirement ("signed exactly like me"; the app and the daemon are one binary), enforced by the system on every message in every build configuration. Signer-agnostic, so it holds for the Developer ID release, a dev's Apple Development build, and an OSS self-build alike. If self-inspection fails, the helper refuses all connections; there is no weaker fallback.

## Native helper setup and removal

`WakeHelperClient` registers the bundled LaunchDaemon through `SMAppService.daemon(plistName:)`.
Only explicit setup actions register it. When macOS requires approval, setup opens the guided
System Settings → Login Items flow. Registration is consent, not proof that the helper is running;
setup returns ready only after the signed XPC endpoint answers. There is no custom privileged shell
installer or `WakeHelperInstaller` in the current implementation.

The managed service has a distinct name from the legacy helper. After native approval, `prepare`
retires the old launchd job and its plist through `WakeHelperMaintenance`, which uses fixed commands
and paths. Cleanup verifies the old job is gone before removing its plist. Uninstall first asks the
helper to restore sleep and remove its own wake/state, then unregisters the service. A cancelled
incomplete uninstall can lift that removal fence through the explicit cancellation path.

## Registration and liveness

`healthProbe()` reports **ready**, **requiresApproval**, **notSetUp**, or **unavailable**. It checks
`SMAppService` status, calls `prepare` over XPC when enabled, and rechecks approval afterward.
`isReachable()` uses that readiness operation rather than `heartbeat`, so passive health checks do
not feed the awake deadman. Once legacy migration is complete, readiness probes are side-effect-free.
Scheduling requires `.ready`; registration or files on disk alone are insufficient. Every XPC wake
operation races its reply/error against a 30-second timeout and resumes its caller only once.

## Setup, enablement, and migration

`enableAfterSetup()` runs at setup completion and launch. Once onboarding is complete, a new
non-knowledge-base-only installation enables the production schedule immediately. It does not wait
for initial analysis, install the helper implicitly, or open a login prompt. The one-time
`scheduler.enabledAfterSetup` latch preserves existing explicit values of `scheduler.enabled` and
respects the old `scheduler.autoEnableFired` latch. The obsolete auto-enable delay preference is
removed; there is no 14-hour timer.

The scheduler can run when `dbg.scheduler.enabled` is on, when `scheduler.enabled` is on outside
knowledge-base-only mode, or when the coordinator has a pending first night. That explicit first-night
choice works in knowledge-base-only mode without enabling recurring production scheduling.
Onboarding completion is required, and Reset/Uninstall suspension disables scheduling. A user pause
cancels the pending wake and is never silently undone by the next overnight trigger.

## Local time and wake replacement

`dbg.scheduler.minutes` retains the shipped preference key. Valid values are minutes since midnight
from 0 through 1439; missing or invalid values use 180. `Calendar.nextDate` uses the current local
calendar, `.nextTime` for a missing DST time, and the first occurrence of a repeated time. Clock and
time-zone changes restart scheduling and recompute persisted scheduled intent.

Saving a clock time recomputes a pending first-night/deferred `ProcessingPlan.Record.due` as well as
the armed wake, preserving its notice. It does not enable a disabled schedule. Onboarding's overnight
choice and its displayed date use the same configured time.

Each restart cancels the previous scheduling task and waits for it to finish before touching the
helper. An in-flight XPC arm cannot be recalled by Swift task cancellation; draining it prevents an
old arm or cancellation from overtaking the latest choice. Before a new outer-loop arm, `cancelWake`
removes only the previously tracked Sentient wake. `armWake` is idempotent at the same timestamp,
not across different timestamps. A schedule edit never cancels `ProcessingCoordinator`'s separate
analysis task or releases its awake lease; replacement scheduling waits for that owned work if needed.

## The nightly run

The loop checks `healthProbe()` and launch at login, surfaces `needsSchedulerSetup` when either is
missing, and retries readiness checks. It does not install the helper itself. Once ready, it cancels
the prior owned wake, arms the persisted due date or next configured local time, and waits. It refreshes
the same wake approximately every five minutes. At the due time it calls
`ProcessingCoordinator.runScheduled()` and then schedules the next wake.

A pending first-night due date crossed during setup by less than a minute is honored immediately;
a stale persisted date is deferred to the next configured time. A waiting loop that resumes beyond
the helper's six-hour overnight window also defers the run and retains a notice. Manual work already
in progress satisfies the trigger: the coordinator does not enqueue a second analysis or override a
requested manual run or explicit pause.

The coordinator admits the current `ProcessingRequest` only when sources, required local model, and
scheduled power conditions are ready. A blocked scheduled run records `Scheduler.gated` and an
overnight diagnostic, then persists the next due date with a reason. Explicit Run now remains pending
when its model or sources are unavailable; the coordinator monitors readiness independently of windows.

For admitted overnight work, the coordinator obtains `beginAwake(1800)`, feeds the helper roughly
every 60 seconds, and holds an idle-system-sleep activity. `ProcessingRun` reads local sources through
`IterativeRun`, then selected Gmail, Calendar, and curated MCP sources, followed by `ProactiveCycle`
for a full cycle. Cancellation checks between legs prevent a draining read from starting a new leg.
The coordinator retains exclusive ownership through task completion and helper cleanup.

`ProcessingPlan` persists status and timing; ingestion checkpoints remain in `CycleStore`. On relaunch,
interrupted manual work becomes requested and interrupted overnight work becomes scheduled. Only a
successful complete full cycle marks initial analysis complete, using the existing
`scheduler.firstCycleCompletedAt` key. Partial first nights remain pending, including in
knowledge-base-only mode. Opening, closing, or hiding progress UI never starts or cancels analysis.

## Power and interruption rules

Battery processing defaults to enabled when `scheduler.allowBattery` has no saved value; an existing
false value remains respected. The Analysis control lets users change it. Actual admission and
monitoring use `PowerState`:

- Thermal critical blocks or pauses every run, including explicit Run now.
- Scheduled work may start on AC. On battery it requires permission plus at least **50%** for initial
  analysis or **30%** after initial completion. An unreadable battery level blocks an unattended start.
- During unattended work, battery at or below **20%**, or an unreadable battery while off AC, requests
  a safe stop. Explicit Run now bypasses battery and AC requirements.
- Low Power Mode is not an admission or pause condition in the current shared policy.

The coordinator checks active work approximately every five seconds. It requests cancellation after
70 minutes without progress, and enforces a six-hour maximum for overnight work. Progress callbacks,
phase changes, and model output refresh the progress timestamp. These checks live in the shared
owner; there is no separate scheduler `runNight` or `NightPulse` implementation.

A stop releases the idle-sleep activity and the owned helper awake hold promptly, while retaining
analysis exclusivity until the worker drains. `releaseAwake()` clears ownership before awaiting the
helper and coalesces concurrent cleanup, so a late completion cannot release a later run's hold.
A user pause remains paused; a non-user overnight interruption is scheduled for the next configured
time after draining. The helper's independent deadman and absolute ceiling remain the backstop if
the app dies or stops monitoring.

## The morning-after caution (`OvernightCaution`)

`classify(error)` turns a cycle failure into a kind the user can act on or should simply know about:
the typed usage-limit errors from every cloud stage → `usageLimit`; the typed `inputTooLarge` canary;
on the ChatGPT backend a 401/unauthorized marker in codex's own output (a token invalidated server-side
still reads logged-in locally) or a failing local `codex login status` → `loggedOut`; a failing network
snapshot → `noInternet`; anything else → nil (the UI only ever states what was verified). Three kinds are
recorded directly rather than classified: `.diskFull` (device storage failure), `.connectorAuth`
(a selected connector needs sign-in), and `.stalled` (the coordinator stopped a stalled or ceiling-limited night). The scheduled
run persists the kind (`overnight.caution`, `Scheduler.caution` analytics) and the home shows a quiet
amber capsule with a first-person message; a later fully successful cycle, or the banner's ✕, clears it.
The watched takeover shows the same kind live on its failed screen instead.

## Rules

- Never gate scheduler readiness on file checks; use `healthProbe`.
- The helper's surface must stay tiny; nothing else may run as root.
- Every XPC call must stay reply/error/timeout-guarded so nothing can hang at 3 AM.
- Register and remove the bundled daemon through `WakeHelperClient` and `SMAppService`; keep the per-message signing requirement fail-closed and privileged maintenance fixed-scope.
- The awake ceiling must never be fed by heartbeats; feeding it would turn it back into the deadman and reopen the alive-but-stuck hole it exists to close.
- Keep analysis ownership through cancellation and helper cleanup; scheduling or view changes must not create a second analysis task.
- Replace only Sentient's tracked wake, and drain old scheduler requests before a new arm; do not use `cancelAllWakes` for ordinary scheduling.
- Once a run releases its awake hold, late callbacks must not release it again or interfere with a later run.

## Related docs

`Proactive/Documentation - Proactive Intelligence.md` (the cycle the run executes), `Ingestion/Documentation - Ingestion Pipeline.md`, `System/Documentation - System (Permissions, Health, Uninstall).md` (`HealthCaution` and the health rows), `Views/Dev/Documentation - Dev Tools.md` (`OvernightDevView`).
