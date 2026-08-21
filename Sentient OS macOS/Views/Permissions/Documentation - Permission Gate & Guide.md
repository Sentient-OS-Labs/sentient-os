# The Permission Gate & the Floating Guide (Views/Permissions/)

How Sentient acquires the grants that make computer use work without ever asking at launch or as an
onboarding step (the lazy-grant policy). Three pieces:

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
| `ComputerUseUpgrade.swift` | The update-migration window: the driver download with live narration, then the same grant rows. |
| `PermissionGuide.swift` | `guide(pane, dragging:)`: open the pane and raise the panel; drag vs instruction mode; close. |
| `PermissionDragPanel.swift` | The borderless, non-activating panel that flies from the pressed button to just below the Settings window and follows it; the Finder-shaped drag source. |
| `SettingsWindowTracker.swift` | Follows the System Settings window: a 30 Hz zero-permission `CGWindowList` poll plus AX observers when available; 12 misses = Settings closed → the panel dismisses. |

The tracker, panel, and drag-source mechanics are adapted from jaywcjlove/PermissionFlow (MIT;
attribution in the file headers). Details there that must not be "simplified": `NSHostingView.
sizingOptions = []` (otherwise the hosting view re-advertises its own size every layout pass and the
panel strands off-screen), the Finder-shaped pasteboard mix, and the CG → AppKit coordinate flip.

## The grants

The cua driver runs inside Sentient's own TCC responsibility chain (see the Driver doc), so every
grant belongs to **Sentient itself** — no helper app ever appears in System Settings:

| Row | Required? | Granted how |
|---|---|---|
| Accessibility (the driver's hands) | **required** | the native system prompt (`AXIsProcessTrustedWithOptions`) |
| Screen Recording (the driver's eyes) | **required** | the drag panel with Sentient as the card (`CGRequestScreenCaptureAccess` does not reliably add the app to the list on Tahoe) |
| Microphone & Speech (Sidekick's voice) | optional — tap-to-type and typed commands work without it | native system prompts (`VoiceCapture.requestPermissions`), amber while not asked |

Sentient's Screen Recording status reads the TCC database under Full Disk Access
(`Permissions.isTCCGranted`), so the row turns green the moment the switch flips even though capture
needs a fresh daemon (the grant change replaces it — see below).

## The gate (`ComputerUseGate`)

`intercept(action)` returns true when it took over (window up, action stashed) and the caller must
abort. Two cases:

- **A required grant is missing → BLOCKING.** The window shows (or re-focuses) and re-holds the action
  every time, until both required grants are green; Continue is disabled, and closing the window DROPS
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
`HealthCaution.computerUseEverReady`, so only a later REGRESSION can banner; a grant landing also
marks the daemon for replacement (macOS caches TCC answers per process, so the running daemon would
keep believing the old answer).

The window is AppKit-owned (a floating `NSWindow`, black, hidden title) so it can appear over OTHER
apps; Sidekick fires from anywhere and a SwiftUI `Window` scene cannot be raised from the coordinator.
Analytics: `PermissionGate.shown` / `.continued`.

## The upgrade window (`ComputerUseUpgrade`)

Macs updating from the 1.x codex-helper era had computer use working (the `everReady` latch) but carry
none of what the cua driver needs: the pinned binary isn't on disk, and Sentient's own Accessibility
was never asked for. Rather than a silent background download, the update gets its own moment: the
first home open after updating raises this window — "Computer use just got better", one glowing CTA,
the live install narration (the same streamed lines `CodexSetup.setupCuaDriver` produces), then the two
required grant rows. Not closable before the driver is installed (the download IS the migration);
after it, Done enables when both grants are green and a quiet "Finish later" hands enforcement back to
the first-fire gate. The trigger (everReady latch + binary missing) is self-extinguishing — once the
driver is on disk the window can never appear again, so no flag is persisted. Fresh installs never see
it.

## The guide (`PermissionGuide`)

`guide(pane, dragging: appURL)` opens the System Settings pane and raises the panel, which flies from
the mouse location to just below the Settings window's content area and follows it. **Drag mode**
(`appURL` set): the panel carries the `.app` card whose drag payload is shaped like a Finder file drag
(the exact pasteboard mix System Settings accepts); while dragging, the panel goes mouse-transparent so
the drop lands in Settings. **Instruction mode** (`appURL` nil): toggle-only panes with no drag target
("Flip Sentient OS on under App Background Activity"). Panes: Full Disk Access (onboarding + Health),
Screen Recording (the gate + Health), Login Items (instruction) — Sentient is always the card. One
panel at a time; System Settings quitting dismisses it; a gear on the panel brings a buried Settings
back to front.

## Where it is wired

`CommandCoordinator.submit` (the bar, Sidekick, notch typing), the hotkey press and notch click
(`interceptBeforeStart`), `ForYouModel.run` (real cards), `RootView`'s first home open
(`ComputerUseUpgrade.maybePresent`), onboarding's permissions step (FDA drag, Login Items
instruction), and Settings → Health (FDA, Accessibility, Screen Recording).

## Related docs

`Driver/Documentation - Driver (cua-driver).md` (why the grants are Sentient's own),
`System/Documentation - System (Permissions, Health, Uninstall).md` (the probes),
`Notch Magic/Documentation - Sidekick - General.md`, `Views/Settings/Documentation - Settings.md`,
`Views/Onboarding/Documentation - Onboarding.md`.
