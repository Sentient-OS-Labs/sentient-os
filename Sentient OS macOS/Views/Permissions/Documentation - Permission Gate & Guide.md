# The Permission Gate & the Floating Guide (Views/Permissions/)

How visible setup surfaces acquire the grants needed for computer use. Background health checks
only check permission state and never request consent. Three pieces:

1. **`ComputerUseGate`**: the one-time setup window that appears the first time the user fires anything
   that acts on the Mac (the command bar, Sidekick, a card's fire) while a required grant is missing.
2. **`PermissionGuide` + `PermissionDragPanel` + `SettingsWindowTracker`**: the floating System-Settings
   companion that opens the right privacy pane and carries a draggable `.app` card the user drops
   straight into the permission list (no "+", no file picker).
3. **`ComputerUseUpgrade`**: the one-time migration window for Macs updating from the 1.x era of
   computer use.

## Files

| File | Job |
|---|---|
| `ComputerUseGate.swift` | The interception (`intercept`, `interceptBeforeStart`, `presentVoiceFixIfDenied`), the grant probes, the AppKit-owned floating window, Continue. |
| `ComputerUseGateView.swift` | The window's face: the grants as `StatusLine` rows in two groups (`SentientPermissionRows` is shared with the upgrade window). |
| `NativePermissionSetup.swift` | Restart workflow receipt; never permission evidence. First-use confirmation permits a normal task only in a later app process. |
| `ComputerUseUpgrade.swift` | Persistent upgrade coordination, native setup window, installation, readiness, release, and reset. |
| `ComputerUseWindowGuard.swift` | Excludes regular scene content during setup and registers its AppKit window for hiding. |
| `PermissionGuide.swift` | `guide(pane, dragging:)`: open the pane and raise the panel; drag vs instruction mode; close. |
| `PermissionDragPanel.swift` | The borderless, non-activating panel that flies from the pressed button to just below the Settings window and follows it; the Finder-shaped drag source. |
| `SettingsWindowTracker.swift` | Follows the System Settings window: a 30 Hz zero-permission `CGWindowList` poll plus AX observers when available; 12 misses = Settings closed → the panel dismisses. |

The tracker, panel, and drag-source mechanics are adapted from jaywcjlove/PermissionFlow (MIT;
attribution in the file headers). Details there that must not be "simplified": `NSHostingView.
sizingOptions = []` (otherwise the hosting view re-advertises its own size every layout pass and the
panel strands off-screen), the Finder-shaped pasteboard mix, and the CG → AppKit coordinate flip.

The Sidekick popup keeps **One-time setup** and uses **Let Sidekick use your computer** as its title.
Its compact layout keeps muted Computer use and Sentient permissions headings, removes Not granted
labels, and uses **Grant** buttons for
remaining steps. Release hides verified rows; Debug deliberately shows all rows. Settings keeps its full permission layout. Double Tap uses the same compact layout and Grant
buttons for Sentient’s own Accessibility and Screen Recording. Its Done button still requires
both real grants; once ready, a short hint tells the user to focus their reply field and tap again.

The Sidekick and Double Tap gates add a localized, slowly moving indigo/blue rim with a small warm accent. Its
opaque center separates it from Home’s broader color washes. Only the decorative Canvas updates
at animation cadence; the effect is noninteractive and stops for Reduce Motion, Low Power Mode,
or a hidden/inactive window. Voice repair retains its existing background.

## The grants

The required grants follow the selected runtime:

| Runtime | Required grants |
|---|---|
| All active backends / OpenAI | Sentient-to-helper Automation; OpenAI helper Accessibility and Screen Recording; Sentient Screen Recording for screen context. |
| All | Microphone and Speech are optional; typed commands work without them. |

OpenAI Automation is checked through Apple's asynchronous API after launching the signed helper.
Visible permission setup requests unasked Automation consent through the macOS dialog. Asking for
Automation never starts a capability test. The helper's Accessibility and Screen Recording rows use
Sentient's floating drag guide. A completed copy drop inside the tracked Settings window changes
only that row to **Restart to finish**; cancelled, misplaced and stale-guide drops do nothing.
The user opens each required grant action, enables its macOS toggle, and selects **Restart Sentient**.
There is no confirmation checkbox or explanatory block. Restart enables once each helper grant
action has been opened (or that grant is verified), and Automation/Sentient Screen Recording are
either already granted or their grant actions have been opened. Automatic Automation probing does
not count as a button click. Grant actions and drags never create permission proof. Full Disk Access is not required and the gate never reads TCC databases.

After a confirmed relaunch, rows without live proof say **Ready to try**. `isReadyForTask` permits an
ordinary native request; `allRequiredGranted` continues to mean actual capability evidence. The
macOS helper enforces access during the task. Known denial keeps the workflow blocked for recovery.

Native first-use setup checks both the compatible Codex CLI and helper installation, and exposes
the shared installer when either needs preparation. Claude users are not asked for a ChatGPT login. Existing grants are reused. `SentientPermissionRows` and
`NativeComputerUsePermissionRows` keep first-use, migration and Settings consistent.

## The gate (`ComputerUseGate`)

`intercept(action)` returns true when it holds an action for required setup or a readiness check.
First-use and post-restart admission never open the synthetic test window. Missing installation,
Sentient Screen Recording or Automation still hold the task in our setup screen. A confirmed restart
allows real work to try without claiming either helper grant. Closing or cancelling drops the held
action, and late startup results cannot revive it. Voice remains optional for typed requests.
The legacy `computerUse.micSpeechOffered` key remains only for reset cleanup.

Before waiting, `CommandRunModel` writes a private `PermissionWaitDraft` bound to its run ID and
conversation generation. It must successfully remove that snapshot before any screen context,
router or model work. Explicit Stop/cancel retires it; approved application termination preserves
it for macOS's own Quit and Reopen. Next launch can restore it only into an empty composer of the
same generation, as an unsent draft. It is never submitted automatically.

For native setup, **Restart Sentient** uses **Save request & relaunch** internally only for
the exact pre-inference waiter with an empty composer. It preserves request/reply, cancels and
drains only that waiter, then uses the ordinary guarded restart. An already executing task cannot
use that path. Other busy work blocks restart with an explanation; a gate-held external task can
be stopped explicitly before restarting. The setup window remains available if saving the draft
or preparing the relaunch fails. No saved request is automatically submitted after relaunch.

The restart receipt is bound to the confirming process. Closing a guide and relaunching without
selecting Restart Sentient does not complete setup. Before the first post-restart request, an exclusive runtime
lease protects a graceful stop of only Sentient's idle helper. Active work and foreign helpers are
never stopped by this preparation. Confirmation survives later launches until reset or a new setup
round; it remains separate from grant evidence.

### Official helper fallback

A native `-10009`/`-10014` or exact ScreenCaptureKit user denial permits one recovery attempt per task.
`NativeComputerUseServer` uses its existing authenticated, model-free MCP session to request
`get_app_state` for System Settings. The helper presents its own permission UI when needed; its
Chrome extension step is optional. Successful text plus a decodable screenshot completes recovery.
Timeout, dismissal, helper exit or Stop do not. The failed original action is never replayed and
still reaches the agent as an error with fresh-read guidance. Recovery shares the original request's
bounded time budget. Further failures leave **Open helper setup** available in our permission screen.
Auth failures, app approvals/policy blocks, missing windows, timeouts and ordinary interaction errors
never trigger this fallback. Reset/new setup invalidates late recovery results.

`presentVoiceFixIfDenied()` is used only after deliberate voice input encounters denied Microphone or
Speech access. Its voice-only window has Done and no held typed action. Unasked voice permission
continues through the native voice-input request. Settings retains its separate voice controls.

### Effective helper readiness without Full Disk Access

`NativePermissionReadiness` validates one `get_app_state` reply for a temporary Sentient-owned window.
It requires a fresh unique marker in the accessibility text and a decodable screenshot from the same
read. The marker is not sent to the tool, so request echo cannot establish access. `list_apps`,
AX text alone, a screenshot alone, a stale marker, timeout, interrupted window or generic error never
turns the rows green. An exact ScreenCaptureKit user-denied domain/code identifies Screen Recording
as denied; unrelated auth, policy and transport failures remain unknown with their actual error.

The marker-based check is retained for explicit diagnostics and validation fixtures, not ordinary
onboarding or task admission. Permission recovery uses the helper setup request instead, with no
custom test window. `NativePermissionCheck` serializes explicit setup/diagnostic operations and
retains successful helper PID/configuration and connection-scoped evidence. Passive Health observes
that evidence without opening a window. Reset/uninstall drains checks and clears workflow receipts.

Passing required checks latches `HealthCaution`'s native readiness history. The isolated fixtures
`test_native_permission_readiness.py`, `test_native_permission_lifecycle.py` and
`test_computer_use_gate.py` cover no-FDA evidence, malformed/partial replies, cancellation, process
lifecycle, concurrent callers, and held-action ownership without real grants or app storage.
Signed `NativeComputerUseLab` mode `permission-readiness` exercises the real read-only check and
records booleans for effective AX/capture and optional TCC-read availability. Run it with isolated
storage/runtime paths; an external fixture sandbox can deny both TCC database reads to exercise the
no-FDA path. It never asks for Automation, changes grants or stores screenshots, and closes the
retained proof client before finishing. A competing helper is reported rather than terminated.


The window is AppKit-owned (a floating `NSWindow`, black, hidden title) so it can appear over OTHER
apps; Sidekick fires from anywhere and a SwiftUI `Window` scene cannot be raised from the coordinator.
Analytics: `PermissionGate.shown` / `.continued`.

## The upgrade window (`ComputerUseUpgrade`)

Migration is prepared by `AppState` before regular scenes and Sidekick start. Fresh installs retain
onboarding. All active backends share native pending, deferred and ready state. CUA history is
recognized as a reason to migrate, never as proof that native permissions are ready.
An onboarded user enters native migration when prior computer-use readiness, a CUA installation
receipt or binary, or an earlier deferred migration establishes existing setup history.
Earlier deferral is treated as unfinished setup. Native completion remains separate from CUA history.

The flow is pitch → shared installation → required grant actions → restart → normal task.
Failure is retryable. Completing it
requires a fresh readiness check and an explicit Done action. Native migration is mandatory:
the regular interface stays unavailable until installation and required permissions are ready.
Closing or minimizing setup does not release the interface, and quitting preserves pending setup for
the next launch. Errors and permission fixes remain in the setup window. Already-ready installations
are recognized at launch without requiring another migration.

The native, normal-level window has close, minimize, resize/fullscreen controls, a unified dark title
bar, and a 560-point content column. Its copy describes preparing computer use for the selected engine. This window has no privacy footer; the app's other trust surfaces retain theirs. Long
installation status and error messages wrap instead of truncating.

`ComputerUseWindowGuard` excludes regular scene content and registers each scene's `NSWindow` for
hiding. Enforcement applies only to registered regular windows, leaving permission prompts and the
floating guide usable. Close and minimize never release the gate. Activation can reopen a closed
setup but does not undo minimization; an explicit Dock/menu Open request restores it. Window-order
notifications hide regular windows without refocusing setup, preventing focus loops.

Done clears pending state, removes enforcement observers, closes setup, restores the requested hidden
windows, starts Sidekick/notch once, and focuses or creates home. The menu-bar label supplies home
creation even on a launch with no regular scenes. Factory Reset uses `ComputerUseUpgrade.reset()`
after the onboarding rewind to clear both persisted and live migration state. A late installer result
cannot revive a reset session; the shared download itself is not cancelled.

For DEBUG visual checks, `--preview-computer-use-upgrade` forces pitch for an onboarded user without
writing or clearing the pending flag. Release ignores it. The preview does not mock installation,
permissions, or other AppState services; use fixtures for destructive or missing-grant scenarios and
never commit the flag to the shared scheme.

## The guide (`PermissionGuide`)

`guide(pane, dragging: appURL)` opens the System Settings pane and raises the panel, which flies from
the mouse location to just below the Settings window's content area and follows it. **Drag mode**
(`appURL` set): the panel carries the `.app` card whose drag payload is shaped like a Finder file drag
(the exact pasteboard mix System Settings accepts); while dragging, the panel goes mouse-transparent so
the drop lands in Settings. **Instruction mode** (`appURL` nil): toggle-only panes with no drag target
("Flip Sentient OS on under App Background Activity"). Panes: Full Disk Access (onboarding + Health),
Screen Recording and Accessibility (the gate + Health), and Login Items (instruction). The card is Sentient or the native helper, matching the requested grant. One
panel at a time; System Settings quitting dismisses it; a gear on the panel brings a buried Settings
back to front.

## Where it is wired

`CommandCoordinator.submit` (the bar, Sidekick, notch typing), `ForYouModel.run` (real cards), `AppState` and all regular app scenes
(`ComputerUseUpgrade` plus `ComputerUseWindowGuard`), onboarding's permissions step (FDA drag, Login Items
instruction), and Settings → Health (FDA, Accessibility, Screen Recording).

## Related docs

`Driver/Documentation - Native Computer Use.md` (the helper grants and Sentient’s screen-context permission),
`System/Documentation - System (Permissions, Health, Uninstall).md` (the probes),
`Notch Magic/Documentation - Sidekick - General.md`, `Views/Settings/Documentation - Settings.md`,
`Views/Onboarding/Documentation - Onboarding.md`.
