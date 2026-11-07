# Sidekick (Notch Magic/): the general doc

**Pick up exactly where you are.** Click the notch and ask Sidekick to “finish this for me.” It uses
screen context and the knowledge Sentient has built to work in your own apps and logged-in browser.
The aim is a small handoff in the middle of your day: finish a registration, work through a form,
follow up on an email, or carry information between apps without restating the whole background.
The request still needs to make your intent clear, and results depend on the model and available context.

Sidekick is also the shared status surface while a user-requested task runs. Tap the Sidekick key
(right Command by default) or click the notch to type. Hold the physical notch or use its microphone
to dictate. Double-tapping the key drafts a reply through Double Tap. Ordinary commands share the
selected frontier backend and computer-task run; the notch's Summarize and Proofread actions have
small, dedicated request paths.

This doc covers the brain and the backend: the coordinator, the run model, the hotkey, voice, the
screen stills, and the prompt. The window, the click-through mechanics, and the visual are in
`Documentation - Sidekick - Notch Window & Visual.md`.
Durable messages, history, context compaction, memory and their verification are documented in
`Documentation - Sidekick - Conversation Backend.md`. The conversation presentation is separate
UI work; these backend seams already survive provider-process and Home-view lifetimes.

## Files

| File | Job |
|---|---|
| `CommandCoordinator.swift` | The app-lifetime brain: owns the one shared run, the hotkey, and voice; drives `phase` (`NotchPhase`), the press → voice or type flow, `submit()`, STOP and cancel, adopted card runs, the notch-as-a-button seams, the onboarding notch demo, and the display anchor. |
| `SidekickDiscovery.swift` | Local ready-hint acknowledgement keys and a bounded count of accepted notch/voice submissions, used to retire Home's learning cue. No task content or telemetry. |
| `CommandRunModel.swift` | Sends ONE user task directly through `FrontierRun.runAgentCommand`, cleans codex's raw stream into the status line and the "Remembering" state, and holds the adoption seams for card fires. `isRunning` is the app-wide lock. Builds the command prompt. |
| `SidekickHotkeyMonitor.swift` | The zero-permission global hotkey: NSEvent `flagsChanged` monitors (global + local) reading the right-key device bit. Press / hold-confirmed / release. |
| `VoiceCapture.swift` · `ScribeRealtimeEngine.swift` · `DictationAudio.swift` | Active dictation: microphone permission, ElevenLabs Scribe streaming, bounded finalization and cancellation. |
| `ScreenCapture.swift` | A still of EVERY display at fire time (main first), attached to the codex run so "finish this" resolves against real pixels. |
| `SidekickInteraction.swift` · `SidekickToolServer.swift` | Per-attempt recovery tools, instruction updates, reporting capability, waiting state and task/attempt correlation. |
| `SidekickTaskSummary.swift` | Stages intent/final workflow phrases, validates their format locally and reports one task outcome and description without additional inference. |
| `NotchWindowController.swift` · `NotchView.swift` · `NotchShape.swift` · `NotchSpace.swift` · `SpinningLogo.swift` | The window and visual (the other doc). |

`AppState` owns one `CommandCoordinator` and one `NotchWindowController`. It starts both once at normal launch, or defers both until an eligible pending computer-use upgrade finishes. Closing/minimizing setup cannot start them; native migration can explicitly defer setup while first-use gates remain enforced.

## The doors, and where they meet

```
hotkey tap ────────► SidekickHotkeyMonitor ─┐
notch click ────────────────────────────────┤─► CommandCoordinator ─► CommandRunModel ─► FrontierRun.runAgentCommand
home PromptBar ─────────────────────────────┘        │ owns phase (NotchPhase) + VoiceCapture
card fire ──► coordinator.beginExternalRun ──────────┤   (adopts the run and transfers its Task to the app)
                                                     ▼
                                          NotchWindowController renders coordinator.phase + run
```

`NotchPhase`: `hidden · opening · listening · transcribing · typing · running · finishing(outcome) ·
notice(message)`.

**Input and routing.** A completed shortcut tap waits for the Double Tap interval before opening
the type field. Notch presses support click-to-type and hold-to-dictate. Voice stops recording before
finalization; only the finished transcript is submitted. Escape and the explicit controls dismiss or
cancel the active input. Ordinary Sidekick actions keep their existing permission/setup gates.

