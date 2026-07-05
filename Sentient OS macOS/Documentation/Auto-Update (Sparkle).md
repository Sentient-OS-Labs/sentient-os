# Auto-Update (Sparkle)

How Sentient OS keeps itself current: [Sparkle 2](https://sparkle-project.org) delivers signed,
notarized updates. Sentient **auto-updates silently** in the normal case, and falls back to its **own
OLED forced-update UI** (no skip, no "remind me later") when a silent install can't happen.

> **Status:** ✅ verified end-to-end on real hardware (2026-07-05). Both paths were exercised with a
> real local appcast + a real EdDSA-signed update: (1) **silent auto-update** — an installed build 1
> self-updated to build 2 with zero interaction ("EdDSA signature is correct", installed on quit); and
> (2) the **fallback gate** — with silent install off, the OLED gate appeared, and "Update Now"
> downloaded → installed → relaunched to the new version. See "Testing" for the harness. Still pending:
> a real notarized-DMG release via `release.sh` (needs the paid team + notary creds).

---

## The shape

- **Framework:** Sparkle 2.9.4, added via SwiftPM (remote package, "Embed & Sign"). Runtime min is
  macOS 12 — under our 15.0 floor, no conflict. Because the app is **non-sandboxed**, Sparkle's XPC
  services (`Installer.xpc` / `Downloader.xpc`) ship inside the framework but are **never used** —
  we must NOT set `SUEnableInstallerLauncherService` / `SUEnableDownloaderService`.
- **Security:** every update is verified twice — an **EdDSA (Ed25519)** signature (our key) AND
  Apple's Developer-ID code signature. Sparkle enforces that an update carries the **same Team ID**
  as the installed app, so all releases must be signed with the paid team (`YJ8AZR3G5Q`, Jesai's).
- **Privacy:** no system profile is ever sent (`SUEnableSystemProfiling`/`SUSendProfileInfo` = NO),
  no JavaScript in release notes. The only network call is the appcast GET (IP + User-Agent) over
  HTTPS — no account, consistent with the Privacy Constitution.

## Code — `Updates/`

| File | Job |
|---|---|
| `UpdateController.swift` | Owns the `SPUUpdater` (targets the main bundle), the driver, and the model. `AppState` holds one and calls `start()` on launch — **GUI path only**, never the root wake-helper. Exposes `checkForUpdatesNow()` + version/last-checked for the menu and Settings. Also the (logging-only) `SPUUpdaterDelegate`. |
| `SentientUpdateDriver.swift` | Our custom `SPUUserDriver`. Translates Sparkle's callbacks into `UpdateModel` state and stashes the reply closures. **Mandatory:** `showUpdateFound…` only ever replies `.install`; `showReady(toInstallAndRelaunch:)` auto-installs. ⚠️ The method labels must match Sparkle's imported Swift signatures exactly (Swift matches these witnesses by signature, not `@objc` selector). |
| `UpdateModel.swift` | `@Observable` bridge between the driver and the UI. A `Phase` state machine (idle → checking → found → downloading → extracting → installing / failed) and a `Surface` (`none` / `gate` / `info`). The UI reads `phase`/`surface`; `installNow()`/`dismissInfo()`/`quit()` fire the stashed closures back. |
| `UpdateGateView.swift` | The OLED UI. Two faces: the full-screen **gate** (mandatory — Update / Quit, no skip/remind) and a small dismissible **info card** (user-initiated "Checking…" / "You're up to date" / "Couldn't check"). Reuses `Theme`, `GlowButton`, `SpinningLogo`. Presented as an overlay by `RootView`; draws nothing at rest. |

**Wiring:** `App/AppState.swift` (owns + `start()`s) · `Views/RootView.swift` (`.overlay { UpdateGateView() }`)
· `Views/MenuBarView.swift` ("Check for Updates…") · `Views/Settings/SystemPane.swift` (Updates group).

## The update model — auto-update, gate as fallback

- **Normal case → silent, zero taps.** With `SUAutomaticallyUpdate`/`SUAllowsAutomaticUpdates` on,
  Sparkle silently downloads new versions and installs them on quit/relaunch (a running bundle can't
  be swapped underneath the user). The gate never appears.
- **Fallback → the gate.** Our custom forced-update UI only shows when a silent install *can't*
  happen: macOS needs an **admin password** (app in a non-user-writable dir like `/Applications`), an
  install error, or the **impatient window** (`SUScheduledImpatientCheckInterval`, 2 days) elapses
  without the app being quit — important because Sentient lives in the menu bar and may run for days,
  so "install on quit" alone could otherwise stall. When it shows, it's **mandatory**: Update / Quit,
  no skip, no remind.
- **Fail-open.** If the feed is unreachable (offline, server down), Sparkle never surfaces anything —
  nobody is locked out of their own local AI.
- **Info card** shows only for *user-initiated* checks (menu / Settings): "Checking…" / "You're up to
  date" / "Couldn't check". A silent background check that finds nothing shows nothing.

Same custom `SPUUserDriver` drives both: whenever Sparkle needs UI, it's our gate — never Sparkle's
stock windows, and never a skip/remind button.

⚠️ **Known limitation:** the gate overlays the **main window**. If the user has a secondary window
(Settings/Knowledge) focused, they could keep using it during a found-update gate. Bringing the app
forward (`NSApplication.activate`) mitigates it. A true all-window blocker (a floating panel like the
notch) is a possible future hardening.

## Config — `Info.plist`

The app uses `GENERATE_INFOPLIST_FILE=YES`, so the Sparkle keys live in a **partial** `Info.plist`
(repo root, next to the `.xcodeproj`) referenced by `INFOPLIST_FILE`; Xcode merges the generated keys
on top. Keys: `SUFeedURL` (`https://sentient-os.ai/appcast.xml`), `SUPublicEDKey`, `SUEnableAutomaticChecks`,
`SUScheduledCheckInterval` (86400), `SUAllowsAutomaticUpdates`/`SUAutomaticallyUpdate` = YES (silent
auto-install; the gate is the fallback), `SUScheduledImpatientCheckInterval` (172800 = 2 days, the
menu-bar-app fallback trigger), and the privacy-off trio.

## Versioning

Sparkle compares `CFBundleVersion` (= `CURRENT_PROJECT_VERSION`). **Every release must bump it** (a
monotonically increasing build number); bump `MARKETING_VERSION` for the human-facing version. The
appcast's `sparkle:version` must exceed the installed build for an update to be offered.

## Releasing — `Scripts/release.sh`

One command does: archive → export (Developer ID) → DMG → notarize → staple → EdDSA-sign →
`generate_appcast` → GitHub Release. Run it on **Jesai's Mac** (paid team + notary creds). Then
publish the emitted `appcast.xml` to `https://sentient-os.ai/appcast.xml`. DMGs are uploaded as
GitHub Release assets; the appcast's enclosure URLs point at them via `--download-url-prefix`.

## Before first release (one-time, load-bearing)

1. **EdDSA key:** `Scripts/release.sh keys` → paste the printed `SUPublicEDKey` into `Info.plist`
   (replacing the `AAAA…=` placeholder) and commit. The private seed stays in the Mac's Keychain,
   **never** the repo. ⚠️ The very first public build MUST already carry the real key — an update can
   only be verified by a build that shipped with the matching public key.
2. **Notary profile:** `xcrun notarytool store-credentials "SentientNotary" --apple-id … --team-id YJ8AZR3G5Q --password <app-specific>`.
3. **Sparkle tools:** `brew install --cask sparkle` (or set `SPARKLE_BIN`).
4. **Host `appcast.xml`** at the `SUFeedURL` (own domain via Vercel — a permanent URL; every shipped
   build polls it forever, so it must never move).

## Testing (the harness that proved it — 2026-07-05)

No Developer ID or notarization is needed to test locally: Sparkle validates the **EdDSA signature
first** and only falls back to a Developer-ID code-signing check if EdDSA *fails*
(`SUUpdateValidator.validateDownloadPathWithFallbackOnCodeSigning:`). So a locally-signed build with a
valid EdDSA signature updates for real. The harness:

1. `generate_keys --account <throwaway>` → put the printed `SUPublicEDKey` in `Info.plist`.
2. Build the app (a **throwaway bundle id** like `com.sentient.updatetest` avoids colliding with your
   running dev instance) → this is "build 1". Derive "build 2" by copying it, bumping `CFBundleVersion`
   (+ `CFBundleShortVersionString`) with PlistBuddy, and re-signing (`codesign -f -s <identity>`).
3. `ditto -c -k --keepParent` build 2 → a zip; `sign_update <zip> --account <throwaway>` → EdDSA sig.
4. Write a local `appcast.xml` (enclosure `url` = `http://localhost:PORT/…zip`, with that sig + length);
   serve the folder with `python3 -m http.server PORT`.
5. Install build 1 to a **user-writable** dir (so the silent path needs no admin password), then
   `defaults write <bundleid> SUFeedURL http://localhost:PORT/appcast.xml`. (Localhost HTTP is fine —
   Sparkle warns but allows it, and ATS permits localhost.)
6. **Silent path:** `SUAutomaticallyUpdate = YES` → launch → it downloads + installs on quit → relaunch
   is build 2. **Gate path:** `SUAutomaticallyUpdate = NO` → launch → the gate appears → "Update Now"
   downloads + installs + relaunches. Watch `log stream --predicate 'senderImagePath CONTAINS "Sparkle"'`
   and the `http.server` access log (appcast-only fetch = gate is waiting; appcast **+** zip = it downloaded).

Clean up after: quit the app, kill the server/log-stream, `security delete-generic-password -s
"https://sparkle-project.org" -a <throwaway>`, `defaults delete <bundleid>`, remove the temp dirs +
`~/Library/Caches/<bundleid>`, and restore the `Info.plist` placeholder key.

## Verified so far

- ✅ SPM resolves Sparkle 2.9.4; the app **compiles** clean with the framework, custom driver, gate,
  and all wiring (`BUILD SUCCEEDED`).
- ✅ **Silent auto-update** (2026-07-05, real hardware): installed build 1 → build 2 with zero
  interaction; log showed "OK: EdDSA signature is correct for update"; installed on quit.
- ✅ **Fallback gate** (2026-07-05): with silent install off, the OLED gate appeared, and "Update Now"
  downloaded → installed → relaunched to build 2 (confirmed on screen).
- ⬜ Notarized DMG + `generate_appcast` via `release.sh` — pending a real Developer-ID signing run.

⚠️ **Atomic-swap caveat seen in testing:** in a plain **Debug** build the embedded Sparkle helper
(`Sparkle.framework/…/Autoupdate`) is **ad-hoc** signed, not the app's team — so Sparkle logs "Skipping
atomic rename/swap … because Autoupdate is not signed with same identity" and uses a (still-working)
non-atomic install. A proper **Developer-ID Release** (via `release.sh`, Embed & Sign) re-signs the
nested helpers with the app's identity, restoring the atomic swap + Gatekeeper pre-scan. Confirm this on
the first real Release build (check `codesign -dv Autoupdate` matches the app's Team ID).
