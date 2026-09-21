# Auto-Update (Sparkle) & the Release Pipeline (Updates/)

How Sentient keeps itself current, and how a release ships. Sparkle 2 delivers signed, notarized
updates; Sentient auto-updates silently and relaunches itself Chrome-style, and falls back to its own
OLED forced-update UI only when a silent install genuinely cannot happen. Releases go out through two
scripts at the repo root (`Scripts/make_dmg.sh` → `Scripts/release.sh`) plus one manual website step.

## Files

| File | Job |
|---|---|
| `UpdateController.swift` | Owns the `SPUUpdater`, the driver, and the model. `AppState` holds one and calls `start()` (GUI only, never the wake helper). The silent-relaunch hook and the idle gate. |
| `SentientUpdateDriver.swift` | Our `SPUUserDriver`: translates Sparkle's callbacks into `UpdateModel` state. Mandatory by design: a found update only ever replies `.install`. |
| `UpdateModel.swift` | The `@Observable` phase machine (idle → checking → found → downloading → extracting → installing / failed), the surface (`none` / `gate` / `info`), and which window a user-initiated check came from. |
| `UpdateNotice.swift` | The silent-relaunch flag (the new build launches windowless once) and the "Sentient just updated" notice (a macOS notification + the home's green capsule). |
| `UpdateGateView.swift` | The OLED UI: the full-screen mandatory gate (Update / Quit, no skip) and the small info card for user-initiated checks. Overlaid by the home and the Settings window. |
| `Info.plist` (repo root) | The Sparkle keys: feed URL, the public EdDSA key, the 3 h check interval, automatic download + install, no profiling, no JavaScript. Xcode merges the generated keys on top of this partial plist. |
| `Scripts/make_dmg.sh` · `Scripts/release.sh` (repo root) | The release pipeline. |

## The update model

- **Release builds only.** `UpdateController.appUpdatesEnabled` is false under `DEBUG`; no `SPUUpdater` is created, automatic/manual checks are inert, and Settings/menu update buttons are disabled. Debug `UpdateNotice` calls neither consume nor change the shared release-version, relaunch, or notice preferences. Do not disable Sparkle by writing its automatic-update preferences: Debug and Release share the bundle ID and defaults. CUA driver updates remain enabled independently.
- **Normal case: fully silent, zero clicks.** Sparkle checks every 3 h (plus once at launch), silently downloads and stages a new version, then calls `willInstallUpdateOnQuit`. `UpdateController` takes over and, the moment it is **idle-safe** (`isSafeToRelaunch`: no pipeline run in flight (`PipelineActivity`), and either the app is not frontmost or the user has been idle 5+ minutes; a 30 s timer retries), installs and relaunches with no UI. Returning `true` from that hook means we MUST eventually fire the handler; the timer guarantees it, and if the user quits first Sparkle installs on quit anyway.
- **The relaunch is windowless.** `UpdateNotice.recordSilentRelaunch()` (only after onboarding) stores the old version string right before the relaunch; the new build consumes it once and launches the home `.suppressed` (Dock icon dropped to match). If the running build still matches the stored version the install never landed, and the flag is ignored, so a stale flag can never hide the window.
- **"Sentient just updated."** Every launch diffs a persisted last-run version; a change fires the macOS notification (explaining the Dock bounce) and arms the persistent green capsule with a Read the changelog pill (the latest GitHub release), rendered in the home's banner slot and over onboarding until dismissed.
- **The gate** shows only when a silent install cannot happen (macOS needs an admin password because the app sits in a non-user-writable directory, or an install error) and for user-initiated checks. Mandatory: Update / Quit, no skip or remind. Fail-open: an unreachable feed shows nothing.
- **The info card** ("Checking…", "You're up to date", "Couldn't check") appears only for user-initiated checks and only in the window the check came from (`CheckOrigin`: Settings' Check Now over Settings; the menu bar's opens the home first).

Security: every update is verified twice, an EdDSA signature (our key) and Apple's Developer ID
signature; Sparkle also enforces the same Team ID as the installed app (`YJ8AZR3G5Q`). The public key
in `Info.plist` is the permanent root of trust; the private seed lives in Jesai's login Keychain
(service `https://sparkle-project.org`, account `ed25519`) with an off-machine backup, and NEVER in the
repo. Losing it strands every user; rotating it means first shipping a build with a new public key.
Because the app is non-sandboxed, Sparkle's XPC services are never used (do not set
`SUEnableInstallerLauncherService` / `SUEnableDownloaderService`).