The typing notch has small Summarize and Proofread shortcut chips. Explicit
voice and notch-typed requests route to these features before the ordinary provider gate. Mentions,
negations, conversation replies and unrelated commands retain their existing semantics. No knowledge
analysis or Sidekick subscription is required for these covered utility requests.

Before the notch becomes key, `Proofread` captures the original selection. The field waits for that
bounded read, and an intervening input/application change cancels the delayed focus transfer. The
active display is also remembered for Summarize. Ordinary submissions and adopted actions reject
while proofreading owns the editing path; Double Tap and Proofread exclude one another through paste
cleanup. Summarize remains a separate read-only request.

The main Sidekick agent also receives `summarize_screen` and `proofread_text` through its per-run
`sentient_recovery` MCP server, shared by Home, notch replies and card tasks. Natural-language
requests outside the quick matcher can therefore use the same specialist services. Summarize opens
the normal reader and returns its text plus the captured app/window identity. The default target is
the external app captured at invocation; an explicit observed application ID can select another
running app. A Home request with no external target requires that explicit app choice.

`proofread_text` returns the exact conservative correction from `ProofreadInference` and explicitly
reports `applied=false`. The agent uses its ordinary editing tools to apply it only when requested and
the original target is still valid. The tool itself never pastes or sends text. Per-run callbacks are
fenced by the run ID; cancellation closes an in-flight Summary reader, and JSON-RPC retries reuse
the same completed tool result. Background model work has no quick-action capability.

See `../Summarize/Documentation - Summarize.md` and `../Proofread/Documentation - Proofread.md` for
capture, data boundaries, completion and fallback behavior.

**Adopted card runs.** `beginExternalRun(caption:onStopRequest:)` lets a proactive card's fire (any
fireable method: computer, gmail, calendar; not research) adopt THE run: `run.adoptExternal` flips
`isRunning` and seeds the status with the card's title, the notch rises in `.running`, the card's raw
codex lines tee through `run.externalPush` (same cleaning), and every exit completes the adoption exactly
once via `run.completeExternal` (no scoreboard or analytics from here; the executor records every card
fire itself). `ownExternalTask` retains the card task in the app-owned run. Home can disappear or
be recreated without cancelling work; persisted card completion precedes releasing the run lock.
`stop()` cancels that owned task (the initial callback covers the interval before transfer).
So `run.isRunning` locks
every other entry point, other fireable cards dim, `beginExternalRun` returns false while anything runs,
and explicit Stop surfaces cancel the owned task.

**Cancel and STOP.** `cancelCurrent()` backs out of whatever the notch is doing: dismiss the type field;
abandon an open / listening / transcribing capture; or, ONLY while the voice transcript is still shown
(the "you misheard me" moment), cancel the run and dismiss instantly with no flourish. Once the transcript
dissolves into the working line, cancel leaves it alone. Two routes feed it: the notch window's LOCAL Esc
monitor when Sentient owns keyboard input, and the explicit Stop controls. There is no global Escape
monitor. Proofread additionally treats a fresh Sidekick-key tap as cancellation; a single tap does
not silently stop an ordinary running Sidekick task.

**Completion.** `run.onFinished` → `.finishing(outcome)`: ✓ and stopped flourish for 1.5 s, a failure
holds 5 s (its caption carries the ✗ reason). `message_user` final answers include the explicit
`completion: "done" | "could_not"` field. `AgentStatus.resolve` checks this task-scoped claim after a
clean provider exit, with the exact final `STATUS: DONE` / `STATUS: COULD_NOT` line as a compatibility
fallback. A refusal from either source wins over a contradictory DONE. Without either source the
outcome remains unconfirmed; saving a plain message or exiting zero alone never means success.
Substantive tools, new provider legs and questions invalidate earlier structured completion claims.
Failed/cancelled providers and connector action-evidence checks still control the actual outcome.
Visible final answers omit a standalone terminal STATUS protocol line. Quoted and code examples
remain intact, and this display cleanup does not create or alter a completion claim.

**Provider-plan recovery.** Free and Go users can use Sidekick until their provider declines a
request. A Plus offer is attached to recovery only for the original ChatGPT task backend, a positively
known Free/Go account, and an actual Codex provider usage-limit or explicit plan-denial error. Model
reports, unknown/premium plans, other backends, connector quotas, network/permission failures and
missing-model errors never produce the offer. The typed policy lives beside `SidekickTaskEnd`; the
recovery presentation carries only its fixed-vocabulary result, never reparses model wording.

