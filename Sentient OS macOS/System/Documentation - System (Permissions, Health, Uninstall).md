# System (System/): permissions, live health, notifications, uninstall

The macOS integration layer: how Sentient detects and (where possible) grants the permissions it
needs, the live health ladder behind the home's red banner, notifications, the screen-awake hold, the
user's standing instructions, the app-support root, and the full uninstall teardown.

## Files

| File | Job |
|---|---|
| `Permissions.swift` | Full Disk Access detection + deep link + relaunch; Sentient screen-context permission and legacy Accessibility status; TCC status reads; official Automation preflight/request and scoped uninstall reset; the System Settings deep links. |
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
fresh process, the guarded restart handoff. It preserves the unsent composer, resolves Knowledge
leave consent, and drains the owned permission-check client. A ready child of the same signed
executable waits at most 15 seconds for final commit and actual parent exit before opening the same
bundle. Failed preparation or cancelled quit keeps the current app open; no second instance starts
first. Generic Health restarts retain Home, while a source-setup restart resumes that setup.
FDA can read false when the app is
launched from Terminal (TCC attribution). Onboarding's Grant… uses the floating drag panel with Sentient
itself as the card (see the Permission Gate doc).

## Sentient's screen context

Sentient's own Screen Recording grant supplies Sidekick's screen snapshots. `hasScreenRecording()`
uses a non-prompting system preflight; the floating guide carries the Sentient app into System
Settings. This preflight does not require Full Disk Access.
Sentient's Accessibility grant is also used by Double Tap to paste the unsent draft. Its old
CUA action path remains only for legacy migration/cleanup.
Active computer tasks use the native helper's action grants for every model backend.

`isTCCGranted(service:clientBundleID:)` reads `auth_value == 2` from the right database for the
service (the SIP-protected system database for Accessibility, ScreenCapture, AllFiles, ListenEvent,
PostEvent; the user database otherwise). These are optional diagnostic observations, never feature
admission: unreadable or stale signing-identity rows do not establish effective capability.

## Native computer-use grants

Every active model backend runs computer use through OpenAI's signed helper. Sentient carries the Apple Events
entitlement and uses `AEDeterminePermissionToAutomateTarget` off the main thread to check or request
Automation access. The helper is started through LaunchServices before querying, so a stopped target
is not mistaken for denied access. Background checks do not prompt. Visible permission setup requests unasked consent through the macOS dialog, and the user chooses Allow in that dialog.

The helper's Accessibility and Screen Recording readiness comes from a bounded, read-only check of
a temporary Sentient-owned window: unique AX marker plus decoded screenshot. Full Disk Access is
not needed. `NativePermissionCheck` retains process/configuration-scoped evidence in memory and
invalidates it on helper exit/change, dead connection or native permission failure. Passive Health
only observes that state; explicit setup or a user-started computer task can open the check window.
Unknown stays unverified rather than denied. Its grant rows carry the helper bundle to System Settings. Sentient's
own Screen Recording remains required for screen context; native actions do not require Sentient's
CUA-specific Accessibility grant. Native permission rows are shared by setup, upgrade and Health.

Normal startup and Factory Reset preserve Automation consent. Uninstall uses the supported `tccutil`
reset for Sentient's own Apple Events grants. No code edits a TCC database or resets another app's
permissions. The shared native helper and the user's Codex home remain intact.

## The live health ladder (`HealthCaution.probe`)

The sibling of `OvernightCaution` (which records a past event): this probes CURRENT state, on the home's
appear and every app foreground, and returns the worst un-muted issue:

1. **Chosen capabilities need attention:** only selected protected sources are checked for readability, after personal setup completes or that source has a previous successful read. No global Full Disk Access verdict blocks cloud or ordinary-folder sources. The overnight wake helper (`WakeHelperClient.isReachable()`) and launch at login are checked only when recurring overnight work is enabled or a scheduled analysis is pending.
2. **Codex gone or signed out** (the login check shells out, so its verdict is cached ~5 min; the home passes `forceCodexRecheck` while a codex banner is up so a fix clears on the next foreground). Signed-out is ChatGPT-backend only.
3. **Computer use regressed:** the selected runtime became unavailable, or a required grant has a confirmed failure, but only once its readiness latch is set (`computerUse.nativeEverReady` for OpenAI; `computerUse.everReady` for CUA). Unknown helper proof at launch, unavailable Automation checks, and generic probe errors are not permission denials. Passive refresh never opens the synthetic capability-check window. Confirmed Sentient capture loss, Automation denial, or helper capability denial can raise the banner; first-use setup remains deferred to an actual task. The binary-missing case stays quiet while the `ComputerUseUpgrade` window presents that same state.

