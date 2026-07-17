//
//  CommandCoordinator.swift
//  Sentient OS macOS
//
//  The app-lifetime brain behind "do this for me." Owns the ONE shared codex run (CommandRunModel),
//  the Sidekick hotkey (SidekickHotkeyMonitor — right ⌘ or right ⌥, the user's choice), and voice
//  capture (VoiceCapture) — so whether the user holds the hotkey and speaks, or types in the home
//  command bar, both reach the SAME backend and the
//  SAME notch status (NotchPhase). The notch RENDERING is built later; this owns + drives `phase` and
//  logs every transition, so the whole voice path is testable headlessly today.
//
//  Hotkey path: press → notch OPENS + mic (if already authorized) · still-held @250ms → committed
//  listening · release(hold) → transcribe → submit(.voice) · release(tap) → a focused TYPE field →
//  submit. Prompt-bar path: submit(.promptBar). Card-fire path: beginExternalRun (a proactive card's
//  computer-use fire adopts the same run — ONE task at a time, app-wide, and the notch shows it).
//  Every command is computer use, which raises the notch. A hotkey press during any real run is the
//  universal STOP. Doc: Documentation/Notch Magic/.
//

import Foundation

/// What the notch is showing. Rendered later by NotchView; here it's the source of truth + logged.
enum NotchPhase: Equatable {
    case hidden
    case opening                            // pressed — notch revealed, not yet committed (voice or type?)
    case listening                          // committed to voice — mic open
    case transcribing                       // released → finalizing speech
    case typing                             // tapped — a focused text field to type a task
    case running                            // codex is acting — orb + status line + STOP
    case finishing(CommandRunModel.Outcome) // a brief success / stopped / failed flourish
    case notice(String)                     // a short serif aside: "didn't catch that", mic-off, …
}

/// Where a task came from — voice gets a 4–9s read-back grace (scaled to length); typed doesn't.
/// promptBar = the home command bar · notchTyped = the notch's tap-to-type field — split so the
/// analytics can see Sidekick-only users who never open the home window.
enum TriggerSource: String { case promptBar, notchTyped, voice }

/// Which display the notch overlay lives on, chosen at each interaction's front door. The hotkey and
/// the home command bar keep everything on the MAIN (menu-bar) display. A click on the physical notch
/// anchors the whole session — typing, the running status, the finishing flourish, even the kb-only
/// aside — to the built-in display's real cutout, so the button works when an external display is
/// primary. Sticky through .hidden, so the dismiss retract merges into the same bezel the session
/// opened on. Read by NotchWindowController for placement.
enum NotchAnchor { case mainDisplay, builtInNotch }

@MainActor @Observable
final class CommandCoordinator {
    /// The single shared run — the home command bar AND the hotkey both drive this exact instance.
    let run = CommandRunModel()

    /// What the notch shows. (Rendering lands later; today this is driven + logged.)
    private(set) var phase: NotchPhase = .hidden

    /// The spoken text, echoed for 4–9s (scaled to its length) after a voice launch so a mishear can be caught. The notch shows
    /// `readBack ?? run.statusLine` while running.
    private(set) var readBack: String?

    /// True while the cursor hovers the IDLE notch — the click-to-type affordance (the shell swells
    /// with a haptic tick; a click opens the type field). Set by NotchWindowController, which owns
    /// the cursor geometry; read by NotchView for the grow + drop shadow. Idle-only by construction:
    /// the controller clears it the instant the notch opens for real.
    private(set) var notchHovering = false

    /// The current interaction's display anchor (see NotchAnchor) — set at every front door, sticky
    /// until the next interaction starts.
    private(set) var notchAnchor: NotchAnchor = .mainDisplay

    /// Onboarding's film step arms this while the film is parked on "Click the notch": the next
    /// notch click plays the scripted Sidekick demo on the user's real bezel — the real type field,
    /// the task typing itself, the run model's scripted story — with the two real-world doors (the
    /// Plus aside, the first-use permission gate) deliberately bypassed: nothing real can fire, so
    /// there is nothing to gate. One-shot: consumed at fire, restored by a dismissed field,
    /// disarmed when the film step leaves.
    private(set) var onboardingDemoArmed = false
    private var onboardingDemoFired: (() -> Void)?
    private var demoTask: Task<Void, Never>?

