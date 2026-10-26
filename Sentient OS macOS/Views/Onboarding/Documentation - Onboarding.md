# Onboarding (Views/Onboarding/)

First launch has two steps: the existing film/Sidekick/Double Tap lessons, then choose and connect a
frontier model. Continue opens Home immediately. Sidekick asks for its essential computer-use access
on first use; personal sources, FDA, analysis, overnight wake, login items, voice and notifications
are not prerequisites for Home.

Home's Sidekick-first workspace keeps the composer usable beside an optional personal-setup panel.
The four feature examples start closed and have a top-left close button and Escape dismissal. Opening
an example never starts analysis or a task. Suggestions only fill the existing draft. After a real
successful non-demo Sidekick task, the setup invitation gains emphasis when Home is idle.

## Files

| File | Job |
|---|---|
| `OnboardingView.swift` | The step switchboard, the whole-onboarding screen-awake hold, the Back button, the GitHub mark, the right-click blocker, and the DEBUG "SKIP TO HOME" handle. Also `OnboardingNextButton`, `OnboardingBackButton`, `OnboardingTrustFooter`. |
| `OnboardingFilmView.swift` · `OnboardingDoubleTapView.swift` | Step 0: the website film, native Sidekick interaction, then the native Double Tap lesson. |
| `OnboardingFrontierModelView.swift` · `OnboardingCodexSteps.swift` | Step 1: the engine picker with the codex login as the ChatGPT panel; engine preparation and login, the `codex --help` confirmation poll (skipped until a codex install exists), the manual-install panel; the shared onboarding bits (`OnboardingWhisper`, `OnboardingDoneLine`, `MonoWaitLine`, `OnboardingStatusText`). |
| `PersonalSetupView.swift` | Optional independent window; Home and Sidekick retain their lifetime while sources are connected. |
| `OnboardingPermissionsView.swift` | `OvernightSetupRequirements`: wake and login controls shown only after choosing overnight analysis. |
| `OnboardingReadyView.swift` | Resumable source picker with three usable selections required before first analysis. No mandatory email prompt. |
| `AnalysisTimingSheet.swift` | Explicit Run now or Overnight choice, and overnight-only prerequisites. |
| `App/PersonalSetupProgress.swift` | Separate Home, personal-setup, first-task milestones and legacy migration. |
| `System/SafeAppRelaunch.swift` | Refuses active-work restarts, preserves an unsent draft and resumes personal setup after an explicit source-permission relaunch. |
| `OnboardingTelemetryConsent.swift` | Privacy policy and diagnostic controls over the frontier-model step; Read More opens the policy and Configure Telemetry uses the same two keys as Settings. |

## The steps

`FINAL_1000` grants unlimited lifetime access, just like `WAITLIST_OGs`. Both onboarding
and Settings redeem it through `redeem_invite`, without an email field, and show the lifetime
gift animation only after a verified permanent grant. The migration
`20261025010000_unlimited_final_invite.sql` also upgrades saved courtesy gifts without changing
existing lifetime receipts. Installed apps can still use `record_late_invite_use`: it now grants
lifetime access while preserving the `lateUse`/email response they verify. Their baked-in courtesy
animation text changes only when the app is updated; refreshed Settings shows lifetime access.
Legacy receipt decoding is retained for saved Keychain snapshots and installed-app compatibility.

`OnboardingWindowLayout` fits the 1100 × 820 design canvas into the display's usable area,
including the Dock and title-bar allowance. Smaller displays get roughly 80% scale, with a
scaled minimum window size and a fully laid-out logical canvas so bottom actions stay visible.
The main window's initial size follows the same policy. `OnboardingWindowFit` responds to display,
Dock, and window-size changes; moving to a larger display restores 100%. Home and Settings retain
their existing sizing after setup. The notch pointer converts its measured margins to the current
canvas scale, so it still points at physical screen coordinates.
The canvas must not clip its safe-area bounds: the film header and GitHub mark deliberately
render into the transparent title bar. The native window supplies the outer clipping boundary.

