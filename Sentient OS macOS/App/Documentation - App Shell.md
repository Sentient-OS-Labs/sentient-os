# App Shell (App/)

The process entry point, the SwiftUI app scenes, and the small amount of app-wide state. This folder
decides what starts when the app launches and which windows exist. Everything heavy lives elsewhere;
this is the wiring.

## Files

| File | Job |
|---|---|
| `main.swift` | The real entry point. The same binary is also the root "wake helper": when launchd relaunches it with `--wake-helper`, `main.swift` branches into `WakeHelper.run()` before SwiftUI ever exists. Otherwise it starts crash reporting, analytics, the one-time anonymous install ping, and the GUI app. |
| `Sentient_OS_macOSApp.swift` | The `App` struct (no `@main`, because `main.swift` is the entry). Declares every window scene and the menu bar item. |
| `AppState.swift` | `@Observable` app-wide state and the launch sequence. Owns the scheduler, the Sidekick coordinator, the notch window controller, the Dock policy, and the updater. |
| `DockPolicy.swift` | Shows the Dock icon only while the home window is open (`.regular` vs `.accessory`). Auxiliary windows float like a menu-bar app's panels. |

## The windows

`Sentient_OS_macOSApp` declares:

- **Home** (`WindowGroup`, id `home`): `RootView`, dark only, hidden title bar, 1180×880 default. Always presented at launch, with one exception: the relaunch right after a silent auto-update stays windowless (`UpdateNotice.suppressHomeThisLaunch`), so a menu-bar user is not interrupted.
- **Knowledge** (id `knowledge`), **Settings** (id `settings`), **Connect your AIs** (id `connect-ais`): each its own resizable window. All auxiliary windows carry `.restorationBehavior(.disabled)` so macOS state restoration never reopens them at launch; the home is the only launch surface.
- **Proactive · Execute** and **Overnight Processing**: dev-only windows opened from Dev Tools.
- **MenuBarExtra**: `MenuBarView` with the orb mark as a template icon.

`SentientOSApp.isHomeWindow(_:)` recognizes the home window by its identifier prefix; `DockPolicy` and `MenuBarView.openHome()` use it.

## The launch sequence (`AppState.init`)

In order:

1. Read `hasCompletedOnboarding` from UserDefaults (`AppState.onboardingKey`).
2. If `SENTIENT_SELFTEST` is set in the environment, stop here. Headless self-tests boot the app shell but must not trigger any launch side effects (they share the real UserDefaults).
3. `scheduler.reevaluate()` and `scheduler.maybeAutoEnable()` (see `Scheduling/`).
4. `commandCoordinator.start()` arms the Sidekick hotkey and warms the speech model; `notch.start()` raises the notch overlay window. The hotkey is armed for everyone; free-plan gating happens live at press time.
5. `dockPolicy.start()`, `update.start()` (Sparkle plus one background check), `UpdateNotice.checkAtLaunch()` (version-changed notice).
6. If onboarding is complete and notification permission is still undetermined, request *provisional* (quiet) authorization. Nothing is shown to the user.
7. If onboarding is NOT complete: 2 s after launch, kick the on-device model download if Full Disk Access is already granted (the FDA grant forces a relaunch, so this is the launch after it); and 1 s after launch, start the background Codex CLI install unless `~/.codex` already holds a real setup (`auth.json` or `config.toml`). The install retry policy lives in `CodexSetup.ensureInstalled`.

## Rules

- Nothing UI-related may run in the wake-helper branch. The privileged path is `WakeHelper.run()` and nothing else.
- Keep launch side effects behind the `SENTIENT_SELFTEST` guard.
- The home is the only window that may present at launch; new auxiliary windows must set `.restorationBehavior(.disabled)`.

## Related docs

`Scheduling/Documentation - Overnight Scheduler & Wake Helper.md` (the helper branch), `Notch Magic/Documentation - Sidekick - General.md` (the coordinator and notch), `Updates/Documentation - Auto-Update (Sparkle) & Release Pipeline.md`, `Views/Onboarding/Documentation - Onboarding.md`.
