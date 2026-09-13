# System (System/): permissions, live health, notifications, uninstall

The macOS integration layer: how Sentient detects and (where possible) grants the permissions it
needs, the live health ladder behind the home's red banner, notifications, the screen-awake hold, the
user's standing instructions, the app-support root, and the full uninstall teardown.

## Files

| File | Job |
|---|---|
| `Permissions.swift` | Full Disk Access detection + deep link + relaunch; Sentient's own Accessibility and Screen Recording status (the cua driver's action grants); TCC status reads; the legacy 1.x Automation-row cleanup; the System Settings deep links. |
| `HealthCaution.swift` | The home's LIVE health banner: probes current state, most severe first, and reports the worst un-muted issue. |
| `Notify.swift` | The notification permission ask and `now(title:body:)`. |
| `DisplayAwake.swift` | Keeps the screen on during long foreground work (onboarding, a home-launched first analysis) via `ProcessInfo.beginActivity`. Not the root `pmset` path. |
| `CustomInstructions.swift` | The one source of truth for the two Settings text fields: `proactive.instructions` (fed to both proactive prompts) and `sidekick.context` (fed to the command prompt). |
| `AppSupport.swift` | `URL.sentientSupport` = `~/Library/Application Support/SentientOS/`, the ONE root everything on disk lives under (the model and its cache, the cycle store, download staging). |
| `Uninstall.swift` | The full teardown behind Settings → System → Uninstall Sentient. |

## Full Disk Access

There is no API to request FDA. `fdaProbeDetail()` tries to open known FDA-gated files (`chat.db`,
Safari's bookmarks, the user TCC.db) and treats `EPERM` / `EACCES` as denied (`ENOENT` moves to the
next probe). `hasFullDiskAccess()` is the bool; `reportProbe()` emits the `fda.probe` diagnostic once
per run when a database source is selected and FDA is not cleanly granted (the top "empty morning"
signal). Granting = open the pane (`openFullDiskAccessSettings`) and, since a grant only applies to a
fresh process, `relaunch()` (`open -n` the bundle, then terminate). FDA can read false when the app is
launched from Terminal (TCC attribution). Onboarding's Grant… uses the floating drag panel with Sentient
itself as the card (see the Permission Gate doc).

## Sentient's own action grants (the cua driver's hands and eyes)

The cua driver runs inside Sentient's TCC responsibility chain (see the Driver doc), so acting on the
Mac needs exactly two grants and both are **Sentient's own**: **Accessibility** (click, type — probed
live with `AXIsProcessTrusted`, granted through the native system prompt) and **Screen Recording**
(see the screen — `hasScreenRecording()` via `CGPreflightScreenCaptureAccess`, never prompts; granted
through the drag panel with Sentient as the card, since `CGRequestScreenCaptureAccess` does not
reliably add the app to the list on Tahoe). A preflight stays false until the process is replaced, so
the FDA-backed TCC read (`isTCCGranted`) rides along as the live truth the health rows use — and a
grant landing marks the daemon for replacement, because macOS caches TCC answers per process. Screen
Recording also gates Sidekick's fire-time screen stills.

`isTCCGranted(service:clientBundleID:)` reads `auth_value == 2` from the right database for the
service (the SIP-protected system database for Accessibility, ScreenCapture, AllFiles, ListenEvent,
PostEvent; the user database otherwise).

## Legacy cleanup: the 1.x Automation row

Sentient 1.x drove computer use through OpenAI's bundled "Codex Computer Use" helper and wrote itself
a `kTCCServiceAppleEvents` row (Sentient → the helper) into the user's TCC database so headless runs
never stalled on a consent macOS had no prompt for. The cua driver sends no Apple Events, so on an
updated Mac that row is dead weight — and ours to sweep. `revokeComputerUseAutomation()` deletes
exactly that row: called once per launch (cheap, idempotent — `AppState.init`) and by Uninstall. The
helper's own rows live in the SIP-protected system TCC database and are not ours to remove; with
nothing driving the helper they are inert.

## The live health ladder (`HealthCaution.probe`)

The sibling of `OvernightCaution` (which records a past event): this probes CURRENT state, on the home's
appear and every app foreground, and returns the worst un-muted issue:

