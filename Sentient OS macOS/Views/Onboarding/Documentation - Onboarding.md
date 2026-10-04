# Onboarding (Views/Onboarding/)

First launch, no separate Sentient account: the film and native Double Tap lesson → choose your frontier model (with the codex login embedded) →
the plan crossroads (free/go ChatGPT accounts only) → permissions → the ready-to-process screen → the
REAL first analysis (pausable) → the finale (the home appears and the Knowledge window's Constellation
opens on top). The current step persists (`onboarding.step`), so the quit-and-relaunch that granting
Full Disk Access requires resumes exactly where the user left off.

## Files

| File | Job |
|---|---|
| `OnboardingView.swift` | The step switchboard, the whole-onboarding screen-awake hold, the Back button, the GitHub mark, the right-click blocker, and the DEBUG "SKIP TO HOME" handle. Also `OnboardingNextButton`, `OnboardingBackButton`, `OnboardingTrustFooter`. |
| `OnboardingFilmView.swift` · `OnboardingDoubleTapView.swift` | Step 0: the website film, native Sidekick interaction, then the native Double Tap lesson. |
| `OnboardingFrontierModelView.swift` · `OnboardingCodexSteps.swift` | Step 1: the engine picker with the codex login as the ChatGPT panel; engine preparation and login, the `codex --help` confirmation poll (skipped until a codex install exists), the manual-install panel; the shared onboarding bits (`OnboardingWhisper`, `OnboardingDoneLine`, `MonoWaitLine`, `OnboardingStatusText`). |
| `OnboardingPlanView.swift` | Step 2: the plan crossroads. |
| `OnboardingPermissionsView.swift` | Step 3: overnight wake → launch at login → Full Disk Access, unlocking sequentially. |
| `OnboardingReadyView.swift` | Step 4: the source tiles and the big Start Analysis glow. |
| `OnboardingModelDownloadView.swift` | Shown between Start Analysis and the takeover if the model has not finished landing. |
| `OnboardingTelemetryConsent.swift` | Privacy policy and diagnostic controls over the frontier-model step; Read More opens the policy and Configure Telemetry uses the same two keys as Settings. |

## The steps

**0 · The film (`OnboardingFilmView`).** `https://sentient-os.ai/onboarding?end=0.42&notch=real|key` in
a webview that is a movie, not a page (hit-testing off, off-host navigation blocked, fades in only after
the page reports ready). The page's autopilot scrolls the film and posts "parked" at each rest, which
blooms the native Continue: leg 1 (the night film → the morning home), leg 2 (the Sidekick scene: it
rides to the invitation whisper, "Click the notch" on a lone notched display or "Press the right ⌘ key"
otherwise, then WAITS for the user's real answer: the coordinator's armed one-shot demo takes a bezel
click or a hotkey press and performs the shopping story on the user's own notch while the film rides on),
The final Sidekick park is `0.999`, followed by the native Double Tap lesson. The current native
sequence does not visit the website's Under-the-hood exhibit, FAQ or footer. The film is passive;
native controls handle progression.
Watchdogs bound every wait (12 s to load, 40 s to park); offline or a failed load falls back to a quiet
branded slide, so onboarding is never blocked on the network. The parked beats are addresses into the
film's scroll timeline and must be re-derived if the website re-paces the film. `dev.film.url` (DEBUG)
points the step at a local dev server.

The website's onboarding wrapper uses `OnboardingPlayback`, `MotionConfig reducedMotion="never"`
and `useFilmReducedMotion` so Reduce Motion does not collapse this timed movie or bypass its parks.
The override belongs to `/onboarding`; it does not change the Mac's setting or all website routes.
`Autopilot` clamps nonpositive film geometry so a bounded film destination cannot become a jump to
the page footer. This behavior is implemented in the website and takes effect for installed apps
when that website build is deployed; changing app documentation does not publish it.

**1 · Choose your frontier model.** The shared `FrontierEnginePicker` in a single centered row over
the per-engine panels, with `OnboardingCodexLoginPanel` as the ChatGPT panel and the picker's own
self-contained Claude panel. **Shared computer-use setup starts at app launch:** Codex CLI and the
native helper prepare while the film plays, regardless of the eventual engine choice. "Log in with
ChatGPT" joins CLI preparation before sign-in; "Sign in with Claude" prepares Claude Code; a custom
tab's Test & Select ensures Codex is ready before probing. Both login panels notice the
finished browser sign-in on their own (a 2 s status poll plus a foreground re-check). If an
automatic install gave up (no network, a reset connection, a region block), the panels show the
manual-install fallback (`CodexInstallFailedPanel` links the official guide and suggests a VPN; the
Claude panel shows the one-line Terminal command); the polls pick a CLI up the moment it lands.
Continue gates on the ACTIVE engine being healthy: ChatGPT logged in, Claude signed in, or a custom
endpoint that passed Test & Select.

**2 · The plan crossroads.** Only free/go ChatGPT accounts see it; full plans, the Claude engine,
and custom engines auto-advance before a pixel renders (Back knows to skip over it for them). "We noticed you're not on
ChatGPT Plus." with the three feature rows, then Upgrade on ChatGPT (opens the pricing page and waits,
quietly re-checking via `CodexAuth.refreshPlan` on foreground), "I've upgraded to ChatGPT Plus" (a
native confirm, then we take their word: `assertedPlus`), or "Continue with just the knowledge base"
(`knowledgeBaseOnly`). See the Plan Gate doc.

