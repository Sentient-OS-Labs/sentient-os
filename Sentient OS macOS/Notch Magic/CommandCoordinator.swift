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
//  submit. Prompt-bar path: submit(.promptBar). Every command is computer use, which raises the notch.
//  Doc: Documentation/Notch Magic/.
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
enum TriggerSource: String { case promptBar, voice }

@MainActor @Observable
final class CommandCoordinator {
    /// The single shared run — the home command bar AND the hotkey both drive this exact instance.
    let run = CommandRunModel()

    /// What the notch shows. (Rendering lands later; today this is driven + logged.)
    private(set) var phase: NotchPhase = .hidden

    /// The spoken text, echoed for 4–9s (scaled to its length) after a voice launch so a mishear can be caught. The notch shows
    /// `readBack ?? run.statusLine` while running.
    private(set) var readBack: String?

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
        Analytics.signal("Command.submitted", parameters: ["source": source.rawValue, "mode": mode.label])   // count only, never the text
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
    /// use is actually working, STOP halts it with the honest "Stopped" beat. Either way the run is cancelled.
    func stop() {
        if phase == .running, readBack != nil, run.remembering == nil { setPhase(.hidden) }
        run.stop()
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

    private func voicePressBegan() {
        guard VoiceCapture.isAvailable else { return }
        // A hotkey tap while the type field is open toggles it closed (no action) — a quick way to back out.
        if phase == .typing { dismissTyping(); return }
        // The hotkey doubles as the GLOBAL cancel (there is no global Esc — keyDown taps are what
        // Input Monitoring gates): a press while a stuck finalize is spinning, or while the
        // just-fired transcript is still shown ("you misheard me"), backs out — the beats the
        // global Esc used to cover.
        if phase == .transcribing { cancelCurrent(); return }
        if phase == .running, readBack != nil, run.remembering == nil {
            stop()                        // transcript shown → instant dismiss, run cancelled
            Log("notch transcript cancelled (\(hotkey.key.label))")
            return
        }
        guard !run.isRunning, !isInteracting else { Log("hotkey ignored — busy"); return }
        // Knowledge-base-only plan (free/go): the notch answers the press INSTANTLY with the
        // Plus aside — same immediate beat as the mic-perms notice — and never opens for
        // listening or typing. Checked live per press, so it can never go stale.
        if CodexAuth.knowledgeBaseOnly {
            flash(Self.needsPlusNotice, for: 2.0)
            Log("hotkey blocked — knowledge-base-only plan (Sidekick needs Plus)")
            return
        }
        setPhase(.opening)                                // you're pulling it open — reveal the instant you press
        if VoiceCapture.isAuthorized { startCapture() }   // never PROMPT on a press; defer to hold-confirm
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

        // Watchdog: transcription must resolve promptly (the finalize itself is <2s; the trap is
        // voice.start() still parked on the on-device speech model DOWNLOAD, which has no bound of
        // its own — seen in the field as a notch spinning forever with every new press "busy").
        // Still transcribing after 15s → cancel the capture, keep the model download moving for
        // the next attempt, and say so honestly. The notch must never wedge.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.phaseToken == token, self.phase == .transcribing else { return }
            Log("✗ transcription timed out — cancelling the capture (speech model likely still downloading)")
            self.listening = false
            self.voiceStartTask?.cancel(); self.voiceStartTask = nil
            self.voice.cancel()
            self.voice.prewarm()   // best-effort: resume/continue the model install in the background
            self.flash("voice isn’t ready yet, try again in a moment")
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
        if case VoiceError.notAuthorized = error {
            flash("turn on the microphone to talk to Sentient")
        } else {
            Log("voice start failed — \(error.localizedDescription)")
            setPhase(.hidden)
        }
    }

    // MARK: Tap-to-type (the notch's text field)

    /// ⏎ from the notch field — fire it as a computer-use task (empty just closes).
    func submitTyped(_ text: String) {
        guard phase == .typing else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { dismissTyping(); return }
        submit(trimmed, mode: .computer, source: .promptBar)   // typed → no read-back
    }

    /// Esc · click-away · empty-⏎ — close the type field with no action.
    func dismissTyping() {
        guard phase == .typing else { return }
        setPhase(.hidden)
        Log("notch typing dismissed")
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
        scheduleHide(after: 1.5)         // a quick ✓/stopped/✗ flourish, then retract
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
