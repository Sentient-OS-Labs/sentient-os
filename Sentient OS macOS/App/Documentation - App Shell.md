# App Shell (App/)

The process entry point, the SwiftUI app scenes, and the small amount of app-wide state. This folder
decides what starts when the app launches and which windows exist. Everything heavy lives elsewhere;
this is the wiring.

## Files

| File | Job |
|---|---|
| `main.swift` | The real entry point. The same binary is also the root "wake helper": when launchd relaunches it with `--wake-helper`, `main.swift` branches into `WakeHelper.run()` before SwiftUI ever exists. Otherwise it starts crash reporting, analytics, the one-time minimal install-count ping, and the GUI app. |
| `Sentient_OS_macOSApp.swift` | The `App` struct (no `@main`, because `main.swift` is the entry). Declares every window scene and the menu bar item. |
| `AppState.swift` | `@Observable` app-wide state and the launch sequence. Owns the scheduler, the Sidekick coordinator, the notch window controller, the Dock policy, and the updater. |
| `DockPolicy.swift` | Shows the Dock icon while the home window is open or computer-use setup is pending (`.regular` vs `.accessory`). Auxiliary windows float like a menu-bar app's panels. |

## The windows

`Sentient_OS_macOSApp` declares:

- **Home** (`WindowGroup`, id `home`): `RootView`, dark only, hidden title bar, 1180×880 default. Guarded and hidden during pending computer-use setup. Otherwise presented at launch, with one exception: the relaunch right after a silent auto-update stays windowless (`UpdateNotice.suppressHomeThisLaunch`), so a menu-bar user is not interrupted.
- **Knowledge** (id `knowledge`), **Settings** (id `settings`), **Connect your AIs** (id `connect-ais`): each its own resizable window. All auxiliary windows carry `.restorationBehavior(.disabled)` so macOS state restoration never reopens them at launch; the home is the only launch surface.
- **Proactive · Execute** and **Overnight Processing**: dev-only windows opened from Dev Tools.
- **MenuBarExtra**: `MenuBarView` with the orb mark as a template icon.

`SentientOSApp.isHomeWindow(_:)` recognizes the home window by its identifier prefix; `DockPolicy` and `MenuBarView.openHome()` use it.

## The launch sequence (`AppState.init`)

1. Read `hasCompletedOnboarding` and construct the shared services.
2. Return before launch side effects when `SENTIENT_SELFTEST` is set. The DEBUG initializer in the app declaration dispatches the existing connector lab.
3. Prepare `ComputerUseUpgrade` before mounting regular scenes or starting Sidekick. A previously ready, onboarded Mac missing the pinned driver enters persistent setup; an existing pending upgrade resumes even after installation. Fresh onboarding and already-configured users retain their normal startup.
4. Start the scheduler as before. `startInterfaceIfReady()` starts the Sidekick coordinator and notch once, immediately on a normal launch or after setup releases the interface. During setup there are no Sidekick hotkey monitors or notch startup.
5. Start Dock policy, Sparkle, update notices, diagnostics, notification checks, and managed CLI maintenance. The detached startup task also sweeps orphaned managed computer-use daemons, preserving daemons whose Sentient host is still alive. These services retain their own guards; the setup window does not pause background scheduling or connector classification maintenance.
6. During onboarding, the existing FDA-dependent model download remains available. Shared Codex CLI and native computer-use preparation start at app launch for all backends. Claude Code preparation is tied to the Claude commitment/sign-in flow.

## Exclusive computer-use setup

All six regular scenes use `ComputerUseWindowGuard`. While setup is pending, their content is absent
(including the home's mirror catch-up task), and their AppKit windows are registered, transparent,
and ordered out. A deferred hiding pass covers AppKit finishing an order-front operation after its
key-window notification. Native permission dialogs and the floating permission guide are not guarded.

The setup window has normal close, minimize, and resize controls. Closing or minimizing changes only
presentation, never the pending state. Ordinary activation leaves minimized setup alone; explicit Dock
reopen and the menu bar's Open action restore it. Dock policy keeps the app's Dock entry throughout
setup, and the menu's manual update check is disabled. Quit remains available.

The always-mounted `MenuBarIcon` registers a SwiftUI home-opening action even when a silent update
launch creates no regular scene. Scene registration provides the same action as a second source.
Completion restores requested hidden windows, prefers home, and creates it when absent. A late opener
registration fulfills an outstanding home request. The completion callback starts Sidekick/notch once.
Factory Reset clears the pending upgrade and its live window session after rewinding onboarding.

## Rules

- Nothing UI-related runs in the wake-helper branch.
- Keep launch side effects behind the `SENTIENT_SELFTEST` guard.
- New regular windows need `ComputerUseWindowGuard` and auxiliary windows need `.restorationBehavior(.disabled)`.
- Preserve silent-update home suppression; setup completion must still be able to create home without a previous scene.
- `--preview-computer-use-upgrade` is DEBUG-only and never belongs in a shared scheme. It preserves pending state but its installer and permission buttons are real.

## Related docs

`Scheduling/Documentation - Overnight Scheduler & Wake Helper.md` (the helper branch), `Notch Magic/Documentation - Sidekick - General.md` (the coordinator and notch), `Updates/Documentation - Auto-Update (Sparkle) & Release Pipeline.md`, `Views/Onboarding/Documentation - Onboarding.md`.
