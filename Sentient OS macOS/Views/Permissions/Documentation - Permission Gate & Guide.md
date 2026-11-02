# The Permission Gate & the Floating Guide (Views/Permissions/)

How visible setup surfaces acquire the grants needed for computer use. Background health checks
only check permission state and never request consent. Three pieces:

1. **`ComputerUseGate`**: the one-time setup window that appears the first time the user fires anything
   that acts on the Mac (the command bar, Sidekick, a card's fire) while a required Sentient grant is missing.
2. **`PermissionGuide` + `PermissionDragPanel` + `SettingsWindowTracker`**: the floating System-Settings
   companion that opens the right privacy pane and carries a draggable `.app` card the user drops
   straight into the permission list (no "+", no file picker).
3. **`ComputerUseUpgrade`**: the one-time migration window for Macs updating from the 1.x era of
   computer use.

## Files

| File | Job |
|---|---|
| `ComputerUseGate.swift` | The interception (`intercept`, `interceptBeforeStart`, `presentVoiceFixIfDenied`), the grant probes, the AppKit-owned floating window, Continue. |
| `ComputerUseGateView.swift` | The window's face: Sentient grants as `StatusLine` rows (`SentientPermissionRows` is shared with the upgrade window). |
| `NativePermissionSetup.swift` | Records native setup and recovery history for diagnostics. Never gates chat admission. Legacy drag/click receipts are ignored. |
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
Its compact layout keeps the muted Sentient permissions heading, removes Not granted
labels, and uses **Grant** buttons for
remaining steps. Release hides verified rows; Debug deliberately shows all rows. Settings keeps its full permission layout. Double Tap uses the same compact layout and Grant
buttons for Sentient’s own Accessibility and Screen Recording. Its Done button still requires
both real grants; once ready, a short hint tells the user to focus their reply field and tap again.

When a user clicks **Grant**, the shared permission rows move their setup window to the left
of its current screen before opening System Settings, making room for the authentication dialog.

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

Sentient Screen Recording is checked before a prompt starts because Sentient captures screen
context. After starting the owned helper, the runtime also checks Sentient’s Automation access
through the macOS API. Confirmed denied or not-yet-requested access opens an Automation row in
our setup window. Unavailable observations permit the real connection attempt. CUA still needs
Sentient Accessibility too.

The native helper owns its Accessibility and Screen Recording rows, grant actions, and any
macOS restart instructions. Tool-catalog startup waits for confirmed missing host Automation
access to be resolved, without issuing a synthetic app read or testing the helper’s grants. When the agent actually calls a
computer tool, that authenticated native request can show the helper's setup window and request
system consent. A greeting that uses no native tools therefore never invokes native setup.

Settings retains explicit **Fix permissions…**, including its Automation request and harmless
native setup read. A timeout or lost connection keeps its real error and does not become a denial.
`NativePermissionSetup` stores native completion/recovery history in version-2 keys for diagnostics;
that history never blocks a new chat. A previous Automation denial is refreshed before showing
setup, so a grant made directly in System Settings can release the next request. Old clicked/dropped steps and
restart receipts never create readiness. After a restart, the next real native operation lets the
helper handle any missing grant, including an unfinished setup.

The companion browser-extension note follows only the helper's main setup window. It is vertically
aligned to the browser row using optional Accessibility geometry, with a permissionless placement
for the pinned helper layout. This cosmetic lookup runs off the main thread and cannot gate setup.
The note hides while System Settings or the native drag guide is active.
Ordinary native tool calls also attach the note because the helper can open consent during a task.
Starting and closing the decorative note never delays the native request or its cancellation.

## The gate (`ComputerUseGate`)

`intercept(action)` returns true only while holding an action for Sentient's own required grants.
Continue re-reads those grants and releases the held action once. Native setup, installation,
and transport startup are owned by the task runner, not the permission gate. Closing or cancelling
drops the held action. Voice remains optional for typed requests.
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

### Native setup and recovery

The same native setup request is used for first use, explicit Settings repair, and real permission
failures. It reads Sentient, which is already running, and does not require System Settings to be
open. The normal session sends the required Codex request metadata. The helper can reopen its own
setup window after a restart and reflect the grants already stored by macOS.

Only one gate-owned setup attempt runs at a time. Cancellation prevents late completion from
starting a held task. Read-only setup can reconnect after a helper relaunch within its bounded
setup deadline. Native `-10009`/`-10014` or an explicit ScreenCaptureKit denial can request recovery
once per task. An uncertain original action is never replayed by setup recovery.

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

The flow is pitch → shared installation → host grants → normal task.
Failure is retryable. Completing it requires fresh host grants and an explicit Done action.
Native helper consent is deferred until a real tool call. Native migration is mandatory:
the regular interface stays unavailable until installation and host permissions are ready.
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

Settings delegates helper permissions to **Fix permissions…**, rather than displaying inferred
per-grant rows. The action always makes a fresh native setup request, even if earlier proof was
cached. A nonactivating companion follows the owned helper’s visible setup window and explains
that Accessibility and Screenshots are needed while the browser extension can be skipped. The
companion closes when the request finishes/cancels or the helper window disappears. When the helper
already has access, it can complete without opening a setup window; Settings reports readiness.
Explicit diagnostics are never disabled merely because setup history is missing or unverified.
A successful diagnostic also records completed setup, and a confirmed native denial invalidates it.
