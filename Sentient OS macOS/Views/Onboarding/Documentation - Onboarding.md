# Onboarding (Views/Onboarding/)

First launch has two steps: the existing film/Sidekick/Magic Reply lessons, then choose and connect a
frontier model. The model screen requires the feedback email popup before Continue opens Home.
Sidekick asks for its essential computer-use access
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
| `OnboardingFilmView.swift` · `OnboardingMagicReplyView.swift` | Step 0: the website film, native Sidekick interaction, then the native Magic Reply lesson. |
| `OnboardingFrontierModelView.swift` · `OnboardingCodexSteps.swift` | Step 1: the engine picker with the codex login as the ChatGPT panel; engine preparation and login, the `codex --help` confirmation poll (skipped until a codex install exists), the manual-install panel; the shared onboarding bits (`OnboardingWhisper`, `OnboardingDoneLine`, `MonoWaitLine`, `OnboardingStatusText`). |
| `OnboardingEmailPrompt.swift` | Required email popup over the model screen, with validation, durable local enqueue and the optional company welcome. |
| `PersonalSetupView.swift` | Optional independent window; Home and Sidekick retain their lifetime while sources are connected. |
| `OnboardingPermissionsView.swift` | `OvernightSetupRequirements`: wake and login controls shown only after choosing overnight analysis. |
| `OnboardingReadyView.swift` | Resumable source picker with three usable selections required before first analysis. No mandatory email prompt. |
| `AnalysisTimingSheet.swift` | Required wake/login setup with guidance and immediate first-analysis start. |
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

**0 · The film and native lessons.** `OnboardingFilmView` embeds the allowlisted website film
and coordinates native demonstrations through `CommandCoordinator`. On a supported built-in
notch, the invitation offers physical touch; disabled or unavailable sensing falls back to the
configured keyboard shortcut. The film can warm eligible sensors before a lesson accepts input.
Warmup is owner-scoped, follows foreground/display/lock state, and cannot dispatch an action.
Entering a lesson fences old sensor events so a touch during the intro cannot answer it.

The native action sequence highlights the real quick-action controls and performs inert Take Over
and Magic Reply demonstrations. `OnboardingActionCue` owns the lesson stage; the film's owner,
generation and current phase fence delayed callbacks. The reply demonstration uses fictional email
content through `OnboardingMagicReplyDemo` and `OnboardingMagicReplyEmail`. Its keyboard alternative
uses `OnboardingDoubleTapKeyboard` and the actual shared shortcut. These lessons never read a real
knowledge base, call a task provider, book anything, or send a message. Leaving the film cancels
owned demonstration work and releases warmup. The website film has bounded loading/park waits
and an offline fallback. Native controls own progression, and the model step remains next.

`OnboardingRestaurantStory` supplies the allowlisted restaurant-film protocol for supported
clients. Display layout and the notch pointer use the native window's measured coordinates;
unsupported layouts keep the keyboard route. Changes to the embedded webpage require the team's
separate website deployment; publishing this app source does not deploy that page.

The model step shares `ModelChoiceBar`, `ModelSelectionHeading`, and `ModelSelectionPanel`
with Settings: animated white capsule selections, a centered title, and the permission window's
soft edge lighting. It only configures the main AI; the Main AI / Magic Reply switch and all
Magic Reply model controls remain exclusive to Settings. Provider activation and login ownership
are unchanged by the presentation.

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

**Feedback email.** After two seconds on the active model screen, `OnboardingView` blurs and disables
the background and presents `OnboardingEmailPrompt`. Leaving the screen cancels the timer; an
inactive app or an active invitation gift defers it. Continue cannot bypass email entry during the
delay. Saving validates and durably queues the address through `MailAccountCloud.onboarding`;
background retries send it to `onboarding_contact_emails`. After the optional company welcome,
the popup closes and the user resumes model connection. The disclosure reads: “Your email is only
saved for the founders to reach out for feedback. We never spam you.”

