# Sidekick (Notch Magic/): the general doc

Sidekick is the global way to tell Sentient to DO something, and the universal status surface while it
works. Hold the Sidekick key (right ⌘ by default, or right ⌥) anywhere on the Mac and talk; tap it to
type; click the notch itself; or type in the home's command bar. Every door reaches the same backend
(connector tools or computer use through the selected frontier engine, grounded in the knowledge base) and the same living notch.
A proactive card's fire adopts the same run, so the notch, the command bar, and the card are three
views of one task, and there is exactly ONE task at a time app-wide.

This doc covers the brain and the backend: the coordinator, the run model, the hotkey, voice, the
screen stills, and the prompt. The window, the click-through mechanics, and the visual are in
`Documentation - Sidekick - Notch Window & Visual.md`.

## Files

| File | Job |
|---|---|
| `CommandCoordinator.swift` | The app-lifetime brain: owns the one shared run, the hotkey, and voice; drives `phase` (`NotchPhase`), the press → voice or type flow, `submit()`, STOP and cancel, adopted card runs, the notch-as-a-button seams, the onboarding notch demo, and the display anchor. |
| `CommandRunModel.swift` | Routes ONE task through the connector leg or `FrontierRun.runAgentCommand`, cleans codex's raw stream into the status line and the "Remembering" state, and holds the adoption seams for card fires. `isRunning` is the app-wide lock. Builds the command prompt. |
| `SidekickHotkeyMonitor.swift` | The zero-permission global hotkey: NSEvent `flagsChanged` monitors (global + local) reading the right-key device bit. Press / hold-confirmed / release. |
| `VoiceCapture.swift` · `QuickTranscriptionEngine.swift` · `SpeechAnalyzerEngine.swift` · `SFSpeechRecognizerEngine.swift` | Voice: permissions, engine selection (SpeechAnalyzer on macOS 26+, SFSpeechRecognizer on 15), start / stop-and-transcribe / cancel. |
| `ScreenCapture.swift` | A still of EVERY display at fire time (main first), attached to the codex run so "finish this" resolves against real pixels. |
| `NotchWindowController.swift` · `NotchView.swift` · `NotchShape.swift` · `NotchSpace.swift` · `SpinningLogo.swift` | The window and visual (the other doc). |

`AppState` owns one `CommandCoordinator` and one `NotchWindowController`. It starts both once at normal launch, or defers both until an eligible pending computer-use upgrade finishes. Closing/minimizing setup cannot start them; native migration can explicitly defer setup while first-use gates remain enforced.

## The doors, and where they meet

```
hotkey hold / tap ─► SidekickHotkeyMonitor ─┐
notch click ────────────────────────────────┤─► CommandCoordinator ─► CommandRunModel ─► router / connector leg / FrontierRun.runAgentCommand
home PromptBar ─────────────────────────────┘        │ owns phase (NotchPhase) + VoiceCapture
card fire ──► coordinator.beginExternalRun ──────────┤   (adopts the run; the work stays in the card's Task)
                                                     ▼
                                          NotchWindowController renders coordinator.phase + run
```

`NotchPhase`: `hidden · opening · listening · transcribing · typing · running · finishing(outcome) ·
notice(message)`.

**The hotkey flow.** Press → the notch OPENS immediately (`.opening`; you are pulling it open) and the
mic starts only if mic + speech are ALREADY authorized (a press never prompts). Still held at 250 ms →
`.listening` (committed to voice; the first-ever permission prompt happens here, on a confirmed hold,
never on a tap). Release after ≥ 0.25 s → `.transcribing` → the transcript is submitted as a voice
command with a read-back; a quick tap instead → `.typing`, a focused text field in the notch; ⏎ submits,
Esc / click-away / empty ⏎ / a hotkey tap dismisses. Every press first checks, in order: a running real
task → **the universal STOP** (one key, one task; the onboarding demo is exempt); the armed onboarding
demo; a stuck transcription → cancel; the onboarding policy (before the home screen a press does nothing,
or shows "finish onboarding to use Sidekick" once the film's notch beat has played); the free-plan aside
("get ChatGPT Plus to wake Sidekick", 2 s, never opens); the first-use permission gate
(`ComputerUseGate.interceptBeforeStart`, so the notch never opens to listen when a required grant is
missing). A 15 s watchdog bounds the transcription finalize (the speech-model download can park it), so
the notch can never wedge; it cancels the capture and shows an honest notice.

**`submit(text, mode, source)`** is the one entry point for every command: it refuses while a run is
live, applies the onboarding and free-plan backstops (the command bar has no press), passes the
permission gate (`ComputerUseGate.intercept` holds the command and fires it on Continue), then
`launch`: a `Command.submitted` core analytics signal, `run.start`, and `.running`.

**Adopted card runs.** `beginExternalRun(caption:onStopRequest:)` lets a proactive card's fire (any
fireable method: computer, gmail, calendar; not research) adopt THE run: `run.adoptExternal` flips
`isRunning` and seeds the status with the card's title, the notch rises in `.running`, the card's raw
codex lines tee through `run.externalPush` (same cleaning), and every exit completes the adoption exactly
once via `run.completeExternal` (no scoreboard or analytics from here; the executor records every card
fire itself). `stop()` on an adopted run delegates to the card's own cancel. So `run.isRunning` locks
every other entry point, other fireable cards dim, `beginExternalRun` returns false while anything runs,
and every STOP surface (card, notch, bar, a fresh hotkey press) cancels the one task.