1. **Essential permissions off:** Full Disk Access; the overnight wake helper (`WakeHelperClient.isReachable()`, the XPC ground truth a file check cannot fake); launch at login. All three were green in onboarding, so any red here is drift.
2. **Codex gone or signed out** (the login check shells out, so its verdict is cached ~5 min; the home passes `forceCodexRecheck` while a codex banner is up so a fix clears on the next foreground). Signed-out is ChatGPT-backend only.
3. **Computer use regressed:** the cua-driver binary vanished, or Sentient's own Accessibility / Screen Recording grants did — but ONLY once the `computerUse.everReady` latch is set (by the probe when everything reads healthy, and by the permission gate at its moment of truth; cleared by FactoryReset), so a user who never set it up is never nagged. The binary-missing case stays quiet while the `ComputerUseUpgrade` window is presenting on that exact state (the same message twice helps no one) and still covers the window-less case (the driver vanishing mid-session).

Nothing persists; broken shows, fixed melts away. ✕ mutes an issue KIND for the session (a lower rung may
then surface). Nothing at all on the free-plan home. The banner's Open Settings lands on Permissions &
Health.

## Notifications (`Notify`)

`ask()` requests alert authorization only while the status is still undetermined (onboarding's
permissions screen fires it silently on appear). `now(title:body:)` is live for the "Sentient just
updated." notice; a denied or undetermined status suppresses it and sends the `Notify.notAuthorized`
analytics signal (a user choice, not a defect). `AppState` additionally banks *provisional* (quiet)
authorization at launch once onboarding is complete. The proactive-reminders tier will ride the same
call when it lands. Everything is silent under `SENTIENT_SELFTEST` (a headless harness cannot answer
the dialog).

## Uninstall (`Uninstall.run`)

FactoryReset also clears the persistent computer-use upgrade and its live coordination state after rewinding onboarding. Its MCP connector-state sweep excludes `mcp.mirror.*`; mirror settings remain intact. Uninstall is FactoryReset's strict superset, driven by `UninstallView`. Stages, in order, each with a whisper for
the sheet: the wake helper FIRST (the only stage that can be declined at its password prompt, so a
cancel aborts before anything irreversible; Try Again / Skip / Cancel), then the cloud copy (while the
Keychain password still exists to authorize the DELETE), the Keychain identity + the frontier-model
choice and its key, the knowledge base + orphan staging + the cycle store, the on-device model (all of
`~/Library/Application Support/SentientOS`), and the traces (the TCC Automation row, caches, saved
state, logs, and the whole defaults domain LAST so a live observer cannot re-persist a key). It raises
`AppState.isUninstalling` first so the home clears its cards and refuses to re-deal off the defaults
wipe. `finishAndQuit()` spawns a detached sweeper for the files a dying process resurrects on the way
out (the preferences plist, the support dir, saved state) and hard-exits with `exit(0)` (graceful
termination invites the frameworks to write state back and can wedge behind the presented sheet).

Deliberately untouched: the `.app` bundle (the gone screen asks the user to drag it to the Trash), all
of `~/.codex` (the user's own codex config and login), the Desktop gift keepsakes, and the
SIP-protected system TCC rows. The cua driver and its shim/screenshot caches go with the Application
Support and caches sweeps.

## Rules

- Never write anything outside `URL.sentientSupport`, the app's caches dir, the knowledge base folder, and the temp dir.
- The legacy Automation cleanup only ever DELETES its one row; the app never writes TCC grants again.
- Health verdicts must come from ground truth (an XPC probe, a TCC read), never a cached file check.
- Two destructive sequences (`FactoryReset`, `Uninstall`) live in exactly one place each; never duplicate them.

## Related docs

`Views/Permissions/Documentation - Permission Gate & Guide.md` (how grants are actually acquired), `Driver/Documentation - Driver (cua-driver).md` (the daemon those grants power), `Scheduling/Documentation - Overnight Scheduler & Wake Helper.md`, `Views/Settings/Documentation - Settings.md` (the Health pane and the Uninstall sheet), `Cloud/Documentation - Cloud - Codex Setup.md`.