The existing `onboarding.emailSubmitted` flag suppresses repeat prompts across relaunches.
Completed users keep Home access; Factory Reset re-arms the prompt. Provider selection tests cover
the delay, cancellation, modal completion and Continue gate; personal-setup tests cover relaunch
and migration. The contact-retention fixture verifies durable enqueue and offline retries.

**Plan access.** Free/Go users can enter Home and try Sidekick. The picker describes limited usage
without another plan screen. A provider-reported usage limit or plan denial on a known Free/Go
ChatGPT task offers Upgrade to Plus, Change AI, Try again and Stop in recovery. Generic network,
permission, connector or model errors do not become a billing prompt. Migration retires the old
`plan.kbOnly` flag; no upgrade requires erasing knowledge or repeating onboarding.

## Optional personal setup

The panel, Analysis and menu bar open the same `personal-setup` window. Source
selections persist immediately. Closing it returns to Home without starting work. Three selected,
usable sources are required; a disconnected connector or unavailable local database does not count.
The user's explicit connector choice is authoritative. Done accepts that choice without a
content probe or cached-health gate. A failed read records that attempt's outcome without silently
unselecting the source. Account ownership, explicit opt-outs, read-only permissions and durable
saves remain enforced. Completed structured summaries do not require a particular native receipt,
query sequence or prose format. A later successful retry resolves earlier attempt errors.
Fresh Desktop/Downloads/Documents toggles are off. Migration preserves established users' old
implicit defaults and every explicit saved choice, including false.

Selecting a protected source opens its own FDA explanation. Cloud sources, Apple Calendar and
user-selected folders use their appropriate access paths. No broad FDA screen precedes the picker.
The pending protected source survives a deliberate restart, while resetting Sentient clears that UI
intent. Relaunch preserves the current unsent request and cannot interrupt an active task or analysis.

Continue opens background setup. Start analysis is handed off only after SwiftUI reports
dismissal and the native parent window has no attached sheet. `AnalysisTimingHandoff` combines the
native did-end-sheet notification with attachment observation, consumes the result once, and cancels
it if the owner closes, detaches or resets. This avoids closing setup underneath a live native sheet.

First analysis has no overnight timing choice. Wake helper readiness and launch-at-login must both
pass before Start analysis is enabled; already enabled settings count without extra clicks. Only
explicit setup actions request registration, and approval-required states open the floating System
Settings guide. Start rechecks both services and source count, and dismissing the sheet cancels a
pending start. First analysis begins now; Pause/Resume remains available in the analysis window.
Neither path asks for voice or notifications. Background setup plus Start completes personal
*setup*; `ProcessingPlan.initialCompletedAt` remains the proof of successful initial *analysis*.
Local-source analysis waits for the local model; cloud-only analysis can proceed without it.
Partial and empty runs retain useful work and explain what needs attention without unlocking
personal-context features prematurely. Sidekick stays available throughout.

Gmail and Outlook Mail retain the disclosed email-only feedback-list behavior. Explicit Done in
their connection sheet records that consent; collection waits for a later authorized mailbox run.
Missing connections/addresses remain pending. This connector list is separate from the required
email popup on the onboarding model screen; personal source setup does not repeat that popup.

## Durable state and migration

- `hasCompletedOnboarding` admits Home after email submission and model setup. It does not consent to sources.
- `onboarding.personalSetupCompleted` records completed background setup and the explicit Start analysis action.
- `scheduler.firstCycleCompletedAt` retains the shipped successful-analysis milestone.
- `onboarding.firstSuccessfulSidekickTask` excludes demos, cancelled work and proactive-card runs.
- `onboarding.personalSetupStage` remembers Sources/Timing; ordinary quit returns to Home.
- `onboarding.resumePersonalSetup` is consumed once after an explicit permission restart.
- `onboarding.sidekickFirstVersion` prevents a new Home-only user being mistaken for completed
  legacy setup on a later launch.