**0 · The film (`OnboardingFilmView`).** `https://sentient-os.ai/onboarding?end=0.42&notch=real|key&invitation=native&story=restaurant-v2` in
a webview that is a movie, not a page (hit-testing off, off-host navigation blocked, fades in only after
the page reports ready). The page's autopilot scrolls the film and posts "parked" at each rest, which
blooms the native Continue: leg 1 (the night film → the morning home), leg 2 (the Sidekick scene: it
rides to the native invitation, **Click your notch** on a lone notched display or **Press right Command**
(the actual configured key) otherwise, then WAITS for the user's real answer: the coordinator's armed one-shot demo takes a bezel
click or a hotkey press and performs the restaurant story on the user's own notch while the film rides on),
The restaurant story shows one message from James, with no earlier chat or floating memory card. It begins with “can you book that restaurant for the weekend?” and the
native prompt “finish this for me”. The notch shows Starting computer use for 0.5 seconds, then Remembering… with Weekend plan.
Only afterward does the browser open. The film books a fictional Juniper table,
and replies “done!” in a sample Messages window. All contacts, reservations and pages are fictional;
no real provider, vault, booking or send is involved. `OnboardingRestaurantStory` pins the version,
command, duration and allowed narration beats. The main-frame, same-host `autopilot` handler accepts
only that version's known beats while this step owns a running demo. The webpage drives the native
Remembering bloom and status from its actual progress. Duplicate/backward/late events are inert;
leaving the film cancels the demo, and a stalled film cannot announce success. Older installed apps
without a restaurant version keep the recipe; v1 clients retain Maya and their original timing.
V2 narration follows the unsprung, linear film clock, independently of the camera’s spring.

The final Sidekick park is `0.999`, followed by the native Double Tap lesson. The current native
sequence does not visit the website's Under-the-hood exhibit, FAQ or footer. The film is passive;
native controls handle progression.
`OnboardingSidekickInvitation` keeps the Messages request fully visible with one prominent native CTA at the
very top: Click your notch, or Press right Command with a compact keycap. Its straight vertical arrow
is a separate transparent, click-through `NSPanel`. The measured CTA aligns to the hardware's
centerline, with 12 pt between its top edge and the arrow's tail and 10 pt below the notch at the tip.
The arrow resizes when the app moves; the native film reserves a clear header above Messages. It cannot become key, hides when onboarding loses focus, and is removed as Sidekick opens
or the step exits. Display changes and disabled notch clicks switch to the keyboard instruction.
The arrow draws once and respects Reduce Motion. The website hides its older text/chevron only when
the new `invitation=native` parameter accompanies the embedded notch cut; older apps keep their cues.
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
For signed-in Claude, Continue prepares Claude Code, rechecks the login, saves Claude as the engine,
then advances; onboarding has no separate Use Claude button. Failed preparation or an expired login
keeps the current engine and stays on this step. Sign-in and installation retry actions remain when
needed, and Settings keeps its explicit Use Claude action. Other choices require the visible tab to
match the active engine: ChatGPT logged in, or the selected custom endpoint that passed Test & Select.

**Plan access.** Free/Go users can enter Home and try Sidekick. The picker describes limited usage
without another plan screen. A provider-reported usage limit or plan denial on a known Free/Go
ChatGPT task offers Upgrade to Plus, Change AI, Try again and Stop in recovery. Generic network,
permission, connector or model errors do not become a billing prompt. Migration retires the old
`plan.kbOnly` flag; no upgrade requires erasing knowledge or repeating onboarding.

## Optional personal setup

The panel, Analysis, Double Tap lesson and menu bar open the same `personal-setup` window. Source
selections persist immediately. Closing it returns to Home without starting work. Three selected,
usable sources are required; a disconnected connector or unavailable local database does not count.
Hosted Done verifies native connection metadata without a model call or content read. Proof belongs
to the current account. Claude's shared login is checked this process before cached proof can count;
an older account's check cannot certify a newer login. A later Stop reading or reconnect in another
window invalidates pending confirmation for that source, so late results cannot restore an opt-out.
Fresh Desktop/Downloads/Documents toggles are off. Migration preserves established users' old
implicit defaults and every explicit saved choice, including false.

Selecting a protected source opens its own FDA explanation. Cloud sources, Apple Calendar and
user-selected folders use their appropriate access paths. No broad FDA screen precedes the picker.
The pending protected source survives a deliberate restart, while resetting Sentient clears that UI
intent. Relaunch preserves the current unsent request and cannot interrupt an active task or analysis.

Start Analysis opens timing selection. Its chosen result is handed off only after SwiftUI reports
dismissal and the native parent window has no attached sheet. `AnalysisTimingHandoff` combines the
native did-end-sheet notification with attachment observation, consumes the result once, and cancels
it if the owner closes, detaches or resets. This avoids closing setup underneath a live native sheet.

Start Analysis opens timing selection. Run now records an explicit request and opens the separate
progress window. Overnight shows wake and launch-at-login controls, then records a scheduled request.
Neither path asks for voice or notification access. A timing choice completes personal *setup*;
`ProcessingPlan.initialCompletedAt` remains the separate proof of successful initial *analysis*.
Local-source analysis waits for the local model; cloud-only analysis can proceed without it.
Partial and empty runs retain useful work and explain what needs attention without unlocking
personal-context features prematurely. Sidekick stays available throughout.

Gmail and Outlook Mail retain the disclosed email-only feedback-list behavior. Explicit Done in
their connection sheet records that consent; collection waits for a later authorized mailbox run.
Missing connections/addresses remain pending. There is no forced manual email form in the new flow.

## Durable state and migration

- `hasCompletedOnboarding` now admits Home after the model step. It does not consent to sources.
- `onboarding.personalSetupCompleted` records the explicit analysis-timing choice.
- `scheduler.firstCycleCompletedAt` retains the shipped successful-analysis milestone.
- `onboarding.firstSuccessfulSidekickTask` excludes demos, cancelled work and proactive-card runs.
- `onboarding.personalSetupStage` remembers Sources/Timing; ordinary quit returns to Home.
- `onboarding.resumePersonalSetup` is consumed once after an explicit permission restart.
- `onboarding.sidekickFirstVersion` prevents a new Home-only user being mistaken for completed
  legacy setup on a later launch.

Old completed users retain access, source choices, knowledge and schedule intent. Users already past
the old model step enter Home with setup still optional. Interrupted analysis retains its persisted
plan. Factory Reset clears the new milestones and restart intent while retaining explicit sources.
After successful cleanup, `AppState.didResetPersonalData` also clears the app-owned Home presentation:
conversation/search controls, old cards, and remembered visit state. Completing onboarding in that
same process returns to the Sidekick invitation and four suggestions. Ordinary window reopen still
preserves the user's chosen conversation view.

## Privacy explanations at setup

The model step explains the split: your on-device model understands local sources; your selected AI
organizes the resulting knowledge and powers assistance. Apple Mail and Apple Calendar work without
a ChatGPT or Claude subscription. Hosted connectors, Double Tap and optional sharing have distinct
settings rather than one blanket “everything stays local” promise.

The native Double Tap lesson explains its unsent draft and low-latency covered route. One-time
writing-style setup reads only opted-in chats and enabled connected mail. Missing samples never block
Double Tap or completion of useful initial analysis. Home retries absent samples once per eligible
selection; an existing user-authored file is never replaced. The frontier step links to the full
policy and diagnostic controls through `OnboardingTelemetryConsent` and shared `PrivacyCopy`.

## Things that happen around the steps

- AppState starts shared Codex CLI/native preparation at launch. Compatible installations are reused. The local model starts downloading during the intro into app-owned Application Support without FDA; it never gates Home or Sidekick. Claude Code remains engine-specific.
- `DisplayAwake` holds the screen on during the introduction and model connection; Home ends that hold.
- Right-clicks are swallowed for onboarding's whole lifetime (the film's webview would offer a browser context menu).
- Sidekick is available after the model connection and remains available during personal setup. The film retains its isolated notch demo and the existing pre-Home gesture policy.
- The DEBUG "SKIP TO HOME" handle quietly flips the flag (no finale). `FactoryReset` rewinds here.

## Related docs

`Cloud/Documentation - Cloud - Codex Setup.md`, `Cloud/Documentation - Cloud - Plan Gate (CodexAuth).md`, `Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md`, `Views/Permissions/Documentation - Permission Gate & Guide.md`, `Engine/Documentation - On-Device Engine & Triage.md` (the download), `Views/Documentation - Views - Home, Processing & Shared UI.md` (`ProcessingView`, the finale), `Notch Magic/Documentation - Sidekick - General.md` (the notch demo).
