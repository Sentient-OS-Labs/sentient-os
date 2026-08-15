# The Permission Gate & the Floating Guide (Views/Permissions/)

How Sentient acquires the grants that make computer use work without ever asking at launch or as an
onboarding step (the lazy-grant policy). Two pieces:

1. **`ComputerUseGate`**: the one-time setup window that appears the first time the user fires anything
   that acts on the Mac (the command bar, Sidekick, a card's fire) while a required grant is missing.
2. **`PermissionGuide` + `PermissionDragPanel` + `SettingsWindowTracker`**: the floating System-Settings
   companion that opens the right privacy pane and carries a draggable `.app` card the user drops
   straight into the permission list (no "+", no file picker).

## Files

| File | Job |
|---|---|
| `ComputerUseGate.swift` | The interception (`intercept`, `interceptBeforeStart`, `presentVoiceFixIfDenied`), the grant probes, the AppKit-owned floating window, Continue. |
| `ComputerUseGateView.swift` | The window's face: the four grants as `StatusLine` rows in two groups. |
| `PermissionGuide.swift` | `guide(pane, dragging:)`: open the pane and raise the panel; drag vs instruction mode; close. |
| `PermissionDragPanel.swift` | The borderless, non-activating panel that flies from the pressed button to just below the Settings window and follows it; the Finder-shaped drag source. |
| `SettingsWindowTracker.swift` | Follows the System Settings window: a 30 Hz zero-permission `CGWindowList` poll plus AX observers when available; 12 misses = Settings closed → the panel dismisses. |

The tracker, panel, and drag-source mechanics are adapted from jaywcjlove/PermissionFlow (MIT;
attribution in the file headers). Details there that must not be "simplified": `NSHostingView.
sizingOptions = []` (otherwise the hosting view re-advertises its own size every layout pass and the
panel strands off-screen), the Finder-shaped pasteboard mix, and the CG → AppKit coordinate flip.

## The four grants

| Row | Held by | Required? | Granted how |
|---|---|---|---|
| Microphone & Speech | Sentient | optional (Sidekick's voice; tap-to-type and typed commands work without it) | native system prompts (`VoiceCapture.requestPermissions`), amber while not asked |
| Screen Recording | Sentient | optional (the screen still; commands run text-only without it) | the drag panel with Sentient as the card (`CGRequestScreenCaptureAccess` does not reliably add the app to the list on Tahoe) |
| Accessibility | the Codex Computer Use helper | **required** | the drag panel with the helper as the card |
| Screen Recording | the Codex Computer Use helper | **required** | the drag panel with the helper as the card |

The helper's two live in the system TCC database (SIP-protected; only the user can flip them), read
live via our Full Disk Access (`Permissions.isTCCGranted`). Sentient's own Screen Recording status also
reads the TCC database, so the row turns green the moment the switch flips even though capture needs a
relaunch (the tip says so).

## The gate (`ComputerUseGate`)

`intercept(action)` returns true when it took over (window up, action stashed) and the caller must
abort. Two cases:

- **A required grant is missing → BLOCKING.** The window shows (or re-focuses) and re-holds the action every time, until every required grant is green; Continue is disabled, and closing the window DROPS the action (never fired blind).
- **All required green, but one of Sentient's optional grants is missing and has never been offered → NON-BLOCKING, once ever** (persisted flags `computerUse.screenRecordingOffered` / `micSpeechOffered`, cleared by FactoryReset). Continue is enabled immediately and closing still FIRES the held command, so an optional nudge never eats what the user asked for.

All required green and both optionals offered = it never appears at all. `interceptBeforeStart()` gates
a surface that must not even OPEN while a grant is missing (the Sidekick hotkey press, so the notch
never drops open to listen and only meets the gate at submit). `presentVoiceFixIfDenied()` raises the
window as a non-blocking fix surface when a voice HOLD hits a DENIED mic/speech grant (a denied grant has
no native prompt left to show). Presenting also runs `Permissions.selfHealComputerUseAutomation` (the
Apple Events grant Sentient → the helper), and passing the required checks latches
`HealthCaution.computerUseEverReady`, so only a later REGRESSION can banner.

The window is AppKit-owned (a floating `NSWindow`, black, hidden title) so it can appear over OTHER
apps; Sidekick fires from anywhere and a SwiftUI `Window` scene cannot be raised from the coordinator.
Analytics: `PermissionGate.shown` / `.continued`.

## The guide (`PermissionGuide`)

`guide(pane, dragging: appURL)` opens the System Settings pane and raises the panel, which flies from
the mouse location to just below the Settings window's content area and follows it. **Drag mode**
(`appURL` set): the panel carries the `.app` card whose drag payload is shaped like a Finder file drag
(the exact pasteboard mix System Settings accepts); while dragging, the panel goes mouse-transparent so
the drop lands in Settings. **Instruction mode** (`appURL` nil): toggle-only panes with no drag target
("Flip Sentient OS on under App Background Activity"). Panes: Full Disk Access (onboarding + Health,
Sentient as the card), Accessibility and Screen Recording (the helper, or Sentient for its own), Login
Items (instruction). One panel at a time; System Settings quitting dismisses it; a gear on the panel
brings a buried Settings back to front.

## Where it is wired

`CommandCoordinator.submit` (the bar, Sidekick, notch typing), the hotkey press and notch click
(`interceptBeforeStart`), `ForYouModel.run` (real cards), onboarding's permissions step (FDA drag,
Login Items instruction), and Settings → Health (FDA, Sentient's Screen Recording, both helper rows).

## Related docs

`System/Documentation - System (Permissions, Health, Uninstall).md` (the probes and the Automation grant), `Notch Magic/Documentation - Sidekick - General.md`, `Views/Settings/Documentation - Settings.md`, `Views/Onboarding/Documentation - Onboarding.md`.