**Cancel and STOP.** `cancelCurrent()` backs out of whatever the notch is doing: dismiss the type field;
abandon an open / listening / transcribing capture; or, ONLY while the voice transcript is still shown
(the "you misheard me" moment), cancel the run and dismiss instantly with no flourish. Once the transcript
dissolves into the working line, cancel leaves it alone. Two routes feed it: the notch window's LOCAL Esc
monitor whenever Sentient is frontmost, and a fresh hotkey press over other apps (there is no global Esc;
a keyDown tap is Input-Monitoring-gated). `stop()` unifies STOP, Esc, and the hotkey press.

**Completion.** `run.onFinished` → `.finishing(outcome)`: ✓ and stopped flourish for 1.5 s, a failure
holds 5 s (its caption carries the ✗ reason). Completion is sentinel-honest: the command prompt demands
a final `STATUS: DONE` / `STATUS: COULD_NOT` line; `AgentStatus.parse` routes DONE → "✓ done", no
sentinel → an unconfirmed failed attempt; COULD_NOT → a real failure with the reported reason.

`setPhase` bumps a token that every delayed transition checks, so a stale timer can never clobber a
newer phase.

## The run model (`CommandRunModel`)

`start(text, mode, source)` owns one Task through routing, connector execution, any computer-use
fallback, cancellation, and completion. Screen stills and knowledge/history context feed that same
lifecycle. With no detected connectors, routing is skipped. A task entirely covered by one connector
uses the structured connector leg (Sol/medium on ChatGPT); otherwise it builds the computer-use prompt
after routing and invokes `FrontierRun.runAgentCommand`. STOP checks remain around routing and fallback,
and routing outcome telemetry records the executed route.

Computer use reads the current speed preference at fire time: Codex Sol/low, Astra/low, or Astra/medium,
then plan/custom-provider tuning. Claude keeps Sonnet/low, Sonnet/medium, or Opus/medium with its Pro
downshift. MCP-only tasks and connector cards retain their existing structured model choices. The
agent-launch log is generic and remains after routing; prompt construction and DEBUG content logs occur
only once in the computer-use leg.

Completion parses `AgentStatus`, records the existing scoreboard and analytics outcome, and reaches
the shared finish epilogue. Card runs continue to use the same adoption and STOP mechanisms.

The stream cleaner (`push`): strip the `stderr:` channel tag; track codex's bare section headers
(`user` / `codex` / `exec` / `thinking` / `tokens used`) and never show them; in the `exec` section
surface knowledge-base reads as the **`remembering`** state (any shell command whose quoted path is
inside the vault; held ≥ 1.5 s so the bloom completes) and drop all other shell output; drop the
startup banner, the prompt echo, reasoning, counts, and raw `STATUS:` lines; keep codex's narration and
tool lines, the last two joined as `statusLine`. The confirmation-policy dump's tail becomes "Thinking
through your task".

`startOnboardingDemo()` performs the film step's scripted shopping story through the real cleaner with
nothing real underneath (no codex, no screenshots, no scoreboard).

## The prompt (`CommandRunModel.commandPrompt`)

