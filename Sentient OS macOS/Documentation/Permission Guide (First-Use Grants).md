# Permission Guide — the first-use gate + the floating drag panel

How Sentient acquires the grants that make computer use work, without ever asking at launch or in
onboarding (the lazy-grant policy). Two pieces, both in `Views/Permissions/`:

1. **`ComputerUseGate`** — the first-use interception: the one-time setup window that appears the
   first time the user fires anything that acts on the Mac.
2. **`PermissionGuide` + `PermissionDragPanel` + `SettingsWindowTracker`** — the floating
   System-Settings companion: opens the right privacy pane and carries a draggable `.app` card the
   user drops straight into the permission list (no "+", no file picker).

The Apple Silicon flow was field-tested on a full fresh-install simulation (defaults + TCC + codex all
reset) on 2026-07-09. The Intel automated and permission-gate status is recorded at the end of this doc.

## The grants and their architecture-specific owner

| Row | Intel (`x86_64`) owner | Apple Silicon (`arm64`) owner | Required? | How it's granted |
|---|---|---|---|---|
| Microphone & Speech | Sentient OS | Sentient OS | required | native system prompts (`VoiceCapture.requestPermissions`) |
| Screen Recording for context | Sentient OS | Sentient OS | optional on Apple Silicon; shared with required Intel capture | the matching System Settings row |
| Computer Use Accessibility | Sentient OS | Codex Computer Use helper | required | Intel uses the public prompt/settings flow; Apple Silicon uses the helper drag card |
| Computer Use Screen Recording | Sentient OS | Codex Computer Use helper | required | the user enables the matching app in System Settings, then relaunches it when required |

`ComputerUseBackend.current` is the source of truth. The Intel service is a child of Sentient, so both
Computer Use grants belong to bundle id `jesai.Sentient-OS-macOS`; the permission UI shows one Screen
Recording row and names Sentient OS. Apple Silicon keeps the separately signed Sky helper owner,
`com.openai.sky.CUAService`, and its existing two helper rows. Intel compiles out the Sky Automation
grant, revoke, and self-heal paths.

The protected grants live in the SYSTEM TCC.db (SIP-protected — nothing can write them directly).
Status reads remain read-only. Intel Screen Recording readiness uses
`CGPreflightScreenCaptureAccess()` for the current process, not only the database row, so the gate stays
blocked and offers a relaunch when the switch is on but the grant is not effective yet. Never edit TCC
to pass this gate.

On Intel, `requestComputerUseScreenRecording()` uses Apple's public request API and opens the matching
privacy pane if capture is still unavailable. On Apple Silicon, keep the field-tested helper drag-card
flow; `CGRequestScreenCaptureAccess` targets Sentient rather than the separately signed Sky helper.

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
- On Apple Silicon, presenting the gate also runs `Permissions.selfHealComputerUseAutomation`, writing the Apple
  Events grant (Sentient → the helper) so it's in place before the first fire ever needs it.
  **Why this is safe:** it's Sentient authorizing *its own* computer-use helper, one row written
  into the *user's own* TCC.db (never the SIP-protected system DB) using the Full Disk Access the
  user already granted by hand — not a broad or hidden capability, just the single entitlement the
  Sky toolchain needs, and the only alternative is a mid-fire Apple Events consent dialog that a
  headless run has no one to answer.
- **The Apple Silicon self-heal has FOUR triggers**, all idempotent and fully guarded (no-op without FDA, or if
  the helper's not on disk, or if it's already granted): the gate above, Settings → Health on open,
  the Dev Tools button, and — earliest — **right after a successful computer-use install**
  (`CodexSetup.setupComputerUse`, 2s after `✓ Computer use ready`). That last one is the ideal
  moment: the helper is freshly on disk and onboarding already holds FDA, so the row is written
  proactively *during setup* — the grant is in place well before the first fire, and the gate's
  copy is just a backstop. The 2s delay lets the just-written helper bundle settle before its
  code-signature blob is read.
- Analytics: `PermissionGate.shown` / `PermissionGate.continued` (all_granted flag only).

On Intel, the gate does not call any Sky Automation lifecycle function. It asks for Sentient's own
Accessibility through `AXIsProcessTrustedWithOptions`, uses the normal Screen Recording request/settings
flow, and requires a Sentient relaunch before a newly enabled Screen Recording grant is accepted.

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
`.screenRecording` (Sentient on Intel; the helper or Sentient's optional context capture on Apple
Silicon) · `.loginItems`
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

## Intel acceptance status — 2026-07-20

On the MacBookPro16,1 test machine running macOS 26.5.2 (25F84), two fresh direct MCP smoke sessions
started the x86_64 adapter/service, listed 65 applications, and reached
`permission_denied_screen_recording` when reading TextEdit. This proves the native processes launch and
the Screen Recording gate is actionable; it does **not** satisfy the physical interaction acceptance.

The user must grant Screen Recording to the exact signed Sentient build in System Settings and relaunch
that build. The final two TextEdit runs are pending until then. No TCC database was edited, no permission
toggle was automated, and the smoke sessions left no PNG or service process behind.