Versioning: Sparkle compares `CFBundleVersion` (`CURRENT_PROJECT_VERSION`), so every release must
bump it; bump `MARKETING_VERSION` for the human version.

## Releasing

You produce the notarized `.app` in Xcode (bump both versions → Archive → Distribute App → Direct
Distribution → wait for "Ready to distribute" → Export Notarized App); the scripts do the rest, run on
Jesai's Mac (the EdDSA seed and the authed `gh` live there):

```
./Scripts/make_dmg.sh "path/to/Sentient OS.app"
./Scripts/release.sh  build/dmg/SentientOS-<version>.dmg
```

**`make_dmg.sh`:** scrubs Finder/iCloud xattr detritus off the bundle (an iCloud-synced Desktop tags
files inside the app and `codesign --strict` rejects it), sanity-checks (signed → notarized → stapled →
a real EdDSA key → Sparkle's Autoupdate helper carries our team), builds the branded DMG with `appdmg`
(background art vendored at `Scripts/dmg/`; window size and icon slots are drawn into the art, so change
them in the website repo's design doc and here together), signs the DMG, notarizes and staples it
(`notarytool`, Keychain profile `sentient-notary`; `SKIP_NOTARIZE=1` escape hatch), and Gatekeeper-
assesses the result. Two one-time Mac setups: a LOCAL Developer ID Application certificate (Xcode's
cloud signing never lands one in the Keychain, so CLI `codesign` cannot see it), and the notarytool
credential from an app-specific password.

**`release.sh`:** validates the DMG is genuinely signed + notarized + stapled, **ensures the build's
dSYMs are on Sentry** (finds them in `~/Library/Developer/Xcode/Archives` by the binary's UUIDs and
uploads; no match or a failed upload ABORTS the release, `SKIP_SENTRY=1` opts out knowingly),
EdDSA-signs the DMG, runs `generate_appcast`, cuts the GitHub Release (uploads the DMG the appcast
points at), bumps the Homebrew cask in our tap (`brew install --cask sentient-os-labs/tap/sentient-os`),
and prints the final manual step: publish `appcast.xml` to `sentient-os.ai/appcast.xml` (the website
repo's `public/appcast.xml`, deployed by Vercel) and bump the site's version-pinned Download URL.
`./release.sh keys` is the one-time key generator.

Testing a real update uses **Release** configuration: publish a "new" build to the live feed, install an "old" one, let it sit idle, and
watch it silently relaunch into "new" (the build number flip and the PID change are the proof; Release
builds are quiet in the unified log). A local throwaway-key harness with a `python3 -m http.server`
appcast works for fast iteration.

## Gotchas

- Apple code signing and Sparkle EdDSA signing are independent; both are needed.
- Never let a development build join the live update channel. A September 2026 Debug launch installed CUA 0.28.2 successfully, then Sparkle replaced the app in DerivedData with the published release carrying older CUA logic. That release raised the migration pitch and left `computerUse.upgradePending` behind. The compile-time gate prevents this even when the published build number exceeds the development one. Verify normal startup as well as headless self-tests, which intentionally bypass updater startup.
- Atomic swap needs same-team nested helpers; a Developer ID export re-signs the Sparkle helpers. `make_dmg.sh` checks.
- The silent path needs a user-writable install dir; a root-owned one falls back to the gate (intended).
- Never ship `.pkg` updates (they always require authorization). Ship a signed, notarized `.app` in a `.dmg`.
- All `SPUUpdater` calls on the main thread. The driver's method labels must match Sparkle's imported Swift signatures exactly.
- The gate overlays the home and Settings windows; a user focused on another window could keep using it during a found-update gate (a known, accepted limitation).

## Related docs

`Diagnostics/Documentation - Diagnostics (Sentry & TelemetryDeck).md` (dSYMs), `App/Documentation - App Shell.md` (the windowless launch), `Documentation - General - Bundle Size & Build Phases.md`.