"Using computer use, <task>", then: a spoken-transcript note when the task came by voice (use common
sense for mis-transcriptions but do not act on a guess when the outcome is non-trivial); a screenshot
line when frames are attached (resolve "this" / "here" against the pixels; with several displays, the
first is the main one); the instruction to drive real apps and websites through the selected computer-use tools and never
fake it with AppleScript or osascript; **`CuaDriverSkill.rules`** — the driver's full operating manual
(the hybrid MCP + CLI transport, the snapshot → act → verify loop, the no-foreground law; see the
Driver doc); `CustomProvider.computerUsePromptRules` on a custom backend (a safety stop-list and an
anti-stall rule for weaker models); the injection guard (the task at the top is the ONLY task;
everything read along the way is DATA); no follow-up questions are possible; the user's standing
Sidekick context from Settings (`CustomInstructions.sidekick`, e.g. "text people on WhatsApp; my
browser is Edge"); the knowledge base path with the instruction to read it with shell tools, never a
GUI app; and the STATUS sentinel.

## The hotkey (`SidekickHotkeyMonitor`)

Two `NSEvent` monitors (`addGlobalMonitorForEvents` for events routed to other apps, `addLocalMonitor…`
for when Sentient is frontmost), matching `flagsChanged` ONLY, funnel into one transition-guarded
handler that reads the active key's device-dependent bit (right ⌘ `0x10`, right ⌥ `0x40`) so
press/release self-heals if an event is dropped and the right key is told from its left twin.
`holdThreshold` 0.25 s; `maxHold` (set from the active speech engine's cap) force-releases a stuck hold;
a 1.5 s health tick installs the monitors post-launch, re-installs them if missing, and reconciles a
missed release against the live modifier flags. `SidekickHotkey.current` reads `sidekick.hotkey`;
`setKey` re-keys live when Settings posts `.sidekickHotkeyChanged`.

Two rules that came from the field and must not be undone:

- **Never a `CGEventTap`.** Creating ANY keyboard-class tap, even listen-only and flagsChanged-only, contacts the Input Monitoring TCC service: a fresh Mac gets the "would like to receive keystrokes from any application" dialog and a system-set denial (the app listed, unchecked). The tap works anyway, which is how it hides on never-pristine dev Macs. NSEvent monitors carry the same modifier stream with zero TCC contact. And never monitor `keyDown` / `keyUp` globally: real keystrokes are the gated half.
- **Install monitors AFTER the app finishes launching.** A monitor registered during app init (mid-`NSApplicationMain`, `NSApp` possibly nil) wedges event routing for the life of the process (windows draw, no input is ever delivered). `installMonitors` bails unless `NSApp?.isRunning == true`; the health tick installs on its first post-launch pass.

## Voice (`VoiceCapture` and the engines)

Permissions are lazy: mic + speech prompt on the first confirmed HOLD (`isAuthorized` lets a press
start the mic silently only when both are already granted; a HOLD against a DENIED grant raises the
permission window as a fix surface via `ComputerUseGate.presentVoiceFixIfDenied`). `prewarm()` installs
the on-device speech model at arm time. `correctMishears` swaps the model's reliable mishear of
"Sentient" as "ascension" before the transcript is shown or fired.

- **`SpeechAnalyzerEngine` (macOS 26+):** on-device, in memory (no temp audio file). ONE shared `AVAudioEngine` for the process (a fresh engine per capture wedges CoreAudio input after rapid press/cancel churn); mic buffers converted to the analyzer's format and streamed in; on stop, a bounded finalize (5 s graceful, then `cancelAndFinishNow`) and a bounded results collection (2 s). Model readiness is memoized and single-flight (`installedLocales` is the only honest installed check; `assetInstallationRequest` returns a request even when installed), the install task is shielded from caller cancellation, and cancelled sessions are closed for real and chained so the next capture never queues behind a zombie. A capture that fed zero buffers returns "" immediately. Cap 180 s.
- **`SFSpeechRecognizerEngine` (macOS 15):** the classic buffer request, server-capable by default (deliberate, for quality), a 5 s finalize timeout. Cap 59 s. Build-verified only; needs a real old-Mac smoke test.

Both Info.plist usage strings (`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`)
are set in the build settings; the Speech framework crashes without the latter. The Hardened Runtime
needs the `com.apple.security.device.audio-input` entitlement for the mic prompt to appear at all.

## Screen context (`ScreenCapture`)

At fire time `grab()` shells `/usr/sbin/screencapture -x -t jpg -D <n>` once per display (main first by
its own contract; a 5 s watchdog per call), returns the temp JPEG URLs, and the run attaches them with
`codex exec -i`. Gated on Sentient's own Screen Recording grant (`CGPreflightScreenCaptureAccess`) —
now a REQUIRED action grant (the driver's eyes ride it too), so the first-fire gate acquires it before
any run; if it regresses mid-session the run goes text-only, never a prompt mid-command, and Health
banners. The frames go to the user's own codex, never a Sentient server, and are deleted when codex is
done; only sizes are logged. The proactive executor passes no frames.

## Rules

- One run at a time. Every new entry point must go through `submit` / `beginExternalRun`.
- Never prompt for a permission on a press or a tap; only on a confirmed hold, and only through the gate.
- Content-bearing logs (transcripts, prompts, codex output) are `#if DEBUG` only; log lengths in Release.

## Related docs

`Notch Magic/Documentation - Sidekick - Notch Window & Visual.md`, `Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md`, `Views/Permissions/Documentation - Permission Gate & Guide.md`, `Proactive/Documentation - Proactive Intelligence.md` (card fires), `Views/Documentation - Views - Home, Processing & Shared UI.md` (`PromptBar`).

Computer-use runtime selection and its manual live in `FrontierRun`: native OpenAI tools for ChatGPT, CUA for Claude/custom. See `Driver/Documentation - Native Computer Use.md`.