Old completed users retain access, source choices, knowledge and schedule intent. Users already past
the old model step enter Home with setup still optional. Interrupted first analysis reopens paused, including old scheduled-first-run plans. An explicit
pause stays paused until Resume; later nightly updates keep their existing recovery policy. Factory Reset clears the new milestones and restart intent while retaining explicit sources.
After successful cleanup, `AppState.didResetPersonalData` also clears the app-owned Home presentation:
conversation/search controls, old cards, and remembered visit state. Completing onboarding in that
same process returns to the Sidekick invitation and four suggestions. Ordinary window reopen still
preserves the user's chosen conversation view.

## Privacy explanations at setup

The model step explains the split: your on-device model understands local sources; your selected AI
organizes the resulting knowledge and powers assistance. Apple Mail and Apple Calendar work without
a ChatGPT or Claude subscription. Hosted connectors, Magic Reply and optional sharing have distinct
settings rather than one blanket “everything stays local” promise.

The native Magic Reply lesson explains its unsent draft and covered GPT-6.1 Sol route. One-time
writing-style setup reads only opted-in chats and enabled connected mail. Missing samples never block
Magic Reply or completion of useful initial analysis. Home retries absent samples once per eligible
selection; an existing user-authored file is never replaced. The frontier step links to the full
policy and diagnostic controls through `OnboardingTelemetryConsent` and shared `PrivacyCopy`.

## Things that happen around the steps

- AppState starts shared Codex CLI/native preparation at launch. Compatible installations are reused. The local model starts downloading during the intro into app-owned Application Support without FDA; it never gates Home or Sidekick. Claude Code remains engine-specific.
- `DisplayAwake` holds the screen on only during active foreground film playback or replay. Paused screens, the interactive lesson, inactive scenes, and leaving the film release the hold.
- Right-clicks are swallowed for onboarding's whole lifetime (the film's webview would offer a browser context menu).
- Sidekick is available after the model connection and remains available during personal setup. The film retains its isolated notch demo and the existing pre-Home gesture policy.
- The DEBUG "SKIP INTRO" handle jumps straight to the frontier-model picker from any intro phase,
  including loading and the native lessons. It skips the transition animation, tears down the demos,
  and records the intro as passed without choosing a model or completing onboarding. The separate
  "SKIP TO HOME" handle quietly flips the completion flag (no finale). `FactoryReset` rewinds here.

## Related docs

`Cloud/Documentation - Cloud - Codex Setup.md`, `Cloud/Documentation - Cloud - Plan Gate (CodexAuth).md`, `Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md`, `Views/Permissions/Documentation - Permission Gate & Guide.md`, `Engine/Documentation - On-Device Engine & Triage.md` (the download), `Views/Documentation - Views - Home, Processing & Shared UI.md` (`ProcessingView`, the finale), `Notch Magic/Documentation - Sidekick - General.md` (the notch demo).


## Wrong-side Command correction

Both the Sidekick invitation and the waiting phases of the native Magic Reply lesson use
`OnboardingShortcutHint`. A standalone left-Command tap, while the configured shortcut is
right Command, sweeps the Sentient spectrum across only “right” for one second. Repeated wrong
taps coalesce into one sweep. Reduce Motion uses a still color highlight for the same duration.
On a notch-equipped Mac, a mistaken keyboard tap switches the invitation to the keyboard cue.

The monitor is local to the owning key window and exists only while its instruction can accept
input. It returns every NSEvent unchanged. It never reads typed characters, adds a global key
listener, requests permission, launches Sidekick, or counts a wrong tap toward a Magic Reply reply.
Intervening keyboard/mouse input, recording shortcuts, focus loss, custom bindings and teardown
cancel or suppress the correction. The gesture uses the existing `ShortcutTap` validator.
The Magic Reply phase, rather than its animated opacity, is the authoritative input boundary.

Checks: `Scripts/test_onboarding_shortcut_hint.swift` covers gesture and pulse lifecycle logic;
`Scripts/test_sidekick_polish.py --invitation` exercises local NSEvents and captures the white
Sidekick button and both real Magic Reply samples. It also verifies normal clicks still finish
the lesson and that hint listeners detach when their instruction leaves.
