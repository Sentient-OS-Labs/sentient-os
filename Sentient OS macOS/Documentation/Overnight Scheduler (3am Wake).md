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
- **The code-sign gate is system-enforced in EVERY config (reworked 2026-07-11):**
  `conn.setCodeSigningRequirement` armed with the daemon's OWN designated requirement — the app
  and the helper are the same signed binary, so "signed exactly like me" is airtight AND
  signer-agnostic (the Developer ID release, a dev's Apple Development build, an OSS self-build,
  even ad-hoc dev signing). The static identifier+anchor string in
  `WakeHelperConfig.clientRequirement` survives only as the fallback if self-inspection fails.
  This replaced a hand-rolled audit-token check whose private `value(forKey: "auditToken")` read
  came back empty on macOS 26 — every client "failed", DEBUG allowed-and-logged it, and the first
  Release build would have slammed the door on our own app (field-found 2026-07-11). Debug now
  exercises the exact gate Release ships. Client-side, `isReachable()` probes log quietly (a
  missing daemon is an expected state, not an error); real ops keep the loud XPC error line.
- ⚠️ **Liveness is the ONLY honest status (field-found 2026-07-11).** System Settings' App
  Background Activity toggle boots a disabled daemon OUT of launchd while leaving its plist on
  disk — so every file check reads green on a dead helper (and unprivileged
  `launchctl print system/…` answers "could not find service" for *everything*, loaded or not, so
  it can't tell either). The ground truth is `WakeHelperClient.isReachable()`: a real XPC
  `heartbeat` (the one op harmless in every state — mid-run it's what the app sends every 60s
  anyway; idle it arms a deadman whose firing is a no-op). `healthProbe()` classifies the verdict:
  **ready** (answers over XPC) · **disabled** (unreachable with the files all correct → the toggle
  is off; launchd honors it over any bootstrap, so only the user flipping it back on helps) ·
  **notSetUp** (stale/missing plist → the installer fixes it). `ensureHelperReady`, Settings →
  Health, onboarding's permissions step, and the home's health banner all gate on this probe —
  never on files alone.

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

**The morning-after caution:** the scheduler is the ONE caller that passes
`ProactiveCycle.run(scheduled: true, …)` — a failure in an unattended run classifies at the
cycle's catch sites (`Scheduling/OvernightCaution`: typed `usageLimit` first → a local
`codex login status` probe (works offline) → an `NWPathMonitor` snapshot → anything else records
NOTHING) into codex-signed-out · no-internet · usage-limit, persisted for the home's amber banner
(`HomeView.cautionBanner`). A watched Analyze Now records nothing (the takeover UI shows failures
live); the next fully successful cycle clears the record. Each caution also emits a PII-free
`overnight.caution{kind}` Sentry event. *(The home's banner slot also carries a LIVE health ladder
— `System/HealthCaution.swift`, red, outranks this amber event — see the Home doc.)*

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
dialog (osascript admin) that writes the LaunchDaemon plist into `/Library/LaunchDaemons`,
chowns/chmods it, and `launchctl bootstrap`s it. It's measured-and-working on real hardware,
self-heals when the binary path or signature goes stale (`isInstalledAndCurrent()`), and — the UX
line we hold — never sends the user into System Settings. **Settings → Permissions & Health's
"Overnight wake" fix button runs exactly this** (except the `disabled` verdict, whose only fix is
the Login Items switch — the button becomes "Turn On…" and deep-links there). The SMAppService.daemon
migration (a Login Items approval toggle) was considered and rejected.

- 🔒 **Verified launch (guards against a local root LPE).** The plist does NOT point
  `ProgramArguments` straight at the app binary — a drag-installed app lives in a *user-writable*
  bundle, so that would let any same-user process overwrite the binary and get their code run as
  root at the next wake/boot. Instead the daemon runs, as root:
  `/bin/sh -c "codesign --verify -R='<app DR>' '<app>' && exec '<binary>' --wake-helper"`. `codesign`
  (a root-owned system tool) verifies the bundle is genuine + untampered *before* `exec`; any tamper
  or foreign signature exits non-zero and `&&` blocks it — nothing runs as root. `exec` replaces the
  shell with the app binary, so the running daemon IS our app and the "signed like me" XPC gate above
  is unchanged. The requirement is the app's OWN designated requirement, captured at install via the
  shared `WakeHelper.selfDesignatedRequirement()` (signer-agnostic, exactly like the XPC gate) — it
  survives same-team Sparkle updates but rejects any other signer. Nested-framework tampering is
  separately blocked by Hardened-Runtime library validation, so only the main binary needed a gate.
- 🔒 **No install-time TOCTOU.** Root decodes the plist **directly** into `/Library/LaunchDaemons`
  from an in-memory base64 blob in the privileged command — there is no user-writable temp file a
  same-user process could swap between our write and root's read (which would otherwise install a
  plist *without* the codesign gate and defeat the fix). The plist itself is built with
  `PropertyListSerialization`, so the quote/bracket-heavy launch script is escaped correctly.

Two plist facts (both 2026-07-11):
- The plist carries **`AssociatedBundleIdentifiers`**, so the System Settings background item
  displays as **"Sentient OS"** — without it, a bare LaunchDaemon shows under the signing
  identity's human name (the "Jesai Tarun" jumpscare, field-seen).
- That key is part of `isInstalledAndCurrent()`'s currency check (alongside the verified-launch
  format, the binary path, and the current designated requirement), so an old plain-binary plist —
  or a moved / re-signed build — reads stale and refreshes on the next setup pass. ⚠️ And remember
  its limit: `isInstalledAndCurrent()` answers "are the files right", never "is it alive" — liveness
  questions go through
  `WakeHelperClient.isReachable()` / `healthProbe()` (see the privilege-model section).

**SMAppService plumbing survives for the dev cockpit only:**
- A LaunchDaemon plist is still bundled at `Contents/Library/LaunchDaemons/…WakeHelper.plist` (repo
  file at the project root, a "Copy wake-helper daemon plist" build phase) so
  `WakeHelperClient.register()` / `.status` / `openLoginItemsSettings()` keep working for
  experiments (`OvernightDevView` step ①).
- `OvernightScheduler.ensureHelperReady()` gates on `WakeHelperClient.healthProbe()` — ONE probe
  covers both install paths, since the production plist and the dev cockpit's SMAppService daemon
  share the mach service. `ready` → arm; `disabled` → surface setup and stop (a reinstall can't
  override the Login Items switch); `notSetUp` → DEBUG self-installs via the password installer,
  Release flags `needsSchedulerSetup` for the setup UX.

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
- `Scheduling/WakeHelperClient.swift` — daemon register/status/deep-link + the XPC ops + `isReachable()`/`healthProbe()` (the liveness ground truth).
- `Scheduling/WakeHelperInstaller.swift` — the PRODUCTION admin-password installer (decided 2026-07-04); also the DEBUG fallback in `ensureHelperReady`.
- `jesai.Sentient-OS-macOS.WakeHelper.plist` (project root) — the bundled SMAppService daemon plist + its Copy Files phase.
- `Proactive/ProactiveCycle.swift` — stamps "initial finished"; classifies scheduled failures.
- `Scheduling/OvernightCaution.swift` — the morning-after caution: classify + persist + clear.
- `AppState.swift` / `Views/RootView.swift` — call `maybeAutoEnable()` at launch / after each cycle.
- `Views/Dev/OvernightDevView.swift` — the standalone dev window (checklist + live status).
- `Views/Dev/DevToolsView.swift` — the "Overnight Processing…" button that opens it.
- `Sentient_OS_macOSApp.swift` — the `OvernightDevView` window scene.
