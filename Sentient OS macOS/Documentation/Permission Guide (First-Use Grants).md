# Permission Guide — the first-use gate + the floating drag panel

How Sentient acquires the grants that make computer use work, without ever asking at launch or in
onboarding (the lazy-grant policy). Two pieces, both in `Views/Permissions/`:

1. **`ComputerUseGate`** — the first-use interception: the one-time setup window that appears the
   first time the user fires anything that acts on the Mac.
2. **`PermissionGuide` + `PermissionDragPanel` + `SettingsWindowTracker`** — the floating
   System-Settings companion: opens the right privacy pane and carries a draggable `.app` card the
   user drops straight into the permission list (no "+", no file picker).

Everything here was field-tested on a full fresh-install simulation (defaults + TCC + codex all
reset) on 2026-07-09.

## The four grants

| Row | Who holds it | Required? | How it's granted |
|---|---|---|---|
| Microphone & Speech | Sentient | required | native system prompts (`VoiceCapture.requestPermissions`) |
| Screen Recording | Sentient | **optional** (amber; commands run text-only without it) | drag panel, Sentient as the card |
| Accessibility | Codex Computer Use helper | required | drag panel, the helper as the card |
| Screen Recording | Codex Computer Use helper | required | drag panel, the helper as the card |

The helper's two grants live in the SYSTEM TCC.db (SIP-protected — nothing can write it), so the
drag panel is the only honest path. Status for both is read live from the system DB via our FDA
(`Permissions.isTCCGranted`); Sentient's own Screen Recording status ALSO reads the TCC DB, so the
row turns green the moment the switch flips even though capture needs an app restart
(`CGPreflightScreenCaptureAccess` stays false until relaunch — the tip says so).

⚠️ Do NOT use `CGRequestScreenCaptureAccess` as the grant flow: on Tahoe it does not reliably add
the app to the Screen Recording list (field-verified), which strands the user in front of a list
with no row to flip. The drag panel works on every macOS.

## ComputerUseGate (the first-use setup window)

- **Interception:** every computer-use surface funnels through `intercept(_:)` — the home command
  bar, Sidekick voice, notch typing (all via `CommandCoordinator.submit`) and a real proactive
  card's fire (`ForYouModel.run`). While any REQUIRED grant is missing, the fired action is
  STASHED, the window appears, and Continue fires the held action ("Continue anyway" when not all
  green). Closing the window drops the action instead — never fired blind.
- **Cadence:** at most once per app session (`shownThisSession`); all required grants green means
  it never appears at all, including the first time. Sentient's optional Screen Recording never
  gates anything.
- The window is AppKit-owned (floating `NSWindow`, black, hidden title) so it can appear over
  OTHER apps — Sidekick fires from anywhere, and a SwiftUI `Window` scene can't be raised from the
  coordinator.
- Presenting the gate also runs `Permissions.selfHealComputerUseAutomation`, writing the Apple
  Events grant (Sentient → the helper) so it's in place before the first fire ever needs it.
  **Why this is safe:** it's Sentient authorizing *its own* computer-use helper, one row written
  into the *user's own* TCC.db (never the SIP-protected system DB) using the Full Disk Access the
  user already granted by hand — not a broad or hidden capability, just the single entitlement the
  toolchain needs, and the only alternative is a mid-fire Apple Events consent dialog that a
  headless run has no one to answer.
- **The self-heal has FOUR triggers**, all idempotent and fully guarded (no-op without FDA, or if
  the helper's not on disk, or if it's already granted): the gate above, Settings → Health on open,
  the Dev Tools button, and — earliest — **right after a successful computer-use install**
  (`CodexSetup.setupComputerUse`, 2s after `✓ Computer use ready`). That last one is the ideal
  moment: the helper is freshly on disk and onboarding already holds FDA, so the row is written
  proactively *during setup* — the grant is in place well before the first fire, and the gate's
  copy is just a backstop. The 2s delay lets the just-written helper bundle settle before its
  code-signature blob is read.
- Analytics: `PermissionGate.shown` / `PermissionGate.continued` (all_granted flag only).

## PermissionGuide (the floating drag panel)

`PermissionGuide.shared.guide(pane, dragging: appURL)` opens the System Settings pane and raises a
borderless, NON-ACTIVATING panel that flies from the pressed button to just below the Settings
window and follows it live. Two modes:

- **Drag** (`appURL` set): the panel carries the `.app` card; `AppDragSourceView`'s pasteboard
  payload mimics a Finder file drag (fileURL + `NSFilenamesPboardType` + promised-file-url +
  string) — the exact mix System Settings accepts into its privacy lists. While dragging, the
  panel goes mouse-transparent so the drop lands in Settings.
- **Instruction** (`appURL` nil): toggle-only panes with no drag target — Login Items approval
  ("Flip Sentient OS on under App Background Activity" — matches the pane's section header).

Panes: `.fullDiskAccess` (onboarding + Health, Sentient as card) · `.accessibility` /
`.screenRecording` (the helper, or Sentient for its own screen recording) · `.loginItems`
(instruction). One active panel at a time; System Settings quitting auto-dismisses it
(`SettingsWindowTracker`: a 30Hz zero-permission CGWindowList poll + AX observers when available,
12-miss tolerance).

The tracker + panel + drag-source mechanics are adapted from
[jaywcjlove/PermissionFlow](https://github.com/jaywcjlove/PermissionFlow) (MIT — attribution in
the file headers; the reference clone lives at the workspace root). Hard-won details to never
"simplify": `NSHostingView.sizingOptions = []` (the panel self-resizes off-screen without it),
the Finder-shaped pasteboard mix, and the CG→AppKit coordinate flip in the tracker.

## Where it's wired

- `CommandCoordinator.submit` → gate (bar + Sidekick + notch typing, one choke point).
- `HomeView`'s `ForYouModel.run` → gate (real cards only; the demo deck never gates).
- Onboarding permissions: FDA's Grant… flies the drag panel with Sentient as the card; Login
  Items approval gets the instruction panel.
- Settings → Health: FDA, Sentient's Screen Recording, and both codex permission rows all use the
  guide; the plain deep-links survive only as the helper-missing fallback.