Home and the notch share **Upgrade to Plus**, **Change AI**, **Try again** and **Stop** actions. Pricing
opens only after a click and does not change billing. Changing AI opens the existing provider settings.
The pending recovery and editable retry guidance survive hiding the panel while the user visits
pricing/settings. Retry keeps the existing task-recovery path; no model or provider is changed for them.

`setPhase` bumps a token that every delayed transition checks, so a stale timer can never clobber a
newer phase.

**Diagnostic consent.** An eligible last-resort computer-use check uses the ordinary inline/notch
question UI. `ask_user` accepts the optional `computer_use_check_id` returned by the native broker;
the app substitutes its own fixed explanation and **Run check / Not now** choices. Only a real
affirmative answer produces a task-scoped, single-use authorization. The question does not open the
test window or reset the connection. Declining/cancelling prevents another offer during that task.
Browser-specific problems and routine interrupted actions keep using normal recovery, not diagnostics.

## The run model (`CommandRunModel`)

`start(text, mode, source)` owns one Task through permission readiness, screen/context capture,
main-agent execution, cancellation, and completion. Every submission goes directly to
`FrontierRun.runAgentCommand`, including tasks that fit one connector. The main agent selects
connected-service, web, and computer tools itself. No preliminary model routing or connector-only
Sidekick executor runs. Historical router evaluations remain DEBUG-only lab fixtures.

The main agent reads the current speed preference at fire time. Paid ChatGPT uses GPT-6.1 Terra/low,
GPT-6.1 Sol/low, or GPT-6 Astra/low; Free/Go uses GPT-6 Luna at low/medium/high. Claude uses
Sonnet 5.5/low, Opus 5.5/low, or Opus 5.5/medium on both Pro and Max. Custom providers keep their own
model/reasoning choice. Proactive card buttons submit a durable card reply through this same main-agent
path; they have no separate model selection or executor. Screenshots, history, saved instructions, cancellation and the one-task lock remain shared.

Completion parses `AgentStatus`, records the existing scoreboard and analytics outcome, and reaches
the shared finish epilogue. Card runs use ordinary submission and Stop. Explicit external-run adoption remains for diagnostic callers.

The stream cleaner (`push`): strip the `stderr:` channel tag; track codex's bare section headers
(`user` / `codex` / `exec` / `thinking` / `tokens used`) and never show them; in the `exec` section
surface knowledge-base reads as the **`remembering`** state (any shell command whose quoted path is
inside the vault; held ≥ 1.5 s so the bloom completes) and drop all other shell output; drop the
startup banner, the prompt echo, reasoning, counts, and raw `STATUS:` lines; keep codex's narration and
tool lines, the last two joined as `statusLine`. The confirmation-policy dump's tail becomes "Thinking
through your task".

The running notch renders raw tool-status lines through the same `SidekickActivityPresentation`
labels and cached app icons used by chat. Its observable conversation projection reads one indexed
latest-activity row for the active task; it never scans the full activity history. Caption changes
blur-dissolve (fade with Reduce Motion). Agent narration, connection notices, read-back and memory
status retain their existing priority. Ending/resetting a task clears its live activity projection.

The notch always uses the full `SpinningLogo` brand mark, including idle and reduced-motion states.
It rotates slowly before work (13 seconds per turn, 30 Hz) and faster while running (2 seconds,
60 Hz). Hidden, Reduce Motion and Low Power states pause the same artwork rather than substituting
a different ring/dot design. Pausing/resuming retains the current angle.

Both ChatGPT and Claude computer runs emit activity through `ComputerUseStream`; Claude's bridge
provides narration only. `SidekickActivityLab` (`SENTIENT_SELFTEST=sidekickbackend`,
`LAB_SIDEKICK_COMMAND=activity`, `LAB_SIDEKICK_PROVIDER=chatgpt|claude_bridge`) validates the real
authenticated providers against six in-memory native tool calls, temporary conversation storage,
and the exact shared notch projection. It checks label/icon identity parity and hidden message/usage
wrappers without launching the computer-use helper or touching real apps. Each provider needs its
normal login; results include content-safe status snapshots for comparison.

