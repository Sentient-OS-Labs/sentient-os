# System (System/): permissions, live health, notifications, uninstall

The macOS integration layer: how Sentient detects and (where possible) grants the permissions it
needs, the live health ladder behind the home's red banner, notifications, the screen-awake hold, the
user's standing instructions, the app-support root, and the full uninstall teardown.

## Files

| File | Job |
|---|---|
| `Permissions.swift` | Full Disk Access detection + deep link + relaunch; the Automation grant for the codex computer-use helper (written into the user's TCC database); read-only status of the helper's Accessibility and Screen Recording (system TCC); Sentient's own Screen Recording; the System Settings deep links. |
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

## The Automation grant (Sentient → the codex computer-use helper)

To act, Sentient spawns `codex`, so macOS makes Sentient the TCC-responsible app; codex talks to its
bundled helper (`com.openai.sky.CUAService`, "Codex Computer Use.app") over Apple Events, which the
Automation service gates. This specific helper exposes no idle Apple Event endpoint, so macOS can show
no consent dialog at all (`AEDeterminePermissionToAutomateTarget` returns `procNotFound`), and without
the grant the very first computer-use action blocks forever. Terminal and Warp acquire the identical
grant the first time you run computer use from them.

`grantComputerUseAutomation()` therefore writes the one `kTCCServiceAppleEvents` row into the USER's
own TCC database (writable with the Full Disk Access the user already granted): client = Sentient,
indirect object = the helper, both code-requirement blobs generated at runtime from the live signed
bundles (so it is correct for any signer and contains nothing device-specific), `auth_value 2`, then
`killall tccd` so the row applies immediately. It authorizes exactly one thing: Sentient controlling its
own bundled helper. `revokeComputerUseAutomation()` deletes exactly that row (uninstall).
`selfHealComputerUseAutomation(context:)` probes and re-grants in the background if missing; it runs
right after a successful computer-use bootstrap, when Settings → Health opens, when the first-use
permission gate presents, and from Dev Tools. Idempotent, silent, fully guarded (no FDA or no helper on
disk = no-op).

## The helper's own grants (read-only)

The helper's **Accessibility** (move the mouse, type) and **Screen Recording** (see the screen) live in
the SYSTEM TCC database, which is SIP-protected: nothing but Apple's `tccd` can write it. So those are
status + deep-link only: `isTCCGranted(service:clientBundleID:)` reads `auth_value == 2` from the
right database for the service (system for Accessibility, ScreenCapture, AllFiles, ListenEvent,
PostEvent; the user database otherwise). The user grants them by dragging the helper into the list (the
Permission Guide's drag panel).

## Sentient's own Screen Recording

`hasScreenRecording()` (`CGPreflightScreenCaptureAccess`, never prompts) gates Sidekick's screen
stills. OPTIONAL by decision: no grant → text-only commands. It is granted through the drag panel with
Sentient as the card, not `CGRequestScreenCaptureAccess` (which does not reliably add the app to the
list on Tahoe). A preflight stays false until relaunch; the TCC read is the live truth the health rows
use.

## The live health ladder (`HealthCaution.probe`)

The sibling of `OvernightCaution` (which records a past event): this probes CURRENT state, on the home's
appear and every app foreground, and returns the worst un-muted issue:

1. **Essential permissions off:** Full Disk Access; the overnight wake helper (`WakeHelperClient.isReachable()`, the XPC ground truth a file check cannot fake); launch at login. All three were green in onboarding, so any red here is drift.
2. **Codex gone or signed out** (the login check shells out, so its verdict is cached ~5 min; the home passes `forceCodexRecheck` while a codex banner is up so a fix clears on the next foreground). Signed-out is ChatGPT-backend only.
3. **Computer use regressed:** the `~/.codex` payload vanished, or the helper lost Accessibility / Screen Recording, but ONLY once the `computerUse.everReady` latch is set (by the probe when everything reads healthy, and by the permission gate at its moment of truth; cleared by FactoryReset), so a user who never set it up is never nagged.

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

FactoryReset's strict superset, driven by `UninstallView`. Stages, in order, each with a whisper for
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
of `~/.codex` (the computer-use payload, config, and the user's own codex login), the Desktop gift
keepsakes, and the SIP-protected system TCC rows.

## Rules

- Never write anything outside `URL.sentientSupport`, the knowledge base folder, and the temp dir.
- The Automation grant authorizes Sentient → its own helper, nothing broader; do not widen it.
- Health verdicts must come from ground truth (an XPC probe, a TCC read), never a cached file check.
- Two destructive sequences (`FactoryReset`, `Uninstall`) live in exactly one place each; never duplicate them.

## Related docs

`Views/Permissions/Documentation - Permission Gate & Guide.md` (how grants are actually acquired), `Scheduling/Documentation - Overnight Scheduler & Wake Helper.md`, `Views/Settings/Documentation - Settings.md` (the Health pane and the Uninstall sheet), `Cloud/Documentation - Cloud - Codex Setup & Computer Use Bootstrap.md`.
