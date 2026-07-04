# 🪄 Notch Magic — Implementation

Documentation for **Notch Magic** — Sentient OS's global hold-to-talk / tap-to-type hotkey and the living notch overlay that shows the AI working. It covers what the feature is, every file, and the hard-won lessons (please don't re-break them). The whole feature — the interaction, the window, the glow, the animations, the Esc/⌘ dismiss — is **built and confirmed working on Jesai's bezel**; §12 is an optional polish backlog, §13 is what's left before launch.

> **How to verify a change:** build through the **Xcode MCP `BuildProject`** (same signing as the Run button) and sweep `GetBuildLog` for warnings. **`RenderPreview` does NOT work on this target** — it has to launch the whole app and times out (see §9). So for anything *visual/animated*, build clean, then **ask Jesai to run it and screenshot/screen-record** — the notch lives on his physical bezel and is all motion; that's the only real test.

> **Design language** (so the notch stays *us*): OLED black as a material · the AI spectrum is `GlowHalo.stops` in `Views/GlowButton.swift` (warm→cool: `#fde2a3 #ff8e3c #ff4646 #e8388f #9b48d4 #6c5ce5 #4a90e2` + wrap — the *same* stops the website logo spins) · serif italic for soul, monospace for the machine whisper · motion is physics, not UI. The logo target is the **app icon** (a thick vibrant color ring + white planet dot); on the notch it deepens that pale first stop to a saturated gold so the tight ring reads as a full rainbow (§8).

---

## 1. What Notch Magic is

**A global way to tell Sentient to *do something*, and a universal status surface for when it's working.** Three front doors, one backend, one notch:

1. **Press-and-hold the right ⌘ key anywhere** → the notch *drops open the instant you press* (you're pulling it open); *speak* a task → release → it transcribes (on-device) and fires it as a **computer-use** command.
2. **Tap the right ⌘ key** (a quick press-release, no hold) → the open notch becomes a focused **text field** → type a task, hit ⏎ → same computer-use backend.
3. **Type in the home command bar** (`PromptBar`) → same backend, same notch.

All funnel through **`CommandCoordinator` → `CommandRunModel` → `CodexCLI.runAgentCommand`**, and the notch is a live view of `coordinator.phase` (+ `coordinator.run`). The notch is the Mac's "face" coming alive — it descends from the bezel **glowing**, shows what it heard (or lets you type), then streams the work — *Thinking through your task*, **Remembering** the notes it reads from your knowledge base, the actions — with a STOP button, and retracts.

Every command is **computer use** (the dedicated browser-use channel was removed — see the root architecture doc §7), and the notch shows for all of them.

**The instant you fire a command, Sentient also snaps a still of your screen and hands it to the agent** (`codex exec -i`), so "finish this", "reply to this", "complete this form" resolve against the actual pixels you're looking at — computer use starts with eyes open, not blind. It rides Sentient's own Screen Recording grant; no grant → the command just runs text-only. See §6a. [✅ verified on hardware — §11.]

---

## 2. Architecture in one breath

```
 right-⌘ hold ──► RightCommandMonitor ─┐
                                        ├─► CommandCoordinator ──► CommandRunModel ──► CodexCLI (computer use)
 home PromptBar ──► coordinator.submit ─┘        │  owns phase (NotchPhase)
                                                 │  owns VoiceCapture (mic → on-device transcript)
                                                 ▼
                                  coordinator.phase  ◄── observed by ──  NotchWindowController (NSPanel host)
                                                 ▲                                 │ renders
                                                 └───────────────  NotchView / NotchContent (the living notch)
```

`AppState` (`AppState.swift`) owns one `CommandCoordinator` and one `NotchWindowController`, created + started in `AppState.init()`. The coordinator arms the hotkey and prewarms the speech model; the window controller raises the overlay.

---

## 3. The files (all in `Notch Magic/`)

| File | Job |
|---|---|
| **`RightCommandMonitor.swift`** | Zero-permission global key tap (`flagsChanged` + `keyDown`): the right-⌘ trigger AND global Esc. Emits `onPress` / `onHoldConfirmed` / `onRelease(held:)` / `onEscape`. Self-healing. |
| **`QuickTranscriptionEngine.swift`** | The protocol both speech engines conform to + `VoiceError`. |
| **`SpeechAnalyzerEngine.swift`** | macOS **26+** speech-to-text (`SpeechAnalyzer` + `SpeechTranscriber`, on-device, in-memory). |
| **`SFSpeechRecognizerEngine.swift`** | macOS **15** fallback (`SFSpeechRecognizer`, server-capable). |
| **`VoiceCapture.swift`** | Façade: mic + speech permissions, engine selection, `prewarm` / `start` / `stopAndTranscribe` / `cancel`. |
| **`CommandRunModel.swift`** | Runs ONE codex task; **cleans codex's raw human-readable stream** into the bar's `statusLine` + the `remembering` state (§6); `stop()`, `onFinished(Outcome)`. Grabs + attaches the screen still at run start (§6a). |
| **`ScreenCapture.swift`** | Grabs the screen to a temp JPEG for computer-use context (`/usr/sbin/screencapture`, main display). `grab() -> URL?` (nil if no Screen Recording grant) · `discard(_:)`. §6a. |
| **`CommandCoordinator.swift`** | The brain: owns the run + hotkey + voice, drives `phase` (`NotchPhase`), the press→branch flow, `submit()` / `submitTyped()` / `dismissTyping()` / `cancelCurrent()` / `stop()`. |
| **`NotchSpace.swift`** | SkyLight private-API wrapper — pins the panel into a top-level window-server space so it's fixed over the notch on every Space. |
| **`NotchWindowController.swift`** | The `NSPanel` host: a **fixed canvas** flush at the bezel; click-through by toggling `ignoresMouseEvents` per cursor position; all-Spaces; observers. Also `NotchPanel`, `NotchHostingView`, the `NSScreen.notchSize`/`displayID` extension. |
| **`NotchShape.swift`** | The silhouette `Shape` (animatable corner radii) **+ `NotchSkirtShape`** — its open twin (sides + rounded bottom + concave top corners, no flat top edge) that the glow strokes. |
| **`SpinningLogo.swift`** | The 2D spectrum-ring logo (matches the app icon). |
| **`NotchView.swift`** | `NotchView` (binder) + `NotchContent` (the pure visual: morph, phases, layered edge glow, the read-back / Remembering / status captions) + `NotchMetrics` (per-phase sizing) + `NotchStopButton` + the `.blurDissolve` transition. |

Edits outside this folder: `AppState.swift` (owns/starts the two objects), `Views/HomeView.swift` (`PromptBar` drives `appState.commandCoordinator`), `Cloud/CodexCLI.swift` (`runAgentCommand` gained an optional `imagePath` → `codex exec -i`, §6a), `System/Permissions.swift` (`hasScreenRecording()`, already present), and the project's `INFOPLIST_KEY_NSMicrophoneUsageDescription` + `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` build settings.

There is still a **DEV bench** `Views/Dev/HotkeyLabView.swift` (DEV TOOLS → HOTKEY LAB) — the original proof of the hotkey tap. It's superseded by `RightCommandMonitor`; **retire it** once you're confident (see §13).

---

## 4. The hotkey + global Esc — `RightCommandMonitor`

ONE listen-only `CGEventTap` (zero permissions) drives two things: the right-⌘ trigger and a global Esc to cancel/dismiss the notch.

**Right ⌘ needs ZERO permissions** because it's a *modifier* — it rides `flagsChanged`, which macOS doesn't gate. A listen-only tap masking `flagsChanged` sees it globally with no prompt, no Settings entry, no Accessibility — even in the notarized, Finder-launched app.

**Esc is a regular key (`keyDown`) — and the long-held "keyDown is gated" assumption turned out to be WRONG.** [MEASURED, macOS Tahoe, Input Monitoring OFF, app unfocused] a **listen-only** tap masking `keyDown` receives keystrokes globally with no permission, no prompt, no Settings entry. So we add `keyDown` to the same tap and watch for Esc (keycode 53). ⚠️ This was measured only on Tahoe (26); the deploy floor is macOS 15 — **re-verify on a 15 machine before launch** (§13). If it's gated there, fall back to a right-⌘-tap cancel (a modifier is always free).

- **Esc is filtered in the C callback:** the mask now catches *every* keystroke, so the trampoline checks `keyboardEventKeycode == escKeyCode (53)` synchronously and only hops to the main actor for Esc — never per keystroke. The tap stays **listen-only**, so keys always pass through untouched (an Esc reaches whatever app you're in too — harmless, and the price of staying permission-free; see §6).
- **Ground-truth right-⌘ state:** on every `flagsChanged`, read the **device-dependent right-⌘ bit** (`NX_DEVICERCMDKEYMASK = 0x10`) from `event.flags`. So press/release self-heals even if an event is dropped (we never toggle a fragile keycode set).
- **Hold vs tap:** `holdThreshold = 0.25s`. `onHoldConfirmed` fires at 250ms if still held; `onRelease(held:)` reports the duration. The coordinator turns a held release into voice, a quick release into the type field (§6).
- **Callbacks:** `onPress` · `onHoldConfirmed` · `onRelease(held:)` · **`onEscape`** (Esc pressed → the coordinator's `cancelCurrent()`, §6).
- **Reliability:** re-enable on `.tapDisabledBy…`; re-arm on `NSWorkspace.didWake`; a 1.5s health timer rebuilds a dead tap and reconciles a missed release against `CGEventSource.flagsState(.combinedSessionState)`; a `maxHold` safety force-releases a stuck hold (set by the coordinator to the engine's transcription cap — see §5).
- The C trampoline must be `nonisolated` (project builds with `-default-isolation=MainActor`; an actor-isolated func can't be a `@convention(c)` pointer) and hops to `@MainActor` to call `handle(type:flags:)` / `handleEscape()`. `escKeyCode` is `nonisolated static` so the off-main callback can read it.

Keycodes for reference: right ⌘ = 54, left ⌘ = 55 (we use the *flag bit*, not the keycode), Esc = 53.

---

## 5. Voice + transcription

`VoiceCapture` is the façade the coordinator talks to. It:
- **Permissions — LAZY-GRANTED, by policy:** Sidekick's grants (microphone + speech, and Sentient's own Screen Recording for the §6a still) are never requested at launch or in onboarding — the ask happens the first time the user actually invokes Sidekick (after initial processing, once the onboarding gating in §13 lands). Today: microphone (`AVCaptureDevice`) + speech (`SFSpeechRecognizer`) prompt on the first confirmed HOLD — a static **`isAuthorized`** lets a *press* start the mic only when both are ALREADY granted, so a tap-to-type never throws a mic dialog (§6); the screen-recording ask is currently Settings-only (Permissions & Health → "Allow…" — `grab()` itself never prompts, §6a). Both Info.plist usage strings are set in the build settings. ⚠️ The Speech framework **crashes** without `NSSpeechRecognitionUsageDescription`, so that key is mandatory. *(Open question: on-device `SpeechAnalyzer` may not need the speech grant — if mic-only works, drop `requestSpeech()`. See §13.)*
- **Picks the engine:** `SpeechAnalyzerEngine` on macOS 26+, else `SFSpeechRecognizerEngine`. `isAvailable` is always true (we support 15+).
- **`prewarm()`** at arm-time installs the on-device model so the first hold is instant.
- **`correctMishears(_)`** fixes the speech model's known brand mishears the moment transcription finishes (before the transcript is shown or fired) — it reliably hears "Sentient" as "ascension", so that whole word is swapped back (case-preserving, whole-word).

**`SpeechAnalyzerEngine` (macOS 26):** fully on-device → private *and* high quality, audio stays in memory (no temp file). Flow: resolve a supported locale → `AssetInventory` install if needed → `SpeechAnalyzer.bestAvailableAudioFormat` → create analyzer + `AsyncStream<AnalyzerInput>` → tap the mic (`AVAudioEngine`), convert each buffer to the analyzer format with `AVAudioConverter`, yield → on stop, `finalizeAndFinishThroughEndOfInput()` and collect `transcriber.results`. **`@preconcurrency import AVFAudio`** is load-bearing (the audio-thread tap captures non-Sendable `AVAudioPCMBuffer`/`AVAudioConverter`); the tap closure captures only locals + a `nonisolated static convert(...)`, never `self`, so there's no MainActor violation.

**`SFSpeechRecognizerEngine` (macOS 15):** classic `SFSpeechAudioBufferRecognitionRequest`; server-capable by default (NOT forced on-device — deliberate, for quality, per Jesai). Bridges the callback API to async with a continuation + a 5s safety timeout. **Build-verified only — never runtime-tested** (needs an old Mac).

**Caps:** `SpeechAnalyzerEngine.maxUtteranceDuration = 180s` (3 min); `SFSpeechRecognizerEngine.maxUtteranceDuration = 59s` (its hard ~1-min audio limit). `VoiceCapture.maxCaptureDuration` returns the active one; the coordinator sets `hotkey.maxHold` to it so a hold is force-finalized before the engine can't take more.

---

## 6. The coordinator — `CommandCoordinator` (+ the run model's stream cleanup)

`@MainActor @Observable`. Source of truth for `phase: NotchPhase` and `readBack: String?`. (The live status + the "Remembering" state live on `run`, below.)

```
enum NotchPhase { hidden · opening · listening · transcribing · typing · running · finishing(Outcome) · notice(String) }
```

**The one entry point** (all triggers call it):
```swift
func submit(_ text:, mode: AgentMode, source: TriggerSource)   // .promptBar | .voice
```
It guards one-run-at-a-time, sets `readBack` for voice (timed in §8), calls `run.start`, and `setPhase(.running)` — every command is computer use, which raises the notch.

**The hotkey flow — press OPENS, then it branches to voice or type:**
- `voicePressBegan()` (onPress, from idle only — `isInteracting` blocks a fresh press mid-interaction): `setPhase(.opening)` *immediately* (the "pull it open" feel). Start the mic **only if `VoiceCapture.isAuthorized`** — never PROMPT on a press.
- `voiceHoldConfirmed()` (@250ms): `setPhase(.listening)` — committed to voice (the "lean in"); start the mic now if perms weren't pre-granted (the only first-use prompt path).
- `voiceReleased(held:)` from `.opening`/`.listening`: `held ≥ 0.25` → `finalizeVoice()` (→ `.transcribing` → `stopAndTranscribe()` → empty? `flash` : `submit(.voice)`); else `beginTyping()` (cancel the mic → `setPhase(.typing)`).
- **Tap-to-type:** `submitTyped(_)` (⏎ in the notch field) → `submit(.computer, .promptBar)`; `dismissTyping()` (click-away · empty-⏎) → `.hidden`. A **right-⌘ tap while the field is open** also dismisses it (`voicePressBegan` toggles it closed instead of opening a fresh interaction).

**Esc — `cancelCurrent()` backs out of whatever the notch is doing**, mirroring the obvious one-tap action per state (it returns whether it consumed the Esc):
- **typing** → `dismissTyping()`.
- **opening / listening** → drop the voice capture, `.hidden` (a later key release then fires nothing).
- **running, ONLY while the voice transcript is still on screen** (`readBack != nil && remembering == nil`) → cancel the run and **dismiss INSTANTLY** (the "you misheard me, redo" case — no "Stopped" flourish). Once the transcript dissolves into the working / "Remembering" line, Esc is left ALONE so it stays free for the user's own apps.

Two routes feed it: the **global** Esc tap (`RightCommandMonitor.onEscape`, §4) handles every state where we're *not* the key window (a voice capture / a transcript over another app); a **local** key monitor in the window (§7) owns the *typing* field, where it can consume Esc before the text field so dismissing never beeps. The global route skips `.typing` so the two never race.

**STOP is transcript-aware too — `stop()` unifies both.** A STOP click (or Esc) *while the transcript shows* dismisses instantly: it sets `.hidden` first, so `runFinished` sees a non-running phase and skips the flourish — while the run is still cancelled underneath. Once computer use is working, STOP halts it with the honest "Stopped" beat. The STOP button (`onStop`) and Esc both route through `stop()`, so they behave identically.

**Run completion** (`run.onFinished`): if `phase == .running` → `.finishing(outcome)` → `scheduleHide(1.5)` (the ✓/stopped/✗ flourish; a non-running phase skips straight to `.hidden`). Notices (`flash`, e.g. "didn't catch that") hold **1.5s** too.

**Plumbing:** `setPhase` bumps `phaseToken`; `scheduleHide`/`flash`/`setReadBack` capture the token and only fire if unchanged — a delayed transition can never clobber a newer one.

**`CommandRunModel` cleans codex's raw stream into the bar.** `codex exec` (computer use, human-readable, gpt-5.5 + `model_reasoning_effort=low`) emits a noisy play-by-play; `push(line)` distills it:
- **strip** the `stderr:` channel tag (before trimming, so empty `stderr:` lines don't flash);
- **track sections** by codex's bare headers (`user`/`codex`/`exec`/…) — show only codex's narration + tool/`mcp:` lines; drop the startup banner, the user-prompt echo, and raw shell output (`barLine`);
- in the **`exec`** section, surface knowledge-base reads as the **`remembering`** state — `knowledgeBaseRead` slices the note path out of a `cat`/`grep`/`sed`/… command (command-agnostic: keys off the vault path, requires it shell-quoted so grep *output* isn't mistaken for a read). `setRemembering` holds it ≥1.5s (so the bloom completes for a single file);
- replace the confirmation-policy `SKILL.md` dump's lingering tail ("…avoid redundant confirmations…") with **"Thinking through your task"**.

### 6a. Screen context — the screenshot (`ScreenCapture.swift`)

So the agent can act on what you're *actually looking at*, every command attaches a still of your screen. It's captured **inside `CommandRunModel.start`** (at the top of its run Task, so `isRunning` is already true — no re-entrancy gap): `await ScreenCapture.grab()` shells `/usr/sbin/screencapture -x -t jpg <temp>` (main display, silent, JPEG to stay compact vs a multi-MB Retina PNG), returns the temp `URL`, and a `defer { ScreenCapture.discard(shot) }` deletes it the moment codex is done.

- **Permission-gated, never prompts:** `grab()` returns `nil` unless `Permissions.hasScreenRecording()` is already true — no grant → the command runs text-only exactly as before. (`CGPreflightScreenCaptureAccess`, so it never surfaces a dialog mid-command.)
- **Into the prompt:** `CodexCLI.runAgentCommand(prompt, imagePath:)` adds `-i <path>` to the `codex exec` args, placed **right before `--skip-git-repo-check`** so that flag terminates `-i`'s variadic `<FILE>...` and the prompt is never mistaken for a second image. `commandPrompt(…, hasScreenshot:)` adds a line telling the agent to resolve "this"/"here" against the attached frame.
- **The proactive executor passes nothing** (`imagePath` defaults to nil) — a background proactive action has no "current screen" to show; this is a Sidekick-only capture.
- **Privacy note:** the frame goes to the user's OWN codex/OpenAI — the same trust boundary computer use already crosses (it reads the live screen anyway). It never touches Sentient servers, and only the file *size* is logged, never the pixels.
- **Known rough edges (§13):** no downscale yet (~0.5–1.5 MB per frame) · our own notch overlay is *in* the shot (recordable window) · main-display only (multi-monitor grabs the wrong screen sometimes) · the **home command-bar path is weak** — Sentient is frontmost there, so the frame is often our own UI; the two *notch* doors (non-activating panel) are where the shot is genuinely useful.

---

## 7. The notch window — `NotchWindowController` + `NotchSpace`

This is where most of the hard bugs were fought and won. The window is a **FIXED canvas** (DynamicNotch's actual approach) — it does NOT resize per state; the notch shape morphs *inside* it. Invariants, do not regress:

**(a) Fixed canvas, top-flush, NEVER resized during a morph.** The panel is sized once to `canvasSize` — the biggest notch state + slack (`canvasHSlack 140`, `canvasVSlack 90`) for the bounce-overshoot and glow bloom — pinned with its top at the screen's edge. `applyPhase` just `placeCanvas()` + `reveal()`; on `.hidden` it `orderOut`s after `settleDelay` (idle = no window at all). Because the window never moves/resizes mid-animation, the notch **can't detach from the bezel**.
> ⚠️ The OLD approach — resize the window to the notch on every phase change (grow-to-union, shrink-after-settle) — made the notch visibly **jump off the bezel** mid-morph (the AppKit frame and the SwiftUI animation fought, worse with a bouncy spring). Don't go back to per-state window resizing.

**(b) Click-through = `ignoresMouseEvents` toggled by CURSOR POSITION.** macOS does per-pixel hit-testing: a click on ANY non-transparent pixel (incl. the glow bloom) is caught by the window *before* `hitTest` runs, and a nil `hitTest` then **swallows** it rather than passing through. So a static hitTest can't make the glow click-through. Instead a ~60 Hz cursor poll (`mouseTimer`, added in `.common` run-loop mode) sets `ignoresMouseEvents = false` **only while the cursor is over the actual notch silhouette** (`cursorOverSilhouette` — a `NotchShape` path test in screen coords); everywhere else the whole window ignores the mouse, so clicks (over the glow, the empty canvas, an inch away) sail straight through. `hitTest` then just returns `super ?? self`; `acceptsFirstMouse` so STOP/the field fire on the first click.
> ⚠️ Don't gate click-through on a static `hitTest`/rect — the glow's drawn pixels are caught before hitTest, and a rect over-claims the area beside the rounded notch. Gate on **where the cursor is**, against the **shape path**.

**(c) Present on ALL Spaces + no slide.** Both still needed: `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`, **re-asserted on EVERY `reveal()`** (macOS drops `.canJoinAllSpaces` on re-order); and `NotchSpace.shared?.pin(panel)` (the SkyLight private API, level `Int32.max`) so it doesn't slide during the 3-finger Spaces swipe (`.stationary` is Exposé-only; best-effort, falls back to the public behaviour).

**(d) Typing needs a key window.** Entering `.typing`, `reveal(makeKey: true)` → `makeKeyAndOrderFront`: the `.nonactivatingPanel` becomes key (takes keystrokes) WITHOUT bringing the app forward over what you're using. A `didResignKey` observer (guarded against the focus-setup race via `typingKeyAt`) dismisses the field on click-away. `NotchPanel.constrainFrameRect` is overridden so the window can sit flush at the very top (over the menu bar).

**(e) Esc for the type field (local key monitor).** `installKeyMonitor()` adds an `NSEvent.addLocalMonitorForEvents(.keyDown)` that, on Esc, calls `coordinator.cancelCurrent()` and swallows the event when handled. A LOCAL monitor needs no permission (it only sees events already routed to our key panel) and fires *before* the text field, so dismissing the type field never beeps. The other states' Esc is handled globally (§4); this exists only for the consume-before-the-field case. `settleDelay = 0.6s` — long enough for the dismiss *retract* (§8) to finish merging into the cutout before the window orders out.

Other notes: `level = .mainMenu + 3`; `sharingType` **left at default** (the notch shows in screen recordings — Jesai chose recordability). Observers (`didChangeScreenParameters`, `activeSpaceDidChange`, `didWake`, `didActivateApplication`) re-place the canvas on the menu-bar display (`CGMainDisplayID`, not `NSScreen.main`) and re-`reveal()`; `host.update(metrics:)` re-renders on display change.

---

## 8. The notch visual — `NotchView` / `NotchContent` / `NotchShape` / `SpinningLogo`

`NotchView` is a thin binder reading `coordinator`; `NotchContent` is the pure, previewable visual (`phase, readBack, statusLine, remembering, metrics, onStop, onSubmitText`). Esc-to-dismiss isn't a `NotchContent` callback — it's caught globally (§4) + by the window's local key monitor (§7).

**The shape sits FLUSH at the bezel.** `NotchShape`'s concave top corners (the genuine-notch flare into the screen edge) are now VISIBLE — the window's top is at the screen edge and the shape's top edge lands on it (the old `topBleed` that shoved the top off-screen is gone). `NotchSkirtShape` is its open twin: the visible perimeter (concave top corners → sides → rounded bottom) but NOT the flat top edge — the glow strokes this, so it warps up into the corners yet never lights the bezel line.

**`NotchMetrics`** computes per-phase `size`/`radii`, kept TIGHT so the notch eats minimally into apps (it runs over the user's browser tabs while computer use works):
- `baseWidth = max(notch.width, 200)`, `baseHeight = max(notch.height, 32)` (`auxiliaryTopLeftArea.height`).
- **opening/listening/transcribing:** `width = baseWidth + 76`, `height = baseHeight + notchBottomCover` — a small **`+2`** cover, because `auxiliaryTopLeftArea.height` reports a hair shallower than the notch's real cutout, so the mic state (the only one sized to ~`baseHeight`; every other state is taller and overshoots) would otherwise let the hardware lip peek below. Radii = the real notch radius (`top: baseHeight/3 - 4`, `bottom: baseHeight/3`).
- **running/finishing:** `runningHeight(caption:) = baseHeight + caption + bottomPad` — `caption` is the read-back's measured height (grows to fit, below) or the tight one-line status (`captionHeight 18`). `topPad 0` + zero VStack spacing so the text sits right under the hardware notch; `bottomPad 4`.
- **typing:** wider + one focusable field row.
- **hidden (the dismiss RETRACT):** size collapses to the **exact hardware notch** (`hardwareNotch`, with the real notch radius), and the black shell stays **opaque** (`shellOpacity = 1`) while only the *content* fades. So on dismiss the shell morphs back into the real cutout and **merges with it** — a physical "suck back into the notch," then the window orders out invisibly (`settleDelay 0.6s`). No fade. (On a notch-less display there's nothing to merge into, so `shellOpacity` fades it instead.)

**Layout (camera-flanking):** a top row (`SpinningLogo` · `Spacer(centerGap 64)` · `rightControl`) at the camera band, then the caption / type-field row. `hPad 18` clearance. The logo AND every `rightControl` fill the **same `controlSlot` (17pt) square**, so the two flanks are twinned in size and on one optical center axis — no per-state drift. `rightControl` cross-fades between **the mic at 14pt** (opening calmer → listening "leans in") · spinner (transcribing) · the `TextField` (typing) · `NotchStopButton` (running) · outcome glyph (finishing).

**The running caption is 3-way** (`runningCaptionKey` = remembering ▸ read-back ▸ status), swapped with a **fancy blur-dissolve-pop** (`.blurDissolve` = blur + fade + a spring scale, on `.spring(duration: 0.7, bounce: 0.35)`):
- **Read-back** — the heard instruction, serif italic, in **curly quotes**; the notch **grows DOWN to fit the whole thing** (measured via `NSString.boundingRect` on the same quoted string, capped at `maxReadBackLines 10`) and lingers **4–9s scaled by line count** (`NotchMetrics.readBackDuration`), then dissolves to the work line.
- **Remembering** — codex reading the knowledge base: the word **"Remembering"** in the analysis-screen "Everything." gradient (`rememberingGradient`), gently breathing via opacity, with the note path morphing beside it per file (`.contentTransition(.interpolate)`).
- **Status** — codex's work lines, mono, `.contentTransition(.interpolate)` so only the CHANGED glyphs morph in place (shared prefixes stay put — e.g. one tool line → the next).

**The morph:** one spring `.spring(response: 0.52, dampingFraction: 0.72)` drives size/radii/content/glow together on `phase`, `readBack`, and `remembering` (reduced-motion → 0.24s ease) — fast-out, gentle settle, slight bounce.

**The edge glow** (`glow` ×3 → `glowLayer`): a rotating `AngularGradient(GlowHalo.stops)` **masked by `NotchSkirtShape.stroke`** — the mask lives in the body so it morphs in LOCKSTEP with the black fill (no "separate entity" pop-in). Three layers (wide soft halo + dense halo behind the fill, crisp bright rim over it) make it thick + vivid. It's **always present**, fading via `.opacity(glowStrength)` so the edges light up in place; `glowStrength` is non-zero for **every visible state** (opening/listening/typing/running…), so the notch glows from the moment it's summoned. ⚠️ Each layer expands its gradient `(lineWidth/2 + blur + 6)` past every edge (`.padding(-m)` + `.mask(skirt.padding(m))`) so the BOTTOM edge isn't thinner than the sides (the gradient must reach beyond the stroke + blur on ALL sides, and the bottom edge sits at the frame edge).

**`SpinningLogo`** (matches the app icon — a thick vibrant color ring + white planet):
- Layers: a soft **single** additive bloom · the **thick, SHARP, saturated color band** (`stroke` at `lineWidth size*0.17`, almost no blur — *this* is the visible color) · a thin white ring (`max(0.75, size*0.028)`, "just for shape", kept extra-fine — the floor governs at notch size) · the white planet (`size*0.36`) with a tiny additive glow.
- **Palette = `bandStops`, NOT raw `GlowHalo.stops`:** the brand spectrum with one change — the pale warm-yellow seam stop (`#fde2a3`) deepened to a saturated **gold `(0.97, 0.70, 0.24)`**. That stop is a very light cream *and* spans the wrap seam (it's both the first stop and the duplicated last), so at this tight ring scale it otherwise reads as a near-WHITE arc that breaks the rainbow. Deepening just that one stop — locally; the shared `GlowHalo.stops` (edge glow, CTAs, website spinner) is untouched — keeps the wheel fully colorful and truer to the app icon.
- ⚠️ **One additive pass only for the color.** Stacking multiple `.plusLighter` passes blew the pale stop past white → a "white thick part" swept around as it spun. One pass on black = the true color.
- The spin is **wall-clock** via `TimelineView` (no per-frame `@State`); speed is `period(fast)` — **13s idle, 2s when `fast == .running`** (the fast "processing" spin); an **anchor** (`anchorAngle`/`anchorTime`, re-based in `onChange(of: fast)`) keeps the colors from jumping when the speed changes.
- ⚠️ **`.transaction { $0.animation = nil }`** on the logo is load-bearing: without it the notch's morph spring interpolates the gradient angle on a speed change and **reverse-spins the logo** for the morph's duration.

---

## 9. ⚠️ Hard-won lessons (please don't re-break these)

1. **Click-through = `ignoresMouseEvents` toggled by cursor position, on a FIXED canvas.** macOS catches clicks on any non-transparent pixel (the glow) before `hitTest`, and a nil `hitTest` swallows (doesn't pass through). Poll the cursor; only stop ignoring the mouse over the notch *silhouette*. (REPLACES the old "notch-sized window + hitTest" lesson — it couldn't make the glow click-through.)
2. **The window NEVER resizes during a morph.** Animate the shape inside a fixed canvas — per-state window resizing makes the notch jump off the bezel mid-animation.
3. **Re-assert `collectionBehavior` on every reveal** — macOS drops `.canJoinAllSpaces` on re-order. **No-slide needs SkyLight** (`NotchSpace`); `.stationary` is Exposé-only.
4. **The notch sits FLUSH at the bezel; the glow uses `NotchSkirtShape`** (concave top corners + sides + rounded bottom, NO flat top edge) so the bezel line never lights up. The old `topBleed` off-screen trick is gone.
5. **The glow must morph in LOCKSTEP via a `.mask`** — stroke the skirt as a mask on the gradient (the shape lives in the body), never a shape built inside the per-frame `TimelineView` (it jumps to the final geometry → a "separate entity" pop-in during morphs).
6. **The glow gradient must extend past the stroke + blur on EVERY edge** — else the bottom (at the frame edge) renders thinner than the sides. Expand each layer (`.padding(-m)`) and inset the mask (`.padding(m)`).
7. **`SpinningLogo`: single additive color pass** (stacking → white blowout) + **`.transaction { animation = nil }`** (else reverse-spin on speed change).
8. **Per-frame discipline:** `TimelineView` wall-clock, **no `@State` writes per frame**. The notch is small so the glow/logo blurs are OK.
9. **`RenderPreview` is broken on this target** (it launches the whole app → 30s timeout). Build to verify; test motion live.
10. **Build hygiene** (`3_Dev_Notes_and_Rules.md`): isolate CLI builds (`-derivedDataPath /tmp/...`) or prefer the Xcode MCP `BuildProject`. Synchronized file groups auto-join a `.swift` dropped into `Notch Magic/`.
11. **Default-MainActor isolation** is on. Off-main code (the audio tap, the CGEvent trampoline) must be `nonisolated` and capture locals, not `self`. A `static let` the off-main callback reads (e.g. `escKeyCode`) must be `nonisolated static`.
12. **The dismiss is a RETRACT, not a fade.** On `.hidden`, the black shell stays opaque and morphs to the *exact hardware-notch silhouette* (size + radius), so it merges into the real cutout and the window orders out invisibly — a physical "suck back in." Only the inner content fades. (Notch-less displays fade — there's nothing to merge into.) An earlier flat opacity fade read as cheap; don't go back.
13. **Listen-only `keyDown` is NOT gated** [MEASURED, macOS Tahoe, Input Monitoring off, app unfocused] — the long-assumed "keyDown needs Input Monitoring" was wrong, so we catch Esc on the same zero-permission tap (filtered in the C callback so we never flood the main actor). This **overturns the old "never mask keyDown" rule.** ⚠️ Verify on the macOS-15 floor before launch (§13); if gated there, fall back to a right-⌘-tap cancel.

---

## 10. Reference: DynamicNotch techniques

The original inspiration was the open-source **DynamicNotch** app, checked out (gitignored, inspiration-only) at the workspace root: `DynamicNotch-main/`. It's ~250 files of feature sprawl; the notch mechanics that matter, and where we used / diverged from them:

- **`Shared/Extensions/extension+NSScreen.swift`** — `notchSize` via `auxiliaryTopLeftArea/RightArea`; menu-bar screen via `CGMainDisplayID`. (We use these.)
- **`Application/OverlayPanelWindow.swift`** + **`AppDelegate/AppDelegate+Window.swift`** — the panel recipe; they re-apply `collectionBehavior` on updates, and use a **FIXED canvas** (`appCanvasSize = 1000×1000`) that never resizes per state with `hitTest` → `super.hitTest` (their content is notch-sized + `.contentShape(NotchShape)`). We match the fixed-canvas idea but make click-through bulletproof with the cursor-position `ignoresMouseEvents` toggle (their `super.hitTest` ate clicks for us — see §7b).
- **`Features/Notch/Components/NotchShape.swift`** + **`NotchModel.swift`** — the silhouette + `cornerRadius = (top: baseHeight/3 - 4, bottom: baseHeight/3)`. (We use this radius for the mic state.)
- **`Shared/PrivateAPI/SkyLightOperator.swift`** — the SkyLight space delegation. We distilled the one piece we need into `NotchSpace.swift`. (We do NOT use their materials/liquid-glass/lock-screen paths — pure OLED black is the brand.)

---

## 11. Current state — what's done & verified

All of the below is **confirmed working on Jesai's bezel** (live screenshots/recordings this session):
- **Backend:** hotkey, voice (macOS 26 path exercised live; macOS 15 path build-only), coordinator, run model + stream cleanup — wired and clean.
- **The interaction:** press → notch drops open; **hold → speak → fire**; **tap → type → ⏎ → fire**. The voice read-back shows in quotes, grows to fit, lingers 4–9s, then blur-dissolves to the work line.
- **The window:** fixed canvas, flush at the bezel (concave corners visible), no detach during morphs; **click-through bulletproof** (cursor-position toggle — verified clicks pass through the glow + everywhere but the notch); typing takes keystrokes without activating the app.
- **The glow:** thick, vivid, layered, all around the silhouette (incl. corners), alive from the moment the notch appears.
- **Remembering:** gradient "Remembering ‹note›" surfaces the knowledge-base reads; status stream is filtered clean (no CLI chrome / `stderr:` / prompt echo).
- **Screen context (§6a):** [MEASURED, real hardware, 2026-07-04] on a "what do you see on my screen" command the log shows the full chain — `📸 screenshot captured (752 KB)` → `screenshot: true` → the prompt carries the screenshot line → `codex exec -i` → codex answered **"I see Google Chrome open to `x.com/home` on X in dark mode."** The still is captured, attached, and read. (Note: computer use ALSO has its own live screen access now, so a given answer may draw on either our still or its live view; codex's "using the screenshot as immediate context" confirms our image is ingested.)
- **The logo** matches the app icon — twinned to the right control in a shared 17pt slot, the warm seam stop deepened to gold (no white spot), the white ring extra-fine, spinning 2× faster while processing.
- **Dismiss & Esc:** the notch *retracts/merges into the cutout* on dismiss (no fade); Esc cancels globally (type field · listening · transcript), a right-⌘ tap closes the type field, and STOP/Esc dismiss the transcript instantly while still halting live computer use with the "Stopped" beat.
- **Not yet done:** §12 polish backlog; productionization (§13). Reduced-motion + VoiceOver coded but unverified.

---

## 12. 🎯 The upgrade list

### ✅ A. Expand-on-press + tap-to-type — **DONE**
Press opens the notch instantly (`.opening`); hold → voice; tap → a focused `.typing` field → ⏎ fires. The old "stretch on hold" idea is dropped. (§4, §6.)

### ✅ B. Edge glow — **DONE (significantly improved)**
Thick, layered (3 passes), vivid, all around the silhouette incl. the concave corners, alive from the moment the notch appears, masked so it morphs in lockstep. (§8.)

### ✅ C. Animations — **DONE**
The morph is a longer, bouncier spring; the read-back→work swap is a blur-dissolve-pop; work lines morph in place (`.contentTransition(.interpolate)`); the notch grows/shrinks to fit the read-back; and the **dismiss retracts/merges into the cutout** (§8) instead of fading. Optional if you ever want more: a bezel-descend stagger, content stagger — Dynamic-Island-grade.

### ✅ D. Dismiss everywhere (Esc · ⌘ · STOP) — **DONE**
Esc cancels/dismisses globally via the zero-permission `keyDown` tap (§4) — the type field, listening, and the voice transcript; a right-⌘ tap closes the type field; STOP and Esc both dismiss the transcript INSTANTLY (no flourish) yet halt live computer use with the "Stopped" beat (§6). Computer-use Esc is left for the user's own apps. (⚠️ verify the keyDown tap on macOS 15, §13.)

### E. Deferred touches (each its own focused pass)
- **Behind-mic color dance:** a small blurred colored glow *behind the mic icon* in the listening state (distinct from the edge glow — the `.opening`→`.listening` "lean in" is the hook).
- **Hover-haptic:** a trackpad haptic (`NSHapticFeedbackManager`) when the cursor crosses the notch's boundary.
- **2-line status:** the bar now shows a tight ONE status line (for compactness); if a 2-line codex narration matters, widen `captionHeight` / show the last 2.
- **Multi-task "↓ N tasks":** today it's one run at a time; the future is a stack you pull down (per-task rows + STOPs). Big change to the coordinator (a list of runs) + the notch.

---

## 13. Productionization & cleanup (pre-launch)

- **Arm the hotkey only after onboarding** — `CommandCoordinator.start()` is called unconditionally in `AppState.init` today (so it's testable). Gate it on `hasCompletedOnboarding`.
- **Trim the Speech permission** if `SpeechAnalyzer` works mic-only (drop `VoiceCapture.requestSpeech()`; keep the Info.plist key).
- **Smoke-test the macOS-15 voice fallback** on an old Mac.
- **Verify global Esc on macOS 15.** The listen-only `keyDown` tap is measured permission-free on Tahoe only; confirm Esc still flows (app unfocused, Input Monitoring off) on the 15 floor — same old-Mac trip as the voice fallback. If gated there, fall back to a right-⌘-tap cancel (a modifier is always free).
- **Confirm** the SkyLight pin + order-out never leaves the notch stuck visible when idle.
- **Reduced-motion / VoiceOver** sanity pass.
- **Retire the dev bench** `Views/Dev/HotkeyLabView.swift` + its DEV TOOLS → HOTKEY LAB button once the real hotkey is proven.
- **Screenshot polish (§6a), each its own small pass:** downscale the frame (~1440px wide) to cut upload/latency/tokens · **exclude our own notch overlay** from the shot (ScreenCaptureKit `SCContentFilter` window-exclusion, vs the current `screencapture` CLI) · **multi-display** — capture the display the user is actually on (or attach all via `-i`'s variadic), not just the main one · reconsider the **home command-bar path**, where the frame is usually just Sentient's own UI (skip it there, or capture the display behind).

---

*Keep this doc true: when you change Notch Magic and confirm it works, update the relevant section.* 🖤