Message previews include a native reply field and Open in Sentient button. The field shares Home's
draft; submission uses the normal coordinator gate with the displayed message's exact reply reference.
Return sends inline without opening Home, and rejected/active-task submissions retain the draft.
Selected-text Reply targets that quote and focuses the inline field. Auto-presentation remains
non-key; only editing requests keyboard focus. Focus or an unsent draft holds attention so a timeout
or newer message cannot replace the preview mid-reply. Closing keeps the draft/reference for Home.
`test_sidekick_notch_reply.py` exercises native editing/Return and renders the real view in an inert
nonactivating panel; attention and layout fixtures cover timing, coalescing and bounded reading space.

`startOnboardingDemo()` starts the presentation-only restaurant story. Known, versioned webpage
progress beats drive `advanceOnboardingDemo`, including the real Remembering bloom for Weekend plan.
There is no provider, vault read, screenshot, booking, send, conversation record or first-task milestone.
Stopping or leaving the film ends the demo immediately; backward and late beats cannot restart it.

## The prompt (`CommandRunModel.commandPrompt`)

The command prompt includes the requested task, a speech-transcription note when appropriate,
screenshot context for “this” and “here,” the user's standing Sidekick memory, and the
knowledge-folder path. It asks the model to read knowledge with file tools, act through computer-use
tools, verify the result, and finish with the `STATUS` sentinel. Retrieved pages, messages and other
content are explicitly framed as data rather than new instructions.
`SidekickInteraction` injects the current memory snapshot, bounded recent conversation and reply
reference across execution routes. Previous screenshots and raw tool traces are never injected.
The model sends explicit Markdown through `message_user` and must finish with a user-facing answer
and structured completion field. The claim is recorded only after the answer commits, is never
accepted while substantive tools are pending, and does not replay work if the final STATUS line is
omitted. The app separately persists the resolved execution outcome and handles missing-answer
fallbacks. `Scripts/test_sidekick_run.py` and `Scripts/test_sidekick_tools.py` cover final outcome
precedence, stale-claim invalidation, exact RPC replay, save failures and legacy replies.

At dispatch, `FrontierRun` appends the selected runtime's manual once. Every active backend uses
`OpenAIComputerUse.promptRules`; custom models also receive `CustomProvider.computerUsePromptRules`.
Prepared direct connector attachments and their account-specific guidance follow the same dispatch.
The native computer-use guide describes the shared snapshot → act → verify contract.
For user-initiated computer tasks, `SidekickInteraction.websiteInstructions` covers CAPTCHAs,
required site terms, and consent dialogs. Codex receives it as a developer instruction, and
the Claude bridge appends the same text to its system prompt.

## Hotkey and dictation

`SidekickHotkeyMonitor` uses local/global `NSEvent.flagsChanged` monitors and the configured key's
device bit. `ShortcutGesture` recognizes standalone taps and pairs; input counters prevent a key
used in another shortcut from becoming a Sidekick gesture. Monitors install after launch. No global
keyboard event tap is installed. A tap during Proofread cancels that operation; ordinary Sidekick
work retains its explicit Stop controls.

`NotchPressGesture` owns physical mouse-down/hold/release across changing views. `VoiceCapture` uses
microphone authorization and ElevenLabs Scribe. Its first-use explanation discloses cloud audio
transcription. Audio capture stops before any asynchronous finalization or model dispatch; a bounded
finalize and session IDs reject stale results. Failed dictation preserves available words as a draft.
Clicking the microphone latches recording; clicking its Stop control finalizes into the same
editable prompt or reply. Send/Return explicitly submits. A held press sends on release near its
origin; release more than 48 pt away keeps a draft instead. The duration limit also keeps a draft.
A final answer hides the task Stop while backend cleanup still holds the execution lock. Reply
recording can begin during that cleanup; dispatch waits briefly for it, retaining the draft if busy.
The presentation signal is a saved answer with no substantive tools in flight, independent of the
separate success/failure claim. New tool work or a question invalidates it. This distinction does not
relax outcome verification or allow two agent executions. Answer previews never put a task Stop
beside the dictation controls; progress-update previews may retain it while actual work continues.
The active path does not request macOS Speech Recognition permission or use the older speech engines.

## Screen context (`ScreenCapture`)