**3 · Permissions.** Three `StatusLine` rows, unlocking sequentially: Overnight wake (the password
installer; a daemon toggled off in Login Items gets a deep link instead), Launch at login (needs-approval
escorts the user with the guide's instruction panel), and Full Disk Access LAST because it forces a
relaunch (the floating drag panel with Sentient itself as the card, then "Relaunch Sentient"; the
persisted step brings the user right back). Notification permission is asked silently on appear
(`Notify.ask()`). Continue needs all three green; statuses re-probe on foreground.

**4 · Ready to process.** The Settings-grade source tiles on the SAME keys as Settings (Desktop,
Downloads, Documents armed by default; WhatsApp / iMessage pickers; Notes; Apple Mail and Calendar selections; Gmail / Calendar connect
sheets, locked where connectors are unavailable), the shared four-selection minimum, and the
full-brightness Start Analysis glow. Start presents the real `ProcessingView` (`.auto`, `pausable`,
`fullCycle` when the deck is real). If the on-device model has not finished downloading, the
downloading screen (`OnboardingModelDownloadView`: the signature glow bar, GB of GB, Try Again on
failure) covers the tail and hands off to the analysis by itself the moment the model verifies. Only a
finished run calls `onFinished`. Gmail and Outlook Mail collect and save the detected address when
the user presses Done in the connection sheet, with an inline email-only feedback-list notice and no extra popup.
Missing connections or undetectable addresses are skipped without asking for manual entry.

## Privacy explanations at setup

The model step explains the split: your on-device model understands local sources; your selected AI
organizes the resulting knowledge and powers assistance. Apple Mail and Apple Calendar work without
a ChatGPT or Claude subscription. Hosted connectors, Double Tap and optional sharing have distinct
settings rather than one blanket “everything stays local” promise.

The native Double Tap lesson explains its unsent draft and low-latency covered route. One-time
writing-style setup is separate from regular source selections. The frontier step links to the full
policy and diagnostic controls through `OnboardingTelemetryConsent` and shared `PrivacyCopy`.

## Things that happen around the steps

- AppState starts shared Codex CLI and native helper preparation on every normal launch, before model selection. Compatible installations are reused; setup is shared with Settings and task startup and is not canceled by pausing analysis. Claude Code remains an engine-specific install. The on-device model starts downloading after the post-FDA relaunch.
- `DisplayAwake` holds the screen on for the whole flow (the download and the first analysis run behind the slides).
- Right-clicks are swallowed for onboarding's whole lifetime (the film's webview would offer a browser context menu).
- Sidekick is home-only: before the film's notch beat a press does nothing; after it, the honest "finish onboarding to use Sidekick" aside; the notch's hover swell is off before the beat too.
- The DEBUG "SKIP TO HOME" handle quietly flips the flag (no finale). `FactoryReset` rewinds here.

## Related docs

`Cloud/Documentation - Cloud - Codex Setup.md`, `Cloud/Documentation - Cloud - Plan Gate (CodexAuth).md`, `Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md`, `Views/Permissions/Documentation - Permission Gate & Guide.md`, `Engine/Documentation - On-Device Engine & Triage.md` (the download), `Views/Documentation - Views - Home, Processing & Shared UI.md` (`ProcessingView`, the finale), `Notch Magic/Documentation - Sidekick - General.md` (the notch demo).
