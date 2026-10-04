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
| `ComputerUseUpgrade.swift` | Persistent upgrade coordination, native setup window, installation, readiness, release, and reset. |
| `ComputerUseWindowGuard.swift` | Excludes regular scene content during setup and registers its AppKit window for hiding. |
| `PermissionGuide.swift` | `guide(pane, dragging:)`: open the pane and raise the panel; drag vs instruction mode; close. |
| `PermissionDragPanel.swift` | The borderless, non-activating panel that flies from the pressed button to just below the Settings window and follows it; the Finder-shaped drag source. |
| `SettingsWindowTracker.swift` | Follows the System Settings window: a 30 Hz zero-permission `CGWindowList` poll plus AX observers when available; 12 misses = Settings closed → the panel dismisses. |

The tracker, panel, and drag-source mechanics are adapted from jaywcjlove/PermissionFlow (MIT;
attribution in the file headers). Details there that must not be "simplified": `NSHostingView.
sizingOptions = []` (otherwise the hosting view re-advertises its own size every layout pass and the
panel strands off-screen), the Finder-shaped pasteboard mix, and the CG → AppKit coordinate flip.

## The grants

The required grants follow the selected runtime:

| Runtime | Required grants |
|---|---|
| All active backends / OpenAI | Sentient-to-helper Automation; OpenAI helper Accessibility and Screen Recording; Sentient Screen Recording for screen context. |
| All | Microphone and Speech are optional; typed commands work without them. |

OpenAI Automation is checked through Apple's asynchronous API after launching the signed helper.
Visible permission setup requests unasked consent through the macOS Apple Events dialog; the user chooses Allow there. Granted and denied states are not re-prompted automatically. Automation remains an internal readiness check rather than a separate permission row. Denied or unavailable consent exposes a contextual Settings/retry action. The helper's own Accessibility/Screen Recording rows use the floating drag guide
with the helper bundle, while Sentient's rows carry Sentient itself. Full Disk Access permits read-only
helper grant checks; there are no direct permission-database writes.

Native first-use setup checks both the compatible Codex CLI and helper installation, and exposes
the shared installer when either needs preparation. Claude users are not asked for a ChatGPT login. Existing grants are reused. `SentientPermissionRows` and
`NativeComputerUsePermissionRows` keep first-use, migration and Settings consistent.

## The gate (`ComputerUseGate`)

`intercept(action)` returns true when it took over (window up, action stashed) and the caller must
abort. Two cases:

- **A required grant is missing → BLOCKING.** The window shows (or re-focuses) and re-holds the action
  every time, until the selected runtime and all its required grants are ready; Continue is disabled, and closing the window DROPS
  the action (never fired blind).
- **Required green, but Microphone & Speech has never been offered → NON-BLOCKING, once ever**
  (persisted flag `computerUse.micSpeechOffered`, cleared by FactoryReset). Continue is enabled
  immediately and closing still FIRES the held command, so the nudge never eats what the user asked
  for.

All required green and the optional offered = it never appears at all. `interceptBeforeStart()` gates
a surface that must not even OPEN while a grant is missing (the Sidekick hotkey press, so the notch
never drops open to listen and only meets the gate at submit). `presentVoiceFixIfDenied()` raises the
window as a non-blocking fix surface when a voice HOLD hits a DENIED mic/speech grant (a denied grant
has no native prompt left to show). Passing the required checks latches
the native runtime's `HealthCaution` readiness latch, so only a later regression can banner.

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

The flow is pitch → shared installation → required grants. Failure is retryable. Completing it
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

`CommandCoordinator.submit` (the bar, Sidekick, notch typing), the hotkey press and notch click
(`interceptBeforeStart`), `ForYouModel.run` (real cards), `AppState` and all regular app scenes
(`ComputerUseUpgrade` plus `ComputerUseWindowGuard`), onboarding's permissions step (FDA drag, Login Items
instruction), and Settings → Health (FDA, Accessibility, Screen Recording).

## Related docs

`Driver/Documentation - Native Computer Use.md` (the helper grants and Sentient’s screen-context permission),
`System/Documentation - System (Permissions, Health, Uninstall).md` (the probes),
`Notch Magic/Documentation - Sidekick - General.md`, `Views/Settings/Documentation - Settings.md`,
`Views/Onboarding/Documentation - Onboarding.md`.