At fire time `grab()` shells `/usr/sbin/screencapture -x -t jpg -D <n>` once per display (main first by
its own contract; a 5 s watchdog per call), returns the temp JPEG URLs, and the run attaches them with
`codex exec -i`. Gated on Sentient's own Screen Recording grant (`CGPreflightScreenCaptureAccess`) —
now a REQUIRED action grant (the driver's eyes ride it too), so the first-fire gate acquires it before
any run; if it regresses mid-session the run goes text-only, never a prompt mid-command, and Health
banners. The frames are supplied to the selected model through the task runtime and their temporary local
files are deleted after the run. A hosted model processes screen context under the chosen provider's
settings; a compatible local model processes it on the Mac. Release diagnostics record sizes, not
screen contents. The proactive executor passes no frames.

## Context, permission and control

Your request, useful knowledge and screen/app context give meaning to a short handoff. Sidekick can
read more context as a task requires; a visible page is not its only source of understanding.
Frontier Model Choice controls its inference provider, while Double Tap's provider is independent.

A user starts each task. The notch shows progress, and STOP cancels the active run. The task may
perform the actions the user requested, so this is an execution surface, not always a draft for a
second confirmation. Prompt guardrails and tool policies guide the run; they are not a claim that
all model mistakes or malicious page instructions are impossible.

## Task reporting

Technical diagnostics correlate operation scopes and retry attempts through app-generated IDs. Tool
names use a fixed vocabulary or a broad family; model and process outcomes are recorded separately.
Recovery reports omit question, answer and error text. See the diagnostics guide for reporting gates.

Eligible user-requested Sidekick attempts can provide a short workflow description for product
analytics. The selected task model calls `describe_task_usage` with intent before actions and a final
phrase before finishing. This bookkeeping does not mark success or appear as progress. Later activity
invalidates a final phrase; a valid original intent can describe an interrupted attempt. Null or
rejected replacements withdraw earlier text. Task completion consumes the report once.

Local checks constrain phrase length, word count and characters. There is no separate model review.
The prompt requires generalized descriptions without identifying or sensitive details, but format
checks and model instructions do not guarantee anonymity. Task outcomes, fixed interruption reasons
and descriptions remain enabled in Release independently of extended analytics, as disclosed in
onboarding and Settings. Debug skips submission. See the diagnostics guide and `SECURITY.md`.

## Rules

- One run at a time. Every new entry point must go through `submit` / `beginExternalRun`.
- Opening or hovering the notch does not prompt for permissions. Explicit dictation or action intent uses the corresponding permission flow.
- Content-bearing logs (transcripts, prompts, codex output) are `#if DEBUG` only; log lengths in Release.

## Related docs

`Notch Magic/Documentation - Sidekick - Notch Window & Visual.md`, `Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md`, `Views/Permissions/Documentation - Permission Gate & Guide.md`, `Proactive/Documentation - Proactive Intelligence.md` (card fires), `Views/Documentation - Views - Home, Processing & Shared UI.md` (`PromptBar`).

Computer-use runtime selection and its manual live in `FrontierRun`: native OpenAI tools through `codex exec` for every backend. Claude subscriptions use the local
ClaudeSubscriptionBridge for inference; dedicated connector tasks stay on the structured Claude path. See `Driver/Documentation - Native Computer Use.md`.

## Main-composer dictation

The Home composer has a microphone beside Send. It becomes Stop while starting/recording;
Stop finalizes into the editable draft without submitting. Send during dictation stops capture
synchronously, waits for the final transcript, then uses the ordinary composer send path once.
Interim transcripts append to the draft present at capture start without duplicating revisions.
Errors retain available words. Changing the answer target, hiding Home, clearing chat or starting
notch dictation cancels the local capture and rejects stale callbacks. `ComposerDictation.swift`
uses the existing VoiceCapture/Scribe path; `test_composer_dictation.py` covers lifecycle behavior
without audio or providers.


### Speech vocabulary and retention

Scribe realtime receives the preferred system language and keyterms `summarise`, `summarize`,
`proofread`, `sentient os`, `sentient`, and `jesai`. The Cloudflare relay issues single-use tokens;
the Mac connects directly to ElevenLabs. The included configuration sets `SCRIBE_ZERO_RETENTION=false`.
Zero retention depends on provider account capabilities and must be verified for the deployed setup.
The existing client fails closed on a retention warning when zero retention is requested.