Shared startup installation and verification do not count as a broken runtime while in progress.
Home rechecks health when installation finishes, including after a failure.
`Scripts/test_health_requirements.py` compiles this production ladder against wholly in-memory
preferences and synthetic capabilities, covering fresh Home, cloud-only setup, selected-source loss,
overnight-off/scheduled intent, unknown helper proof, and confirmed regressions.

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

FactoryReset also clears the persistent computer-use upgrade and its live coordination state after rewinding onboarding. Its MCP connector-state sweep excludes `mcp.mirror.*`; mirror settings remain intact. Uninstall removes local setup as well as generated knowledge, driven by `UninstallView`. Stages, in order, each with a whisper for
the sheet: the wake helper FIRST (the only stage that can be declined at its password prompt, so a
cancel aborts before anything irreversible; Try Again / Skip / Cancel), then the cloud copy (while the
Keychain password still exists to authorize the DELETE), the Keychain identity + the frontier-model
choice and its key, the knowledge base + orphan staging + the cycle store, the on-device model (all of
`~/Library/Application Support/SentientOS`), and the traces (Sentient's Apple Events reset, caches, saved
state, logs, and the whole defaults domain LAST so a live observer cannot re-persist a key). It raises
`AppState.isUninstalling` first so the home clears its cards and refuses to re-deal off the defaults
wipe. `finishAndQuit()` spawns a detached sweeper for the files a dying process resurrects on the way
out (the preferences plist, the support dir, saved state) and hard-exits with `exit(0)` (graceful
termination invites the frameworks to write state back and can wedge behind the presented sheet).

`MailAccountCloud.forgetLocalState()` cancels contact retries and removes local queue/auth data.
Neither reset nor uninstall deletes the email-only founder-feedback list or invitation/lifetime-access
records. Mirror deletion is attempted separately and can be delayed by network failure.

Deliberately untouched: the `.app` bundle (the gone screen asks the user to drag it to the Trash), all
of `~/.codex` (the user's own codex config and login), the Desktop gift keepsakes, and the
SIP-protected system TCC rows. The cua driver and its shim/screenshot caches go with the Application
Support and caches sweeps.

## Rules

- Managed data lives in `URL.sentientSupport`, app caches, the knowledge base and temporary staging. The native helper has the explicit shared location in the existing Codex home; computer-use setup never rewrites Codex configuration or login.
- Permission writes belong to macOS. Requests use its APIs; uninstall resets only Sentient's Apple Events access through `tccutil`.
- Health verdicts distinguish verified capability, explicit denial and unknown. A TCC row or installation file alone is not effective helper capability.
- Two destructive sequences (`FactoryReset`, `Uninstall`) live in exactly one place each; never duplicate them.

## Related docs

`Views/Permissions/Documentation - Permission Gate & Guide.md` (how grants are actually acquired), `Driver/Documentation - Native Computer Use.md` (the active helper and its grants), `Scheduling/Documentation - Overnight Scheduler & Wake Helper.md`, `Views/Settings/Documentation - Settings.md` (the Health pane and the Uninstall sheet), `Cloud/Documentation - Cloud - Codex Setup.md`.

## Permission restart validation

`Scripts/test_permission_relaunch_handoff.py` exercises the actual subprocess protocol with an
inert launch callback: parent lifetime, uncommitted/cancelled requests, expiry and launch failure.
`test_safe_relaunch.py` covers final termination approval, retained-client drainage, update rechecks,
active setup windows and private draft/reply persistence. `test_personal_setup_flow.py` compiles the
coordinator with in-memory preferences and inert services. None launches the real app or changes grants.