    /// What the demo is currently "typing" — NotchContent mirrors it into the field's draft, so
    /// the show runs through the REAL TextField. nil = the user owns the field.
    private(set) var demoDraft: String?

    private let hotkey = SidekickHotkeyMonitor()
    private let voice = VoiceCapture()
    private var hotkeyChangeObserver: NSObjectProtocol?

    private var listening = false           // a voice session is live (start → finalize / cancel)
    private var voiceStartTask: Task<Void, Never>?
    private var phaseToken = 0              // guards delayed phase transitions against newer ones
    private var readBackToken = 0

    // MARK: Lifecycle

    /// Arm the hotkey + warm the speech model + wire run-completion. Idempotent.
    /// (TODO: production should arm only after onboarding completes — kept always-on for now so the
    /// backend is testable immediately.)
    func start() {
        hotkey.maxHold = VoiceCapture.maxCaptureDuration   // cap the hold at the active engine's limit
        hotkey.setKey(.current)                            // honor the user's Settings choice (right ⌘ / right ⌥)
        hotkey.onPress = { [weak self] in self?.voicePressBegan() }
        hotkey.onHoldConfirmed = { [weak self] in self?.voiceHoldConfirmed() }
        hotkey.onRelease = { [weak self] held in self?.voiceReleased(held: held) }
        // No global Esc: a keyDown tap is exactly what Input Monitoring gates, so the monitor
        // listens to modifiers only. Esc still cancels via the window's LOCAL monitor whenever
        // Sentient itself is frontmost; over other apps, a fresh hotkey press is the cancel
        // (see voicePressBegan).
        hotkey.start()
        // Live re-key when the user flips the choice in Settings — no restart needed.
        hotkeyChangeObserver = NotificationCenter.default.addObserver(
            forName: .sidekickHotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkey.setKey(.current) }
        }
        voice.prewarm()
        run.onFinished = { [weak self] outcome in self?.runFinished(outcome) }
        Log("CommandCoordinator armed (\(hotkey.key.label) hold-to-talk · voice available: \(VoiceCapture.isAvailable))")
    }

    // MARK: The one entry point — hotkey-voice AND the prompt bar both call this

    func submit(_ text: String, mode: AgentMode, source: TriggerSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !run.isRunning else { Log("submit ignored — a task is already running"); return }

        // The home command bar starts a fresh main-display interaction. Voice and notchTyped submits
        // arrive MID-session (the anchor was set at their press/click) and must not move a
        // notch-anchored one to the main display the moment ⏎ lands.
        if source == .promptBar { notchAnchor = .mainDisplay }

        // The onboarding backstop: no run — and therefore no permission gate — can EVER fire
        // before the home screen (the press doors are already guarded; this covers everything).
        if interceptForOnboarding() { return }

        // Knowledge-base-only backstop (the hotkey path already flashed at press) — covers the
        // home command bar, which submits without a press. The run must never fire on free/go.
        if CodexAuth.knowledgeBaseOnly {
            flash(Self.needsPlusNotice, for: 2.0)
            Log("submit blocked — knowledge-base-only plan (Sidekick needs Plus)")
            return
        }

        // First-use permission gate: while any of the four action grants is missing, the one-time
        // setup window takes over and holds this command — Continue fires it, close drops it.
        if ComputerUseGate.shared.intercept({ [weak self] in self?.launch(trimmed, mode: mode, source: source) }) {
            setPhase(.hidden)   // the gate window owns the moment; the notch steps aside
            return
        }
        launch(trimmed, mode: mode, source: source)
    }

    /// The actual fire — everything after the gate. Only submit() and the gate's Continue call this.
    private func launch(_ trimmed: String, mode: AgentMode, source: TriggerSource) {
        guard !run.isRunning else { Log("launch ignored — a task is already running"); return }
        if source == .voice { setReadBack(trimmed) } else { clearReadBack() }
        // Core tier: THE Sidekick-usage count (count only, never the text) — one of the handful of
        // always-on telemetry signals disclosed in Settings.
        Analytics.signal("Command.submitted", parameters: ["source": source.rawValue, "mode": mode.label], tier: .core)
        run.start(trimmed, mode: mode, source: source.rawValue)
        // Every command is computer use, which raises the notch.
        setPhase(.running)
        Log("▶︎ submit [\(source)] \(mode.label) (\(trimmed.count) chars)")   // B7: length, not the command text
        #if DEBUG
        Log("   cmd ↓ \(trimmed)")
        #endif
    }

    /// Cancel the running task. A STOP (or Esc) WHILE THE TRANSCRIPT IS SHOWN means "you misheard me — redo":
    /// dismiss INSTANTLY with no "Stopped" flourish (hiding first makes `runFinished` skip it). Once computer
    /// use is actually working, STOP halts it with the honest "Stopped" beat. Either way the run is cancelled
    /// (an adopted card fire included — run.stop() routes to the card's own cancel).
    func stop() {
        if phase == .running, readBack != nil, run.remembering == nil { setPhase(.hidden) }
        run.stop()
    }

    // MARK: Adopted external runs (a proactive card's computer-use fire)

    /// A proactive card's computer-use fire adopting the notch: the run model lights up — locking
    /// out every other entry point — and the notch rises in `.running`, exactly like a command-bar
    /// launch. Returns false when a task already owns the run (the ONE-task-at-a-time lock): the
    /// caller must not fire. Doubles as the gate-held re-check — a fire the permission gate held
    /// for minutes re-answers the lock here. Completion needs no coordinator API: the card's
    /// completeExternal rides onFinished → runFinished → the normal finishing flourish.
    @discardableResult
    func beginExternalRun(caption: String, onStopRequest: @escaping @MainActor () -> Void) -> Bool {
        guard !run.isRunning else { return false }
        clearReadBack()
        notchAnchor = .mainDisplay        // card fires live on the home's display, like the prompt bar
        run.adoptExternal(caption: caption, onStopRequest: onStopRequest)
        setPhase(.running)
        Log("▶︎ external run adopted (proactive card)")
        return true
    }

    // MARK: Voice + tap-to-type (hotkey) path
    //
    // press → .opening (reveal NOW; mic starts only if already authorized — a tap-to-type must never
    // trigger a permission prompt) · still-held @250ms → .listening (committed; start the mic now if it
    // wasn't pre-authorized) · release(hold) → transcribe → submit · release(tap) → .typing field.

    /// The knowledge-base-only aside — one string for the press flash and the submit backstop.
    /// Short on purpose (the notch truncates around ~45 characters), and shaped like the mic
    /// notice: [do X] to [get Y], in the living-machine voice ("wake", not "unlock").
    private static let needsPlusNotice = "get ChatGPT Plus to wake Sidekick"

    // MARK: Sidekick before the home screen (the onboarding policy)

    /// Sidekick is HOME-ONLY. Until onboarding completes, a press can never open the notch, fire
    /// a run, or raise the first-use permission gate — before the film's notch beat a press does
    /// NOTHING (silence; the hover swell is off too, via notchButtonAvailable); after the beat it
    /// answers with the honest aside. Live-checked per press so it can never go stale.
    private static var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: AppState.onboardingKey)
    }

    /// Flipped the moment the film's notch beat is behind the user (the demo fired, or the film
    /// step was skipped/advanced) — from here presses get the aside instead of silence.
    /// FactoryReset wipes it with the rest of the defaults (the onboarding rewind).
    static let notchDemoPlayedKey = "onboarding.notchDemoPlayed"

    private static let finishOnboardingNotice = "finish onboarding to use Sidekick"

    /// The window controller's gate for the hover affordance: no swell for a button that would
    /// do nothing (pre-beat silence); during the beat and after it, the swell is honest.
    var notchButtonAvailable: Bool {
        Self.hasCompletedOnboarding || onboardingDemoArmed
            || UserDefaults.standard.bool(forKey: Self.notchDemoPlayedKey)
    }

    /// True = the press was consumed by the onboarding policy (silence, or the aside). The
    /// armed demo exempts only the notch CLICK — the film says "click the notch", so a hotkey
    /// press stays quiet even during the beat.
    private func interceptForOnboarding(demoEligible: Bool = false) -> Bool {
        guard !Self.hasCompletedOnboarding else { return false }
        if demoEligible, onboardingDemoArmed { return false }
        if UserDefaults.standard.bool(forKey: Self.notchDemoPlayedKey) {
            flash(Self.finishOnboardingNotice, for: 2.0)
            Log("sidekick press during onboarding — the finish-onboarding aside")
        } else {
            Log("sidekick press during onboarding — silent (pre notch beat)")
        }
        return true
    }

    private func voicePressBegan() {
        // One task, one notch, one key: a press while ANY real task is running STOPS it —
        // hotkey-, command-bar-, or card-launched alike (decided 2026-07-17). Hoisted above the
        // voice gate so a Mac with no speech model still gets the cancel. stop() keeps the
        // transcript beat's instant no-flourish dismiss ("you misheard me"); every other running
        // moment gets the honest "Stopped" beat. The onboarding demo is exempt (scripted
        // theater — the film narrates through it; those presses fall to the guards below).
        if run.isRunning, !run.isDemo {
            stop()
            Log("hotkey → STOP (universal cancel, \(hotkey.key.label))")
            return
        }
        guard VoiceCapture.isAvailable else { return }
        // A hotkey tap while the type field is open toggles it closed (no action) — a quick way to back out.
        if phase == .typing { dismissTyping(); return }
        // The press also bails a stuck finalize (there is no global Esc — keyDown taps are what
        // Input Monitoring gates).
        if phase == .transcribing { cancelCurrent(); return }
        guard !run.isRunning, !isInteracting else { Log("hotkey ignored — busy"); return }
        notchAnchor = .mainDisplay        // the hotkey always lives on the main display (incl. the asides below)
        // Before the home screen, Sidekick doesn't exist yet (the onboarding policy above) —
        // and the permission gate below can therefore never rise during onboarding.
        if interceptForOnboarding() { return }
        // Knowledge-base-only plan (free/go): the notch answers the press INSTANTLY with the
        // Plus aside — same immediate beat as the mic-perms notice — and never opens for
        // listening or typing. Checked live per press, so it can never go stale.
        if CodexAuth.knowledgeBaseOnly {
            flash(Self.needsPlusNotice, for: 2.0)
            Log("hotkey blocked — knowledge-base-only plan (Sidekick needs Plus)")
            return
        }
        // First-use permission gate — BEFORE the notch opens. If any required action grant is
        // missing, the setup window takes the press; the notch never drops open to listen (which
        // would only meet the gate at submit, after a whole listen-and-transcribe dance). The user
        // grants, then presses again to talk. Same window the command bar + proactive cards raise.
        if ComputerUseGate.shared.interceptBeforeStart() {
            Log("hotkey press intercepted — computer-use permissions missing, gate up")
            return
        }
        setPhase(.opening)                                // you're pulling it open — reveal the instant you press
        // Never PROMPT on a press (defer to hold-confirm), and never capture into a model that's
        // still downloading — the audio could never be transcribed.
        if VoiceCapture.isAuthorized, !VoiceCapture.isModelDownloading { startCapture() }
    }

    /// Open the mic (idempotent). On first-ever use this is what prompts — so it's gated to a confirmed hold.
    private func startCapture() {
        guard !listening else { return }
        listening = true
        voiceStartTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.voice.start() }
            catch { self.voiceStartFailed(error) }
        }
    }

    private func voiceHoldConfirmed() {
        guard phase == .opening else { return }
        // Mic or speech DENIED → a hold can never work and no native prompt can re-appear, so the
        // permission window rises as the fix surface (non-blocking — voice is optional; only a
        // committed HOLD reaches this, taps and typed commands never do).
        if !VoiceCapture.isAuthorized, ComputerUseGate.shared.presentVoiceFixIfDenied() {
            setPhase(.hidden)
            Log("hold answered with the permission window — mic/speech denied")
            return
        }
        // A genuine first-run model download → say so instead of pretending to listen (the mic tap
        // only installs after the model lands, so anything spoken now would be silently lost). Only
        // a committed HOLD gets this beat — tap-to-type stays fully alive during the download.
        if VoiceCapture.isModelDownloading {
            flash("still downloading the voice model", for: 2.0)
            Log("hold answered with a download notice — speech model installing")
            return
        }
        setPhase(.listening)               // committed to voice — the "lean in" beat
        if !listening { startCapture() }   // perms weren't pre-granted → start now (the first-use prompt)
    }

    private func voiceReleased(held: TimeInterval) {
        switch phase {
        case .opening, .listening:
            if held >= SidekickHotkeyMonitor.holdThreshold { finalizeVoice() } else { beginTyping() }
        default:
            break
        }
    }

    /// A quick tap → drop any mic capture and morph the open notch into a focused text field.
    private func beginTyping() {
        listening = false
        voiceStartTask?.cancel(); voiceStartTask = nil
        voice.cancel()
        setPhase(.typing)
    }

    private func finalizeVoice() {
        setPhase(.transcribing)
        let token = phaseToken

        // Watchdog — the last-resort backstop: the finalize itself is <2s, and the old trap
        // (voice.start() parked on the asset daemon EVERY press — assetInstallationRequest returns
        // a request even when the model is installed) is gone now that readiness is memoized and
        // gated on installedLocales. What's left is the rare genuine stall (a first-run download
        // reaching a hold, a wedged finalize). Still transcribing after 15s → cancel the capture
        // and say so honestly. The notch must never wedge.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.phaseToken == token, self.phase == .transcribing else { return }
            let downloading = VoiceCapture.isModelDownloading
            Log("✗ transcription timed out — cancelling the capture (\(downloading ? "model still downloading" : "capture stalled"))")
            self.listening = false
            self.voiceStartTask?.cancel(); self.voiceStartTask = nil
            self.voice.cancel()
            self.voice.prewarm()   // best-effort: keep a genuine model install moving (no-op when ready)
            self.flash(downloading ? "voice isn’t ready yet, try again in a moment" : "voice got stuck — try again")
        }

        Task { [weak self] in
            guard let self else { return }
            await self.voiceStartTask?.value     // ensure capture actually started (or failed)
            guard self.listening else { return } // a start failure already set a notice/hidden phase
            guard self.phaseToken == token else { return }   // timed out / Esc'd while waiting
            do {
                let text = try await self.voice.stopAndTranscribe()
                guard self.phaseToken == token else { return }   // timed out / Esc'd mid-finalize
                self.listening = false
                if text.isEmpty {
                    Log("🗣️ heard nothing")
                    self.flash("didn’t catch that")
                } else {
                    Log("🗣️ heard (\(text.count) chars)")   // B7: length, not the raw transcript
                    #if DEBUG
                    Log("   heard ↓ \(text)")
                    #endif
                    self.submit(text, mode: .computer, source: .voice)
                }
            } catch {
                guard self.phaseToken == token else { return }   // the watchdog already spoke
                self.listening = false
                Log("✗ transcription failed — \(error.localizedDescription)")
                self.flash("didn’t catch that")
            }
        }
    }

    private func voiceStartFailed(_ error: Error) {
        listening = false
        voiceStartTask = nil
        voice.cancel()
        if error is CancellationError { return }   // an intentional bail (tap-to-type / Esc / watchdog) — not a failure
        if case VoiceError.notAuthorized = error {
            flash("turn on the microphone to talk to Sentient")
        } else {
            Log("voice start failed — \(error.localizedDescription)")
            // Hide only if we're still in the voice moment — a late failure must never clobber a
            // newer phase (the watchdog's notice, an open type field, a running task).
            switch phase {
            case .opening, .listening, .transcribing: setPhase(.hidden)
            default: break
            }
        }
    }

    // MARK: Tap-to-type (the notch's text field)

    /// ⏎ from the notch field — fire it as a computer-use task (empty just closes).
    func submitTyped(_ text: String) {
        guard phase == .typing else { return }
        // While the onboarding demo owns the field, a stray user ⏎ must never reach the real
        // submit path (the script fires the demo itself).
        guard !onboardingDemoArmed else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { dismissTyping(); return }
        submit(trimmed, mode: .computer, source: .notchTyped)   // typed → no read-back
    }

    /// Esc · click-away · empty-⏎ — close the type field with no action.
    func dismissTyping() {
        guard phase == .typing else { return }
        setPhase(.hidden)
        Log("notch typing dismissed")
    }

    // MARK: The notch as a button (the hover affordance)

    /// NotchWindowController's seam for the hover state (it owns the cursor geometry; the view
    /// renders the swell + shadow off this).
    func setNotchHovering(_ hovering: Bool) {
        guard notchHovering != hovering else { return }
        notchHovering = hovering
    }

    /// A click on the idle, hover-swollen notch — the pointer's twin of a hotkey TAP: open the
    /// tap-to-type field. Mirrors voicePressBegan's beats minus the voice branches (a click can only
    /// mean typing): the knowledge-base-only aside, then the first-use permission gate, then the
    /// field. The window controller makes the panel key on .typing, same as the hotkey path.
    func notchClicked() {
        guard phase == .hidden, !run.isRunning else { return }
        notchAnchor = .builtInNotch       // the whole session lives on the bezel that was clicked
        if onboardingDemoArmed { beginNotchDemo(); return }
        // Before home: silence pre-beat (the swell is off then anyway), the aside after.
        if interceptForOnboarding(demoEligible: true) { return }
        if CodexAuth.knowledgeBaseOnly {
            flash(Self.needsPlusNotice, for: 2.0)
            Log("notch click blocked — knowledge-base-only plan (Sidekick needs Plus)")
            return
        }
        if ComputerUseGate.shared.interceptBeforeStart() {
            Log("notch click intercepted — computer-use permissions missing, gate up")
            return
        }
        setPhase(.typing)
        Log("notch clicked → typing")
    }

    // MARK: The onboarding notch demo (the film step's "click the notch" beat)

    /// Arm the one-shot demo. `onFired` is the film step's cue to resume the webview ride the
    /// moment the demo "presses ⏎" — the film's browser windows play the shopping run while the
    /// real notch narrates.
    func armOnboardingNotchDemo(onFired: @escaping () -> Void) {
        onboardingDemoArmed = true
        onboardingDemoFired = onFired
        Log("onboarding notch demo ARMED")
    }

    /// Disarm + cancel any in-flight typing script (the film step left, or SKIP). A demo RUN
    /// already in flight is left to finish on its own — it's pure theater and self-retracts.
    func disarmOnboardingNotchDemo() {
        guard onboardingDemoArmed || demoTask != nil else { return }
        onboardingDemoArmed = false
        onboardingDemoFired = nil
        demoTask?.cancel(); demoTask = nil
        demoDraft = nil
        Log("onboarding notch demo disarmed")
    }

    /// The demo click: the REAL type field opens (no Plus aside, no permission gate — nothing real
    /// can fire), the film's task types itself, then the run model performs the scripted story.
    /// A dismissed field (Esc / click-away / hotkey tap) bails the script and re-arms for another
    /// click; the arm is consumed only when the demo actually fires.
    private func beginNotchDemo() {
        setPhase(.typing)
        Log("notch clicked → onboarding demo (typing)")
        demoTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(0.7))          // the field's bloom + focus settle
                let task = "order this stuff"
                for i in 1...task.count {
                    guard let self, self.phase == .typing else { self?.demoDraft = nil; return }
                    self.demoDraft = String(task.prefix(i))
                    try await Task.sleep(for: .seconds(0.07))
                }
                try await Task.sleep(for: .seconds(0.4))          // the beat before ⏎
                guard let self, self.phase == .typing else { self?.demoDraft = nil; return }
                self.demoDraft = nil
                self.onboardingDemoArmed = false                  // consumed — later clicks are real
                UserDefaults.standard.set(true, forKey: Self.notchDemoPlayedKey)   // beat done → presses get the aside
                let fired = self.onboardingDemoFired
                self.onboardingDemoFired = nil
                self.demoTask = nil
                self.run.startOnboardingDemo()
                self.setPhase(.running)
                Log("▶︎ onboarding notch demo fired")
                fired?()
            } catch {
                self?.demoDraft = nil                             // cancelled by disarm — nothing to restore
            }
        }
    }

    /// Cancel — back out of whatever the notch is doing, mirroring the obvious one-tap action for each state:
    /// dismiss the type field · abandon an open/listening/transcribing voice capture (so a later release
    /// fires nothing, and a stuck finalize can always be bailed) ·
    /// or, ONLY while the voice transcript is still on screen, cancel the just-fired run and dismiss INSTANTLY
    /// (no "Stopped" flourish — that's reserved for interrupting live computer use via STOP) so a misheard
    /// command can be killed and redone at a glance. The instant the transcript dissolves into the working /
    /// "Remembering" line, cancel is left ALONE — computer use is now quietly running. Returns whether it
    /// consumed the event (so the key monitor swallows it). Reached via the window's LOCAL Esc monitor
    /// (works whenever Sentient is frontmost — no global keyDown tap, that's Input-Monitoring-gated) and
    /// via a right-⌘ press for the transcribing beat (voicePressBegan).
    @discardableResult
    func cancelCurrent() -> Bool {
        switch phase {
        case .typing:
            dismissTyping()
            return true
        case .opening, .listening, .transcribing:
            listening = false
            voiceStartTask?.cancel(); voiceStartTask = nil
            voice.cancel()
            setPhase(.hidden)
            Log("notch voice capture cancelled (Esc)")
            return true
        // Only while the transcript is actually shown (readBack up AND not yet replaced by "Remembering") —
        // not once computer use is working, so Esc stays free for the user's own apps then.
        case .running where readBack != nil && run.remembering == nil:
            stop()                       // transcript shown → stop() dismisses instantly (no flourish), run cancelled
            Log("notch transcript cancelled (Esc) — immediate dismiss")
            return true
        default:
            return false
        }
    }

    /// True while a voice/tap interaction is mid-flight — a fresh press is ignored until it resolves.
    private var isInteracting: Bool {
        switch phase {
        case .opening, .listening, .transcribing, .typing: return true
        default: return false
        }
    }

    // MARK: Run completion → the notch's finishing flourish

    private func runFinished(_ outcome: CommandRunModel.Outcome) {
        clearReadBack()
        // Only flourish if the notch is actually up (a stop/dismiss may have already hidden it).
        guard phase == .running else { setPhase(.hidden); return }
        setPhase(.finishing(outcome))
        // ✓/stopped are a quick flourish; a failure holds longer — its caption carries the ✗ REASON
        // (the sentinel's give-up explanation or the error), and that has to be readable.
        scheduleHide(after: outcome == .failed ? 5.0 : 1.5)
    }

    // MARK: Phase + read-back plumbing (generation-guarded so a delayed change never clobbers a newer one)

    private func setPhase(_ newPhase: NotchPhase) {
        phase = newPhase
        phaseToken &+= 1
        Log("notch → \(newPhase)")
    }

    private func scheduleHide(after seconds: Double) {
        let token = phaseToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.phaseToken == token else { return }
            self.setPhase(.hidden)
        }
    }

    private func flash(_ message: String, for seconds: Double = 1.5) {
        setPhase(.notice(message))
        scheduleHide(after: seconds)
    }

    private func setReadBack(_ text: String) {
        readBack = text
        readBackToken &+= 1
        let token = readBackToken
        let seconds = NotchMetrics.readBackDuration(for: text)   // 4s (one line) → 9s (long), scaled to length
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.readBackToken == token else { return }
            self.readBack = nil
        }
    }

    private func clearReadBack() {
        readBack = nil
        readBackToken &+= 1
    }
}
