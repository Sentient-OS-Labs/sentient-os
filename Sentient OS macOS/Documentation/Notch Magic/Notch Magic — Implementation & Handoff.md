# 🪄 Notch Magic — Implementation & Handoff

**You are a fresh Claude picking this up. You have NO prior context — this doc is your complete context. Read it fully before touching code.** It covers what the feature is, every file, and the hard-won lessons (please don't re-break them). The interaction, the window, the glow, and the core animations are **built and confirmed working on Jesai's bezel**; §12 is what's left, §13 is productionization.

> **How to verify your work:** build through the **Xcode MCP `BuildProject`** (same signing as the Run button) and sweep `GetBuildLog` for warnings. **`RenderPreview` does NOT work on this target** — it has to launch the whole app and times out (see §9). So for anything *visual/animated*, build clean, then **ask Jesai to run it and screenshot/screen-record** — the notch lives on his physical bezel and is all motion; that's the only real test.

> **Design language** (so the notch stays *us*): OLED black as a material · the AI spectrum is `GlowHalo.stops` in `Views/GlowButton.swift` (warm→cool: `#fde2a3 #ff8e3c #ff4646 #e8388f #9b48d4 #6c5ce5 #4a90e2` + wrap — the *same* stops the website logo spins) · serif italic for soul, monospace for the machine whisper · motion is physics, not UI. The logo target is the **app icon** (a thick vibrant color ring + white planet dot).

---

## 1. What Notch Magic is

**A global way to tell Sentient to *do something*, and a universal status surface for when it's working.** Three front doors, one backend, one notch:

1. **Press-and-hold the right ⌘ key anywhere** → the notch *drops open the instant you press* (you're pulling it open); *speak* a task → release → it transcribes (on-device) and fires it as a **computer-use** command.
2. **Tap the right ⌘ key** (a quick press-release, no hold) → the open notch becomes a focused **text field** → type a task, hit ⏎ → same computer-use backend.
3. **Type in the home command bar** (`PromptBar`) → same backend, same notch.

All funnel through **`CommandCoordinator` → `CommandRunModel` → `CodexCLI.runAgentCommand`**, and the notch is a live view of `coordinator.phase` (+ `coordinator.run`). The notch is the Mac's "face" coming alive — it descends from the bezel **glowing**, shows what it heard (or lets you type), then streams the work — *Thinking through your task*, **Remembering** the notes it reads from your knowledge base, the actions — with a STOP button, and retracts.

Every command is **computer use** (the dedicated browser-use channel was removed — see the root architecture doc §7), and the notch shows for all of them.

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
| **`RightCommandMonitor.swift`** | Zero-permission global right-⌘ detector (a `flagsChanged`-only `CGEventTap`). Emits `onPress` / `onHoldConfirmed` / `onRelease(held:)`. Self-healing. |
| **`QuickTranscriptionEngine.swift`** | The protocol both speech engines conform to + `VoiceError`. |
| **`SpeechAnalyzerEngine.swift`** | macOS **26+** speech-to-text (`SpeechAnalyzer` + `SpeechTranscriber`, on-device, in-memory). |
| **`SFSpeechRecognizerEngine.swift`** | macOS **15** fallback (`SFSpeechRecognizer`, server-capable). |
| **`VoiceCapture.swift`** | Façade: mic + speech permissions, engine selection, `prewarm` / `start` / `stopAndTranscribe` / `cancel`. |
| **`CommandRunModel.swift`** | Runs ONE codex task; **cleans codex's raw human-readable stream** into the bar's `statusLine` + the `remembering` state (§6); `stop()`, `onFinished(Outcome)`. |
| **`CommandCoordinator.swift`** | The brain: owns the run + hotkey + voice, drives `phase` (`NotchPhase`), the press→branch flow, `submit()` / `submitTyped()` / `dismissTyping()`. |
| **`NotchSpace.swift`** | SkyLight private-API wrapper — pins the panel into a top-level window-server space so it's fixed over the notch on every Space. |
| **`NotchWindowController.swift`** | The `NSPanel` host: a **fixed canvas** flush at the bezel; click-through by toggling `ignoresMouseEvents` per cursor position; all-Spaces; observers. Also `NotchPanel`, `NotchHostingView`, the `NSScreen.notchSize`/`displayID` extension. |
| **`NotchShape.swift`** | The silhouette `Shape` (animatable corner radii) **+ `NotchSkirtShape`** — its open twin (sides + rounded bottom + concave top corners, no flat top edge) that the glow strokes. |
| **`SpinningLogo.swift`** | The 2D spectrum-ring logo (matches the app icon). |
| **`NotchView.swift`** | `NotchView` (binder) + `NotchContent` (the pure visual: morph, phases, layered edge glow, the read-back / Remembering / status captions) + `NotchMetrics` (per-phase sizing) + `NotchStopButton` + the `.blurDissolve` transition. |

Edits outside this folder: `AppState.swift` (owns/starts the two objects), `Views/HomeView.swift` (`PromptBar` drives `appState.commandCoordinator`), and the project's `INFOPLIST_KEY_NSMicrophoneUsageDescription` + `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` build settings.

There is still a **DEV bench** `Views/HotkeyLabView.swift` (DEV TOOLS → HOTKEY LAB) — the original proof of the hotkey tap. It's superseded by `RightCommandMonitor`; **retire it** once you're confident (see §13).

---

## 4. The hotkey — `RightCommandMonitor`

**The headline: detecting the right ⌘ needs ZERO permissions, forever.** macOS gates `keyDown`/`keyUp` (the letters you type) behind Input Monitoring — but **NOT `flagsChanged`** (modifier transitions). Right ⌘ is a modifier, so a *listen-only* `CGEventTap` masking **only `flagsChanged`** sees it globally with no prompt, no Settings entry, no Accessibility — even in the notarized, Finder-launched app.

- **The one ironclad rule:** never add `keyDown`/`keyUp` to the global mask. That's the gated half. (Tap-to-type captures typing in our *own* focused `TextField`, not via a global tap.)
- **Ground-truth state:** on every `flagsChanged`, we read the **device-dependent right-⌘ bit** (`NX_DEVICERCMDKEYMASK = 0x10`) from `event.flags`. So press/release self-heals even if an individual event is dropped (we never toggle a fragile keycode set).
- **Hold vs tap:** `holdThreshold = 0.25s`. `onHoldConfirmed` fires at 250ms if still held; `onRelease(held:)` reports the duration. The coordinator turns a held release into voice, a quick release into the type field (§6).
- **Reliability:** re-enable on `.tapDisabledBy…`; re-arm on `NSWorkspace.didWake`; a 1.5s health timer rebuilds a dead tap and reconciles a missed release against `CGEventSource.flagsState(.combinedSessionState)`; a `maxHold` safety force-releases a stuck hold (set by the coordinator to the engine's transcription cap — see §5).
- The C trampoline must be `nonisolated` (project builds with `-default-isolation=MainActor`; an actor-isolated func can't be a `@convention(c)` pointer) and hops to `@MainActor` to call `handle(type:flags:)`.

Keycodes for reference: right ⌘ = 54, left ⌘ = 55 (we use the *flag bit*, not the keycode).

---

## 5. Voice + transcription

`VoiceCapture` is the façade the coordinator talks to. It:
- **Permissions:** microphone (`AVCaptureDevice`) + speech (`SFSpeechRecognizer`). A static **`isAuthorized`** lets a *press* start the mic only when both are ALREADY granted — so a tap-to-type never throws a mic dialog; the first-use prompt waits for a confirmed hold (§6). Both Info.plist usage strings are set in the build settings. ⚠️ The Speech framework **crashes** without `NSSpeechRecognitionUsageDescription`, so that key is mandatory. *(Open question: on-device `SpeechAnalyzer` may not need the speech grant — if mic-only works, drop `requestSpeech()`. See §13.)*
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
- **Tap-to-type:** `submitTyped(_)` (⏎ in the notch field) → `submit(.computer, .promptBar)`; `dismissTyping()` (Esc · click-away · empty-⏎) → `.hidden`.

**Run completion** (`run.onFinished`): if `phase == .running` → `.finishing(outcome)` → `scheduleHide(2.5)`.

**Plumbing:** `setPhase` bumps `phaseToken`; `scheduleHide`/`flash`/`setReadBack` capture the token and only fire if unchanged — a delayed transition can never clobber a newer one.

**`CommandRunModel` cleans codex's raw stream into the bar.** `codex exec` (computer use, human-readable, gpt-5.5 + `model_reasoning_effort=low`) emits a noisy play-by-play; `push(line)` distills it:
- **strip** the `stderr:` channel tag (before trimming, so empty `stderr:` lines don't flash);
- **track sections** by codex's bare headers (`user`/`codex`/`exec`/…) — show only codex's narration + tool/`mcp:` lines; drop the startup banner, the user-prompt echo, and raw shell output (`barLine`);
- in the **`exec`** section, surface knowledge-base reads as the **`remembering`** state — `knowledgeBaseRead` slices the note path out of a `cat`/`grep`/`sed`/… command (command-agnostic: keys off the vault path, requires it shell-quoted so grep *output* isn't mistaken for a read). `setRemembering` holds it ≥1.5s (so the bloom completes for a single file);
- replace the confirmation-policy `SKILL.md` dump's lingering tail ("…avoid redundant confirmations…") with **"Thinking through your task"**.

---

## 7. The notch window — `NotchWindowController` + `NotchSpace`

This is where most of the hard bugs were fought and won. The window is a **FIXED canvas** (DynamicNotch's actual approach) — it does NOT resize per state; the notch shape morphs *inside* it. Invariants, do not regress:

**(a) Fixed canvas, top-flush, NEVER resized during a morph.** The panel is sized once to `canvasSize` — the biggest notch state + slack (`canvasHSlack 140`, `canvasVSlack 90`) for the bounce-overshoot and glow bloom — pinned with its top at the screen's edge. `applyPhase` just `placeCanvas()` + `reveal()`; on `.hidden` it `orderOut`s after `settleDelay` (idle = no window at all). Because the window never moves/resizes mid-animation, the notch **can't detach from the bezel**.
> ⚠️ The OLD approach — resize the window to the notch on every phase change (grow-to-union, shrink-after-settle) — made the notch visibly **jump off the bezel** mid-morph (the AppKit frame and the SwiftUI animation fought, worse with a bouncy spring). Don't go back to per-state window resizing.

**(b) Click-through = `ignoresMouseEvents` toggled by CURSOR POSITION.** macOS does per-pixel hit-testing: a click on ANY non-transparent pixel (incl. the glow bloom) is caught by the window *before* `hitTest` runs, and a nil `hitTest` then **swallows** it rather than passing through. So a static hitTest can't make the glow click-through. Instead a ~60 Hz cursor poll (`mouseTimer`, added in `.common` run-loop mode) sets `ignoresMouseEvents = false` **only while the cursor is over the actual notch silhouette** (`cursorOverSilhouette` — a `NotchShape` path test in screen coords); everywhere else the whole window ignores the mouse, so clicks (over the glow, the empty canvas, an inch away) sail straight through. `hitTest` then just returns `super ?? self`; `acceptsFirstMouse` so STOP/the field fire on the first click.
> ⚠️ Don't gate click-through on a static `hitTest`/rect — the glow's drawn pixels are caught before hitTest, and a rect over-claims the area beside the rounded notch. Gate on **where the cursor is**, against the **shape path**.

**(c) Present on ALL Spaces + no slide.** Both still needed: `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`, **re-asserted on EVERY `reveal()`** (macOS drops `.canJoinAllSpaces` on re-order); and `NotchSpace.shared?.pin(panel)` (the SkyLight private API, level `Int32.max`) so it doesn't slide during the 3-finger Spaces swipe (`.stationary` is Exposé-only; best-effort, falls back to the public behaviour).

**(d) Typing needs a key window.** Entering `.typing`, `reveal(makeKey: true)` → `makeKeyAndOrderFront`: the `.nonactivatingPanel` becomes key (takes keystrokes) WITHOUT bringing the app forward over what you're using. A `didResignKey` observer (guarded against the focus-setup race via `typingKeyAt`) dismisses the field on click-away. `NotchPanel.constrainFrameRect` is overridden so the window can sit flush at the very top (over the menu bar).

Other notes: `level = .mainMenu + 3`; `sharingType` **left at default** (the notch shows in screen recordings — Jesai chose recordability). Observers (`didChangeScreenParameters`, `activeSpaceDidChange`, `didWake`, `didActivateApplication`) re-place the canvas on the menu-bar display (`CGMainDisplayID`, not `NSScreen.main`) and re-`reveal()`; `host.update(metrics:)` re-renders on display change.

---

## 8. The notch visual — `NotchView` / `NotchContent` / `NotchShape` / `SpinningLogo`

`NotchView` is a thin binder reading `coordinator`; `NotchContent` is the pure, previewable visual (`phase, readBack, statusLine, remembering, metrics, onStop, onSubmitText, onCancelText`).

**The shape sits FLUSH at the bezel.** `NotchShape`'s concave top corners (the genuine-notch flare into the screen edge) are now VISIBLE — the window's top is at the screen edge and the shape's top edge lands on it (the old `topBleed` that shoved the top off-screen is gone). `NotchSkirtShape` is its open twin: the visible perimeter (concave top corners → sides → rounded bottom) but NOT the flat top edge — the glow strokes this, so it warps up into the corners yet never lights the bezel line.

**`NotchMetrics`** computes per-phase `size`/`radii`, kept TIGHT so the notch eats minimally into apps (it runs over the user's browser tabs while computer use works):
- `baseWidth = max(notch.width, 200)`, `baseHeight = max(notch.height, 32)` (`auxiliaryTopLeftArea.height`).
- **opening/listening/transcribing:** `width = baseWidth + 76`, `height = baseHeight + notchBottomCover` — a small **`+2`** cover, because `auxiliaryTopLeftArea.height` reports a hair shallower than the notch's real cutout, so the mic state (the only one sized to ~`baseHeight`; every other state is taller and overshoots) would otherwise let the hardware lip peek below. Radii = the real notch radius (`top: baseHeight/3 - 4`, `bottom: baseHeight/3`).
- **running/finishing:** `runningHeight(caption:) = baseHeight + caption + bottomPad` — `caption` is the read-back's measured height (grows to fit, below) or the tight one-line status (`captionHeight 18`). `topPad 0` + zero VStack spacing so the text sits right under the hardware notch; `bottomPad 4`.
- **typing:** wider + one focusable field row.

**Layout (camera-flanking):** a top row (`SpinningLogo` · `Spacer(centerGap 64)` · `rightControl`) at the camera band, then the caption / type-field row. `hPad 18` clearance. `rightControl` cross-fades between mic (opening calmer → listening "leans in") · spinner (transcribing) · the `TextField` (typing) · `NotchStopButton` (running) · outcome glyph (finishing).

**The running caption is 3-way** (`runningCaptionKey` = remembering ▸ read-back ▸ status), swapped with a **fancy blur-dissolve-pop** (`.blurDissolve` = blur + fade + a spring scale, on `.spring(duration: 0.7, bounce: 0.35)`):
- **Read-back** — the heard instruction, serif italic, in **curly quotes**; the notch **grows DOWN to fit the whole thing** (measured via `NSString.boundingRect` on the same quoted string, capped at `maxReadBackLines 10`) and lingers **4–9s scaled by line count** (`NotchMetrics.readBackDuration`), then dissolves to the work line.
- **Remembering** — codex reading the knowledge base: the word **"Remembering"** in the analysis-screen "Everything." gradient (`rememberingGradient`), gently breathing via opacity, with the note path morphing beside it per file (`.contentTransition(.interpolate)`).
- **Status** — codex's work lines, mono, `.contentTransition(.interpolate)` so only the CHANGED glyphs morph in place (shared prefixes stay put — e.g. one tool line → the next).

**The morph:** one spring `.spring(response: 0.52, dampingFraction: 0.72)` drives size/radii/content/glow together on `phase`, `readBack`, and `remembering` (reduced-motion → 0.24s ease) — fast-out, gentle settle, slight bounce.

**The edge glow** (`glow` ×3 → `glowLayer`): a rotating `AngularGradient(GlowHalo.stops)` **masked by `NotchSkirtShape.stroke`** — the mask lives in the body so it morphs in LOCKSTEP with the black fill (no "separate entity" pop-in). Three layers (wide soft halo + dense halo behind the fill, crisp bright rim over it) make it thick + vivid. It's **always present**, fading via `.opacity(glowStrength)` so the edges light up in place; `glowStrength` is non-zero for **every visible state** (opening/listening/typing/running…), so the notch glows from the moment it's summoned. ⚠️ Each layer expands its gradient `(lineWidth/2 + blur + 6)` past every edge (`.padding(-m)` + `.mask(skirt.padding(m))`) so the BOTTOM edge isn't thinner than the sides (the gradient must reach beyond the stroke + blur on ALL sides, and the bottom edge sits at the frame edge).

**`SpinningLogo`** (matches the app icon — a thick vibrant color ring + white planet):
- Layers: a soft **single** additive bloom · the **thick, SHARP, saturated color band** (`stroke` at `lineWidth size*0.17`, almost no blur — *this* is the visible color) · a thin white ring (`size*0.028`, "just for shape") · the white planet (`size*0.36`) with a tiny additive glow.
- ⚠️ **One additive pass only for the color.** Stacking multiple `.plusLighter` passes blew the pale first stop (`#fde2a3`) past white → a "white thick part" swept around as it spun. One pass on black = the true color.
- The spin is **wall-clock** via `TimelineView` (no per-frame `@State`); speed is `period(fast)` (13s idle, 4s when `fast == .running`); an **anchor** (`anchorAngle`/`anchorTime`, re-based in `onChange(of: fast)`) keeps the colors from jumping when the speed changes.
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
11. **Default-MainActor isolation** is on. Off-main code (the audio tap, the CGEvent trampoline) must be `nonisolated` and capture locals, not `self`.

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
- **The logo** matches the app icon; spin glitch fixed.
- **Not yet done:** §12 deferred touches; productionization (§13). Reduced-motion + VoiceOver coded but unverified.

---

## 12. 🎯 The upgrade list

### ✅ A. Expand-on-press + tap-to-type — **DONE**
Press opens the notch instantly (`.opening`); hold → voice; tap → a focused `.typing` field → ⏎ fires. The old "stretch on hold" idea is dropped. (§4, §6.)

### ✅ B. Edge glow — **DONE (significantly improved)**
Thick, layered (3 passes), vivid, all around the silhouette incl. the concave corners, alive from the moment the notch appears, masked so it morphs in lockstep. (§8.)

### ◐ C. Animations — **mostly done**
The morph is a longer, bouncier spring; the read-back→work swap is a blur-dissolve-pop; work lines morph in place (`.contentTransition(.interpolate)`); the notch grows/shrinks to fit the read-back. Still open if you want more: the bezel-descend stagger, retract polish, content stagger — Dynamic-Island-grade.

### D. Deferred touches (each its own focused pass)
- **Behind-mic color dance:** a small blurred colored glow *behind the mic icon* in the listening state (distinct from the edge glow — the `.opening`→`.listening` "lean in" is the hook).
- **Hover-haptic:** a trackpad haptic (`NSHapticFeedbackManager`) when the cursor crosses the notch's boundary.
- **2-line status:** the bar now shows a tight ONE status line (for compactness); if a 2-line codex narration matters, widen `captionHeight` / show the last 2.
- **Multi-task "↓ N tasks":** today it's one run at a time; the future is a stack you pull down (per-task rows + STOPs). Big change to the coordinator (a list of runs) + the notch.

---

## 13. Productionization & cleanup (pre-launch)

- **Arm the hotkey only after onboarding** — `CommandCoordinator.start()` is called unconditionally in `AppState.init` today (so it's testable). Gate it on `hasCompletedOnboarding`.
- **Trim the Speech permission** if `SpeechAnalyzer` works mic-only (drop `VoiceCapture.requestSpeech()`; keep the Info.plist key).
- **Smoke-test the macOS-15 voice fallback** on an old Mac.
- **Confirm** the SkyLight pin + order-out never leaves the notch stuck visible when idle.
- **Reduced-motion / VoiceOver** sanity pass.
- **Retire the dev bench** `Views/HotkeyLabView.swift` + its DEV TOOLS → HOTKEY LAB button once the real hotkey is proven.

---

*Keep this doc true: when you ship an upgrade and it's confirmed working, update the relevant section. This is the only context the next Claude gets.* 🖤
