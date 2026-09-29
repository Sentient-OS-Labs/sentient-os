# Onboarding (Views/Onboarding/)

First launch, zero accounts: the film → choose your frontier model (with the codex login embedded) →
the plan crossroads (free/go ChatGPT accounts only) → permissions → the ready-to-process screen → the
REAL first analysis (pausable) → the finale (the home appears and the Knowledge window's Constellation
opens on top). The current step persists (`onboarding.step`), so the quit-and-relaunch that granting
Full Disk Access requires resumes exactly where the user left off.

## Files

| File | Job |
|---|---|
| `OnboardingView.swift` | The step switchboard, the whole-onboarding screen-awake hold, the Back button, the GitHub mark, the right-click blocker, the DEBUG "SKIP TO HOME" handle, and the two-minutes-in selected-runtime download. Also `OnboardingNextButton`, `OnboardingBackButton`, `OnboardingTrustFooter`. |
| `OnboardingFilmView.swift` | Step 0: the website's film in a `WKWebView`. |
| `OnboardingFrontierModelView.swift` · `OnboardingCodexSteps.swift` | Step 1: the engine picker with the codex login as the ChatGPT panel; the lazy install-on-commitment kicks, the `codex --help` confirmation poll (skipped until a codex install exists), the manual-install panel; the shared onboarding bits (`OnboardingWhisper`, `OnboardingDoneLine`, `MonoWaitLine`, `OnboardingStatusText`). |
| `OnboardingPlanView.swift` | Step 2: the plan crossroads. |
| `OnboardingPermissionsView.swift` | Step 3: overnight wake → launch at login → Full Disk Access, unlocking sequentially. |
| `OnboardingReadyView.swift` | Step 4: the source tiles and the big Start Analysis glow. |
| `OnboardingModelDownloadView.swift` | Shown between Start Analysis and the takeover if the model has not finished landing. |
| `OnboardingTelemetryConsent.swift` | The film's final park: "We never collect your personal info." with Read More (the privacy policy) and Configure Telemetry (the two toggles, the same keys as Settings). |

## The steps

**0 · The film (`OnboardingFilmView`).** `https://sentient-os.ai/onboarding?end=0.42&notch=real|key` in
a webview that is a movie, not a page (hit-testing off, off-host navigation blocked, fades in only after
the page reports ready). The page's autopilot scrolls the film and posts "parked" at each rest, which
blooms the native Continue: leg 1 (the night film → the morning home), leg 2 (the Sidekick scene: it
rides to the invitation whisper, "Click the notch" on a lone notched display or "Press the right ⌘ key"
otherwise, then WAITS for the user's real answer: the coordinator's armed one-shot demo takes a bezel
click or a hotkey press and performs the shopping story on the user's own notch while the film rides on),
leg 3 (the Under-the-hood exhibit, the film's one interactive park, with the telemetry consent block).
Watchdogs bound every wait (12 s to load, 40 s to park); offline or a failed load falls back to a quiet
branded slide, so onboarding is never blocked on the network. The parked beats are addresses into the
film's scroll timeline and must be re-derived if the website re-paces the film. `dev.film.url` (DEBUG)
points the step at a local dev server.

**1 · Choose your frontier model.** The shared `FrontierEnginePicker` in a single centered row over
the per-engine panels, with `OnboardingCodexLoginPanel` as the ChatGPT panel and the picker's own
self-contained Claude panel. **Installs are lazy** (decided 2026-08-21): nothing downloads at launch
or on screen appear — "Log in with ChatGPT" is the codex download moment (mid-install the button
greys and the streamed progress narrates; the sign-in follows on its own the moment the install
lands), "Sign in with Claude" is Claude Code's, and a custom tab's Test & Select installs codex
before probing (the CLI is the engine room even for custom endpoints). Both login panels notice the
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
Downloads, Documents armed by default; WhatsApp / iMessage pickers; Notes; Gmail / Calendar connect
sheets, locked where connectors are unavailable), the shared four-selection minimum, and the
full-brightness Start Analysis glow. Start presents the real `ProcessingView` (`.auto`, `pausable`,
`fullCycle` when the deck is real). If the on-device model has not finished downloading, the
downloading screen (`OnboardingModelDownloadView`: the signature glow bar, GB of GB, Try Again on
failure) covers the tail and hands off to the analysis by itself the moment the model verifies. Only a
finished run calls `onFinished`.

## Things that happen around the steps

- Frontier CLIs install at engine commitment. The on-device model starts downloading after the post-FDA relaunch; the selected computer-use runtime is prepared two minutes into the first analysis. ChatGPT prepares OpenAI's signed helper; Claude/custom prepare CUA. The unstructured shared installation is not canceled by pausing analysis.
- `DisplayAwake` holds the screen on for the whole flow (the download and the first analysis run behind the slides).
- Right-clicks are swallowed for onboarding's whole lifetime (the film's webview would offer a browser context menu).
- Sidekick is home-only: before the film's notch beat a press does nothing; after it, the honest "finish onboarding to use Sidekick" aside; the notch's hover swell is off before the beat too.
- The DEBUG "SKIP TO HOME" handle quietly flips the flag (no finale). `FactoryReset` rewinds here.

## Related docs

`Cloud/Documentation - Cloud - Codex Setup.md`, `Cloud/Documentation - Cloud - Plan Gate (CodexAuth).md`, `Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md`, `Views/Permissions/Documentation - Permission Gate & Guide.md`, `Engine/Documentation - On-Device Engine & Triage.md` (the download), `Views/Documentation - Views - Home, Processing & Shared UI.md` (`ProcessingView`, the finale), `Notch Magic/Documentation - Sidekick - General.md` (the notch demo).
