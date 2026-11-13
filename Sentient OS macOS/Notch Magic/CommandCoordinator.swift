//
//  CommandCoordinator.swift
//  Sentient OS macOS
//
//  The app-lifetime brain behind "do this for me." Owns the ONE shared codex run (CommandRunModel),
//  the Sidekick hotkey (SidekickHotkeyMonitor — one shared single key), and voice
//  capture (VoiceCapture) — so whether the user taps the key and types, clicks the notch's mic and
//  talks, or types in the home command bar, every door reaches the SAME backend and the SAME notch
//  status (NotchPhase). This owns + drives `phase` and logs every transition.
//
//  A completed standalone tap reveals the notch; after the double-tap window it focuses the
//  type field. A second tap drafts a reply without taking focus. Both actions share one saved
//  key. Voice starts from the field's mic button. Prompt-bar path: submit(.promptBar).
//  Card buttons submit a proactive reply through submit(.proactiveCard). Legacy external runs adopt
//  the same run. ONE task at a time, app-wide, and the notch shows it.
//  Every command is computer use, which raises the notch. A hotkey press during a running task
//  does nothing on its own (the notch's STOP button, the bar's STOP, and Esc are the cancels);
//  two presses are still a double tap. Doc: the two Documentation - Sidekick - *.md files here.
//

import AppKit
import Foundation

/// What the notch is showing. Rendered by NotchView; here it's the source of truth + logged.
enum NotchPhase: Equatable {
    case hidden
    case opening                            // pressed — notch revealed, waiting out the double-tap window (type, or a reply draft?)
    case typing                             // the field: type a task, or click its mic to talk
    case listening                          // the mic is open — the field row shows "Listening…" + the stop button
    case transcribing                       // stopped → finalizing speech
    case running                            // codex is acting — orb + status line + STOP
    case message                            // a committed user-facing message, never a second task
    case recovery                           // one pending question or an app-owned retry
    case finishing(CommandRunModel.Outcome) // a brief success / stopped / failed flourish
    case notice(String)                     // a short serif aside: "didn't catch that", mic-off, …

    /// Only presentation changes; the shared run and its completion state keep advancing.
    func displayed(homeFocused: Bool) -> Self {
        guard homeFocused else { return self }
        switch self {
        case .running, .finishing, .message, .recovery: return .hidden
        default: return self // Explicit input and short quick-action feedback still work.
        }
    }

}

/// Where a task came from — voice gets a 0.5–2.5s read-back grace (scaled to length); typed doesn't.
/// promptBar = the home command bar · notchTyped = the notch's tap-to-type field — split so the
/// analytics can see Sidekick-only users who never open the home window.
enum TriggerSource: String { case promptBar, notchTyped, voice, proactiveCard = "proactive_card" }

/// Which display the notch overlay lives on, chosen at each interaction's front door. The hotkey and
/// the home command bar keep everything on the MAIN (menu-bar) display. A click on the physical notch
/// anchors the whole session — typing, the running status, the finishing flourish, even the kb-only
/// aside — to the built-in display's real cutout, so the button works when an external display is
/// primary. Sticky through .hidden, so the dismiss retract merges into the same bezel the session
/// opened on. Read by NotchWindowController for placement.
enum NotchAnchor: Equatable { case mainDisplay, builtInNotch, display(CGDirectDisplayID) }

@MainActor @Observable
final class CommandCoordinator {
    /// The single shared run — the home command bar AND the hotkey both drive this exact instance.
    let run = CommandRunModel()
    let summarize = SummarySessions()
    let proofread = Proofread.shared
    let quickActionHotkeys = QuickActionHotkeys()
    private var quickActionTask: Task<Void, Never>?
    private var quickActionID: UUID?
    @ObservationIgnored var relinquishNotchFocus: (() -> Void)?
    var notchInputReady: Bool { !proofread.isCapturingSelection }

    /// Buttons and short spoken requests share the same personal reply engine as Double Tap.
    @discardableResult
    func magicReply(source: TriggerSource = .notchTyped, preference: String = "") -> Bool {
        guard quickActionsAvailable, !run.isRunning, !run.isClearingChat, !run.recovery.isPending,
              voiceSessionID == nil, !proofread.isRunning,
              !DoubleTap.shared.isDrafting else { return false }
        #if DEBUG
        guard !run.preventsTaskExecutionForUIFixture else { return false }
        #endif
        pendingSingleTap?.cancel(); pendingSingleTap = nil; hotkeyPair.reset()
        proofread.clearPreparedSelection(); clearReadBack()
        let displayID = summaryDisplayID ?? ScreenCapture.summaryDisplay()
        setPhase(.hidden)
        // Return the nonactivating panel's keyboard focus synchronously, before the shared
        // Double Tap task reads the caret or captures the screen.
        relinquishNotchFocus?()
        let token = phaseToken
        SidekickDiscovery.recordNotchUse()
        Log("⌘⌘ magic reply [\(source.rawValue)] → direct draft")
        DoubleTap.shared.start(displayID: displayID, preference: preference) { [weak self] result in
            guard let self, self.phaseToken == token else { return }
            switch result {
            case .pasted: break // The existing caret light lands with the personalized draft.
            case .notAMessage: break // The shared engine shows its pointer-following explanation.
            case .stopped: break
            case .failed(let reason): self.flash(reason, for: 3)
            }
        }
        return true
    }

    @discardableResult
    func takeOver(source: TriggerSource = .notchTyped) -> Bool {
        guard quickActionsAvailable, !run.isRunning, !run.isClearingChat, !run.recovery.isPending,
              voiceSessionID == nil, !proofread.isRunning, notchInputReady,
              !DoubleTap.shared.isDrafting else { return false }
        #if DEBUG
        guard !run.preventsTaskExecutionForUIFixture else { return false }
        #endif
        guard !interceptForOnboarding() else { return false }
        if CodexAuth.knowledgeBaseOnly { flash(Self.needsPlusNotice, for: 2); return false }
        let context = screenActionContext(SidekickActionRequest.takeOverInstructions, source: source)
        pendingSingleTap?.cancel(); pendingSingleTap = nil; hotkeyPair.reset()
        proofread.clearPreparedSelection()
        return launch("Take over what I’m looking at.", mode: .computer, source: source,
                      takingOver: true, actionContext: context)
    }

    private func screenActionContext(_ instructions: String, source: TriggerSource) -> String {
        let origin = quickActionOrigin(for: source.rawValue)
        let metadata: [String: String] = ["application": origin.target?.name ?? "",
            "application_id": origin.target?.bundleIdentifier ?? "",
            "window_title": origin.target?.windowTitle ?? "",
            "display_id": origin.display.map { String($0) } ?? ""]
        let encoded = (try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return instructions + "\nOrigin (data): " + encoded
    }

    func refreshQuickActionShortcuts() {
        let enabled = quickActionsAvailable && !ShortcutPreferences.isRecording
        quickActionHotkeys.setEnabled(enabled)
        if !enabled { cancelQuickActionPreparation() }
        PhysicalNotchTap.shared.refresh()
    }

    /// A second physical tap means a tap while the input is open, not a timed double tap.
    @discardableResult
    func physicalScreenTapped() -> Bool {
        guard NotchPreferences.physicalTapEnabled(), NSApp.modalWindow == nil,
              !ShortcutPreferences.isRecording, !run.isClearingChat,
              !proofread.isRunning, !DoubleTap.shared.isDrafting, voiceSessionID == nil else { return false }
        if onboardingDemoArmed {
            guard onboardingPhysicalTapAvailable, phase == .hidden, !run.isRunning else { return false }
            notchAnchor = .builtInNotch
            beginNotchDemo(door: "physical screen tap")
            return phase == .typing
        }
        guard quickActionsAvailable else { return false }
        #if DEBUG
        guard !run.preventsTaskExecutionForUIFixture else { return false }
        #endif
        let tapTime = ProcessInfo.processInfo.systemUptime
        let cadence = tapTime-lastPhysicalTapTime
        physicalTapSpringResponse = cadence < 1.25 ? min(0.30,max(0.11,cadence*0.60)) : 0.52/1.35
        lastPhysicalTapTime = tapTime
        physicalTapTransition = true
        defer { physicalTapTransition = false }
        if run.recovery.isPending {
            if phase == .hidden { return run.recovery.reopen() }
            guard NotchPreferences.secondPhysicalTap() == .close else { return false }
            run.recovery.dismiss(); return true
        }
        if run.isRunning {
            if phase == .hidden { notchAnchor = .builtInNotch; setPhase(.running); return true }
            guard NotchPreferences.secondPhysicalTap() == .close else { return false }
            switch phase {
            case .running: setPhase(.hidden); return true
            case .message: dismissMessagePreview(); return true
            default: return false
            }
        }
        switch phase {
        case .hidden:
            guard !run.recovery.isPending else { return false }
            openNotchInput(anchor: .builtInNotch, door: "physical screen tap")
            return phase == .typing
        case .typing:
            switch NotchPreferences.secondPhysicalTap() {
            case .close: dismissTyping(); return true
            case .takeOver: return takeOver()
            case .magicReply: return magicReply()
            case .summarize: return summarizeScreen()
            case .proofread: return notchInputReady && proofreadSelection()
            }
        case .message:
            guard NotchPreferences.secondPhysicalTap() == .close else { return false }
            dismissMessagePreview(); return true
        default: return false // A tap never answers a question or submits dictation.
        }
    }

    func cancelQuickActionPreparation() {
        let hadPending = quickActionTask != nil
        quickActionID = nil; quickActionTask?.cancel(); quickActionTask = nil
        if hadPending, !proofread.isRunning { proofread.clearPreparedSelection() }
    }

    /// Global chords preserve the active app's focus and enter the same actions as the buttons.
    func handleQuickActionShortcut(_ action: QuickActionShortcut) {
        guard quickActionsAvailable, !ShortcutPreferences.isRecording, NSApp.modalWindow == nil,
              !run.isClearingChat, voiceSessionID == nil, !proofread.isRunning,
              !run.recovery.isPending, !DoubleTap.shared.isDrafting else { return }
        #if DEBUG
        guard !run.preventsTaskExecutionForUIFixture else { return }
        #endif
        cancelQuickActionPreparation()
        interruptHotkeyGesture()
        notchAnchor = .mainDisplay
        if action == .summarize {
            // The hidden notch's remembered display may belong to a previous interaction.
            if phase != .typing { summaryDisplayID = ScreenCapture.summaryDisplay(); summaryTarget = SummaryAccessibility.target() }
            _ = summarizeScreen()
            return
        }
        guard !run.isRunning else { return }
        let originalPhase = phase, activity = ShortcutActivity.current
        if phase != .typing { prepareProofreadSelection() }
        let id = UUID(); quickActionID = id
        quickActionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.quickActionID == id {
                    if !self.proofread.isRunning, originalPhase != .typing, self.phase == originalPhase {
                        self.proofread.clearPreparedSelection()
                    }
                    self.quickActionID = nil; self.quickActionTask = nil
                }
            }
            await self.proofread.waitForSelection()
            guard !Task.isCancelled, self.quickActionID == id, self.phase == originalPhase,
                  (activity == ShortcutActivity.current || self.proofread.selectionActivity == ShortcutActivity.current), !self.proofread.captureWasInterrupted else { return }
            _ = self.proofreadSelection()
        }
    }


    @discardableResult
    func proofreadSelection() -> Bool {
        guard quickActionsAvailable, !run.isRunning, !run.isClearingChat, voiceSessionID == nil,
              !DoubleTap.shared.isDrafting, !proofread.isRunning else { return false }
        #if DEBUG
        guard !run.preventsTaskExecutionForUIFixture else { return false }
        #endif
        pendingSingleTap?.cancel(); pendingSingleTap = nil; hotkeyPair.reset()
        clearReadBack()
        guard proofread.start(restoringFocus: phase == .typing || phase == .listening || phase == .transcribing, completion: { [weak self] caption in
            if caption.isEmpty { self?.setPhase(.hidden) }
            else { self?.flash(caption, for: caption == ProofreadSelection.Failure.noSelection.localizedDescription ? 1 : 3) } }) else { return false }
        setPhase(.notice("Proofreading…"))
        return true
    }

    private func prepareProofreadSelection(preservingHomeDraft token: UUID? = nil) {
        #if DEBUG
        guard !run.preventsTaskExecutionForUIFixture else { return }
        #endif
        if hasPreparedHomeDraft(token) || prepareHomeProofreadDraft() { return }
        proofread.prepareSelection()
    }

    /// Called on mouse-down, before AppKit/SwiftUI can resign Home's field editor.
    @discardableResult
    private func prepareHomeProofreadDraft() -> Bool {
        #if DEBUG
        guard !run.preventsTaskExecutionForUIFixture else { return false }
        #endif
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
           NSApp.keyWindow.map(SentientOSApp.isHomeWindow) == true,
           !run.recovery.isPending, !composerDictation.isActive {
            let conversation = run.conversation
            let original = conversation.draft
            let generation = conversation.generation
            let editor = NSApp.keyWindow?.firstResponder as? NSTextView
            let selected = editor?.string == original ? editor?.selectedRange() : nil
            let fullRange = NSRange(location: 0, length: original.utf16.count)
            let range = selected.flatMap { $0.location != NSNotFound && $0.length > 0 && NSMaxRange($0) <= fullRange.length ? $0 : nil } ?? fullRange
            let passage = (original as NSString).substring(with: range)
            proofread.prepareDraft(text: passage) { [weak self] corrected in
                guard let self, self.run.conversation.generation == generation,
                      self.run.conversation.draft == original, !self.run.isClearingChat,
                      !self.run.isRunning, !self.run.recovery.isPending,
                      !self.composerDictation.isActive else { return false }
                self.run.conversation.draft = (original as NSString).replacingCharacters(in: range, with: corrected)
                return true
            }
            return true
        }
        return false
    }

    private func hasPreparedHomeDraft(_ token: UUID?) -> Bool {
        token != nil && proofread.preparedDraftToken == token
    }

    private var summaryDisplayID: CGDirectDisplayID?
    private var summaryTarget: SummaryAccessibility.Target?
    func quickActionOrigin(for source: String) -> (target: SummaryAccessibility.Target?, display: CGDirectDisplayID?) {
        let fromNotch = source == TriggerSource.voice.rawValue || source == TriggerSource.notchTyped.rawValue
        let current = fromNotch ? (summaryTarget ?? SummaryAccessibility.target()) : SummaryAccessibility.target()
        return (current?.pid == getpid() ? nil : current, fromNotch ? summaryDisplayID : ScreenCapture.summaryDisplay())
    }
    var quickActionsAvailable: Bool { Self.hasCompletedOnboarding && !onboardingDemoArmed && !onboardingReplyLessonActive }

    @discardableResult
    func summarizeScreen(preference: String = "") -> Bool {
        guard quickActionsAvailable, !run.isClearingChat, voiceSessionID == nil else { return false }
        #if DEBUG
        guard !run.preventsTaskExecutionForUIFixture else { return false }
        #endif
        let target = summaryTarget ?? SummaryAccessibility.target()
        guard target?.pid != getpid() else {
            pendingSingleTap?.cancel(); pendingSingleTap = nil; hotkeyPair.reset()
            proofread.clearPreparedSelection()
            flash(SummaryAccessibility.Failure.ownApplication.localizedDescription, for: 1.8)
            return false
        }
        guard let display = summaryDisplayID ?? ScreenCapture.summaryDisplay() else {
            flash("No screen is available to summarize."); return false
        }
        pendingSingleTap?.cancel(); pendingSingleTap = nil; hotkeyPair.reset()
        proofread.clearPreparedSelection()
        if !run.isRunning { clearReadBack(); setPhase(.hidden) }
        summarize.start(displayID: display, preference: preference, target: target)
        return true
    }

    private var workWindowMessage: String?
    @ObservationIgnored private var workWindowFeedbackRunID: UUID?
    var workWindowFeedback: String? {
        run.isRunning && workWindowFeedbackRunID == run.runID ? workWindowMessage : nil
    }
    @ObservationIgnored private var workWindowRequest: Task<Void, Never>?

    var canShowWorkWindow: Bool { run.isRunning && run.activeWorkWindow != nil }

    func showWorkWindow() {
        guard run.isRunning, let target = run.activeWorkWindow else { return }
        workWindowRequest?.cancel()
        workWindowMessage = nil
        let generation = run.runID
        workWindowFeedbackRunID = generation
        workWindowRequest = Task { [weak self] in
            do { try await target.reveal() }
            catch is CancellationError { return }
            catch {
                guard let self, !Task.isCancelled, self.run.runID == generation, self.run.isRunning else { return }
                self.workWindowMessage = (error as? LocalizedError)?.errorDescription ?? "That work window is unavailable."
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled else { return }
                self.workWindowMessage = nil
            }
        }
    }

    /// What the notch shows. (Rendering lands later; today this is driven + logged.)
    private(set) var phase: NotchPhase = .hidden
    /// Retain the transition's speed until the next phase so the view and panel teardown agree.
    private(set) var notchAnimationSpeed = 1.0
    private(set) var notchDismissalPreview = false
    @ObservationIgnored private var dismissalPreviewTask: Task<Void, Never>?
    @ObservationIgnored private var pointerDismissal = false
    private(set) var notchPhysicalSpringResponse: Double?
    @ObservationIgnored private var physicalTapSpringResponse = 0.52/1.35
    @ObservationIgnored private var lastPhysicalTapTime = -Double.infinity
    @ObservationIgnored private var physicalTapTransition = false
    /// Unsent notch input is independent of Home; submitted requests share `run`.
    var notchDraft = ""
    var homeWindowFocused = false {
        didSet {
            // Home has already presented this completion. Do not let its hidden
            // toast reappear when the next click or dictation moves focus away.
            if homeWindowFocused, case .finishing = phase { setPhase(.hidden) }
        }
    }
    var displayedNotchPhase: NotchPhase { phase.displayed(homeFocused: homeWindowFocused) }
    enum SetupCaption: String {
        case sidekick = "Set up Sidekick"
        case computerUse = "Set up computer use"
    }

    /// Presentation follows the visible permission UI, independent of agent progress.
    var setupCaption: SetupCaption? {
        guard phase == .running, run.isRunning, !run.isDemo else { return nil }
        if NativeHelperPermissionNote.visibility.isVisible { return .computerUse }
        let gate = ComputerUseGate.shared
        if gate.isPresenting, !gate.showingVoiceRepair, !gate.isReadyForTask { return .sidekick }
        return nil
    }
    private(set) var notchMessage: SidekickConversationStore.Record?
    private(set) var messageReplyFocused = false
    private var attentionPolicy = SidekickAttentionPolicy(generation: nil, latestSequence: 0)
    private var messageTimer: Task<Void, Never>?

    /// The spoken text, echoed for 0.5–2.5s (scaled to its length) after a voice launch so a mishear can be caught. The notch shows
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
    private(set) var notchFocusRequest = 0

    /// The current lesson admits a physical tap or fallback only while ready. It
    /// demonstrates an action on the real notch, then advances an inert film or sample.
    /// Dismissal re-arms the invitation; leaving the owning view cancels the lesson.
    private(set) var onboardingDemoArmed = false
    private var onboardingDemoFired: (() -> Void)?
    private var demoTask: Task<Void, Never>?
    private var demoAnimationID: UUID?
    private weak var onboardingDemoWindow: NSWindow?
    private var onboardingDemoOwnerID: UUID?
    private(set) var onboardingDemoAction: OnboardingNotchAction = .takeOver
    private var onboardingReplyLessonActive: Bool {
        onboardingDemoOwnerID != nil && onboardingDemoAction == .magicReply
    }
    private(set) var onboardingActionCue: OnboardingActionCue = .idle

    /// Only the visible film invitation temporarily admits sensor input before setup.
    var onboardingPhysicalTapAvailable: Bool {
        onboardingDemoArmed && NSApp.isActive && onboardingDemoWindow?.isVisible == true
            && onboardingDemoWindow?.isKeyWindow == true
            && onboardingDemoWindow?.isMiniaturized == false
            && NotchWindowController.builtInNotchScreen() != nil
    }

    private let hotkey = SidekickHotkeyMonitor()
    private let voice = VoiceCapture()
    private var hotkeyChangeObserver: NSObjectProtocol?

    let dictation = DictationPresentation()
    let composerDictation = ComposerDictation()
    let notchPress = NotchPressGesture()
    private var voiceSessionID: UUID?
    private var hotkeyVoiceSessionID: UUID?
    private var voiceFinalizeTask: Task<Void, Never>?
    private var voiceLimitTask: Task<Void, Never>?
    private var voiceStartTask: Task<Void, Never>?
    private var phaseToken = 0              // guards delayed phase transitions against newer ones
    private var readBackToken = 0
    private var hotkeyPair = ShortcutTapPair()
    private var pendingSingleTap: Task<Void, Never>?
    private var returningFromRecovery = false
    private var deferredSubmission: (String, AgentMode, TriggerSource)?

    init() {
        attentionPolicy = SidekickAttentionPolicy(generation: run.conversation.generation,
            latestSequence: (try? run.conversation.store?.latestSequence) ?? 0)
        run.conversation.onRefresh = { [weak self] in self?.routeAttention() }
        run.onFinished = { [weak self] outcome in self?.runFinished(outcome) }
        run.onRecoveryResumed = { [weak self] in self?.setPhase(.running) }
        run.makeQuickActions = { [weak self] source in
            guard let self else {
                return SidekickQuickActions(summarize: { _,_ in throw SidekickQuickActionTools.Failure.unavailable },
                                            proofread: { _ in throw SidekickQuickActionTools.Failure.unavailable })
            }
            return self.quickActions(for:source)
        }
        run.recovery.onChange = { [weak self] in
            guard let self else { return }
            if self.run.recovery.isPending {
                if self.run.conversation.isVisible, self.run.recovery.isVisible {
                    self.run.recovery.dismiss()
                    return
                }
                self.clearReadBack()
                self.setPhase(self.run.recovery.isVisible ? .recovery : .hidden)
            } else if self.phase == .recovery { self.setPhase(.hidden) }
        }
    }

    func backFromRecovery() {
        guard run.recovery.isPending else { return }
        run.stop()
        returningFromRecovery = run.isRunning
        deferredSubmission = nil
        clearReadBack(); setPhase(.typing)
    }

    // MARK: Lifecycle

    /// Arm the hotkey + warm the speech model + wire run-completion. Idempotent.
    /// (TODO: production should arm only after onboarding completes — kept always-on for now so the
    /// backend is testable immediately.)
    func start() {
        guard hotkeyChangeObserver == nil else { return }
        hotkey.onTap = { [weak self] key, time, activity in
            self?.hotkeyTapped(key, at: time, activity: activity)
        }
        hotkey.onInterruption = { [weak self] in self?.interruptHotkeyGesture() }
        hotkey.onHold = { [weak self] key in self?.beginHotkeyDictation(key) ?? false }
        hotkey.onHoldEnd = { [weak self] _, send in self?.endHotkeyDictation(send: send) }
        quickActionHotkeys.onAction = { [weak self] action in self?.handleQuickActionShortcut(action) }
        refreshHotkeys()
        hotkey.start()
        quickActionHotkeys.start()
        #if DEBUG
        let armPhysicalTap = ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == nil
        #else
        let armPhysicalTap = true
        #endif
        if armPhysicalTap {
            PhysicalNotchTap.shared.start(allowed: { [weak self] in self?.quickActionsAvailable == true || self?.onboardingPhysicalTapAvailable == true },
                                         onTap: { [weak self] in _ = self?.physicalScreenTapped() })
        }
        hotkeyChangeObserver = NotificationCenter.default.addObserver(
            forName: .shortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHotkeys() }
        }
        run.onFinished = { [weak self] outcome in self?.runFinished(outcome) }
        Log("CommandCoordinator armed (shared Sidekick and Double Tap key · voice available: \(VoiceCapture.isAvailable))")
    }

    // MARK: The one entry point — hotkey-voice AND the prompt bar both call this

    func showSubmissionFailure(_ error: Error) {
        flash((error as? LocalizedError)?.errorDescription ?? "Sidekick couldn’t open this request. Your draft has been kept.", for: 4)
    }

    @discardableResult
    func submit(_ text: String, mode: AgentMode, source: TriggerSource,
                reply: SidekickConversationEvent.ReplyReference? = nil,
                onCompletion: ((CommandRunModel.Outcome) -> Void)? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !run.isRunning, !run.isClearingChat, !proofread.isRunning,
              !DoubleTap.shared.isDrafting, voiceSessionID == nil else { return false }
        returningFromRecovery = false
        // A rejected submission must preserve the draft and pending recovery.
        if interceptForOnboarding() { return false }
        if (source == .voice || source == .notchTyped), reply == nil, run.conversation.replyReference == nil {
            if let preference = SidekickActionRequest.magicReplyPreference(trimmed) {
                return magicReply(source: source, preference: preference)
            }
            if SidekickActionRequest.isTakeOver(trimmed) { return takeOver(source: source) }
        }
        if (source == .voice || source == .notchTyped), reply == nil,
           run.conversation.replyReference == nil, ProofreadRequest.matches(trimmed) {
            return proofreadSelection()
        }
        if (source == .voice || source == .notchTyped), reply == nil,
           run.conversation.replyReference == nil, let preference = SummaryRequest.match(trimmed) {
            return summarizeScreen(preference: preference)
        }
        if CodexAuth.knowledgeBaseOnly {
            flash(Self.needsPlusNotice, for: 2.0)
            return false
        }
        if source == .promptBar || source == .proactiveCard { notchAnchor = .mainDisplay }
        proofread.clearPreparedSelection()
        return launch(trimmed, mode: mode, source: source, reply: reply ?? run.conversation.replyReference,
                      onCompletion: onCompletion)
    }

    /// Own the run immediately. Permission/setup waiting happens inside its cancellable task,
    /// so the notch stays visible and every other entry point sees the same one-task lock.
    private func launch(_ trimmed: String, mode: AgentMode, source: TriggerSource,
                        takingOver: Bool = false,
                        actionContext: String = "",
                        reply: SidekickConversationEvent.ReplyReference? = nil,
                        onCompletion: ((CommandRunModel.Outcome) -> Void)? = nil) -> Bool {
        guard !run.isRunning, !run.isClearingChat, !proofread.isRunning, voiceSessionID == nil else { return false }
        if source == .voice { setReadBack(trimmed) } else { clearReadBack() }
        // Core tier: THE Sidekick-usage count (count only, never the text) — one of the handful of
        // always-on telemetry signals disclosed in Settings.
        Analytics.signal("Command.submitted", parameters: ["source": source.rawValue, "mode": mode.label], tier: .core)
        let preflight: (@MainActor () async throws -> Void)? = reply?.card.map { card in
            { try await SidekickCardContext.validate(card) }
        }
        run.start(trimmed, mode: mode, source: source.rawValue, takingOver: takingOver, actionContext: actionContext, reply: reply,
                  preflight: preflight, onCompletion: { outcome in
            if let card = reply?.card { SidekickCardContext.finish(card, succeeded: outcome == .success) }
            onCompletion?(outcome)
        })
        guard run.isRunning else { setPhase(.running); runFinished(.failed); return false }
        if source == .voice || source == .notchTyped { SidekickDiscovery.recordNotchUse() }
        run.conversation.replyReference = nil
        InviteProgram.shared.record(.sidekick)
        // Every command is computer use, which raises the notch.
        setPhase(.running)
        Log("▶︎ submit [\(source)] \(mode.label) (\(trimmed.count) chars)")   // B7: length, not the command text
        #if DEBUG
        Log("   cmd ↓ \(trimmed)")
        #endif
        return true
    }

    /// Cancel the running task. A STOP (or Esc) WHILE THE TRANSCRIPT IS SHOWN means "you misheard me — redo":
    /// dismiss INSTANTLY with no "Stopped" flourish (hiding first makes `runFinished` skip it). Once computer
    /// use is actually working, STOP halts it with the honest "Stopped" beat. Either way the run is cancelled
    /// (an adopted card fire included — run.stop() routes to the card's own cancel). Reached from the
    /// notch's and the bar's STOP buttons and from Esc at the transcript beat; never from the hotkey.
    func stop() {
        cancelQuickActionPreparation()
        if DoubleTap.shared.isDrafting { DoubleTap.shared.cancel() }
        if proofread.isRunning { proofread.cancel(); return }
        if returningFromRecovery {
            deferredSubmission = nil
            setPhase(.hidden)
        }
        if phase == .running, readBack != nil, run.remembering == nil && !run.isPersonalizing { setPhase(.hidden) }
        run.stop()
    }

    /// Clear only the conversation. Cancel input that has not become a run yet, then let
    /// the run owner stop/drain and atomically reset history before admitting another task.
    func clearChat(defaults: UserDefaults = .standard) async throws {
        guard !run.isClearingChat else { throw CommandRunModel.ClearChatFailure.busy }
        deferredSubmission = nil; returningFromRecovery = false
        hotkeyPair.reset()
        cancelDictation()
        cancelOnboardingActionAnimation()
        clearReadBack()
        setPhase(.hidden) // also invalidates delayed voice/opening/finishing callbacks
        try await run.clearChat(defaults: defaults)
        notchDraft = ""
        clearReadBack()
        setPhase(.hidden)
    }

    // MARK: Adopted external runs (a proactive card's fire — any channel)

    /// A proactive card's fire (computer, gmail, or calendar) adopting the notch: the run model lights up — locking
    /// out every other entry point — and the notch rises in `.running`, exactly like a command-bar
    /// launch. Returns false when a task already owns the run (the ONE-task-at-a-time lock): the
    /// caller must not fire. Doubles as the gate-held re-check — a fire the permission gate held
    /// for minutes re-answers the lock here. Completion needs no coordinator API: the card's
    /// completeExternal rides onFinished → runFinished → the normal finishing flourish.
    @discardableResult
    func beginExternalRun(caption: String, request: String? = nil, retryContext: String = "", onRetry: ((String) -> Void)? = nil,
                          onStopRequest: @escaping @MainActor () -> Void) -> Bool {
        guard !run.isRunning, !run.isClearingChat, !proofread.isRunning, voiceSessionID == nil else { return false }
        clearReadBack()
        notchAnchor = .mainDisplay        // card fires live on the home's display, like the prompt bar
        run.adoptExternal(caption: caption, request: request, retryContext: retryContext, onRetry: onRetry, onStopRequest: onStopRequest)
        guard run.isRunning else { setPhase(.running); runFinished(.failed); return false }
        setPhase(.running)
        Log("▶︎ external run adopted (\(caption))")
        return true
    }

    // MARK: The hotkey path (tap → type · hold → voice · double tap → a reply draft)
    //
    // A completed tap reveals a non-key notch. A second tap within the gesture window
    // drafts into the original app; otherwise the notch becomes the focused type field.
    // Double Tap remains available during a real task without changing its notch or task lock.

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
        guard NotchPreferences.clickEnabled() else { return false }
        guard !DoubleTap.shared.isDrafting else { return false }
        guard !onboardingReplyLessonActive || onboardingDemoArmed else { return false }
        return Self.hasCompletedOnboarding || onboardingDemoArmed
            || UserDefaults.standard.bool(forKey: Self.notchDemoPlayedKey)
    }

    /// True = the press was consumed by the onboarding policy (silence, or the aside). The
    /// armed demo never reaches here — both its doors (the notch click, the hotkey press)
    /// answer before their intercept.
    private func interceptForOnboarding() -> Bool {
        guard !Self.hasCompletedOnboarding else { return false }
        if UserDefaults.standard.bool(forKey: Self.notchDemoPlayedKey) {
            flash(Self.finishOnboardingNotice, for: 2.0)
            Log("sidekick press during onboarding — the finish-onboarding aside")
        } else {
            Log("sidekick press during onboarding — silent (pre notch beat)")
        }
        return true
    }

    private func refreshHotkeys() {
        interruptHotkeyGesture()
        let keys: Set<ShortcutKey>
        if ShortcutPreferences.isRecording {
            keys = []
        } else {
            keys = [ShortcutPreferences.current]
        }
        hotkey.setKeys(keys)
        refreshQuickActionShortcuts()
    }

    private func interruptHotkeyGesture() {
        endHotkeyDictation(send: false)
        pendingSingleTap?.cancel(); pendingSingleTap = nil
        hotkeyPair.reset()
        if phase == .opening { proofread.clearPreparedSelection(); setPhase(.hidden) }
    }

    /// Completed standalone taps arrive here. Both actions use the same key; the first
    /// tap waits for a possible second tap before Sidekick can take focus.
    private func hotkeyTapped(_ key: ShortcutKey, at time: TimeInterval, activity: ShortcutActivity) {
        guard !run.isClearingChat else { return }
        guard !ShortcutPreferences.isRecording, (!onboardingReplyLessonActive || onboardingDemoArmed),
              !DoubleTap.shared.isDrafting else { return }
        guard key == ShortcutPreferences.current else { return }
        if proofread.isRunning { proofread.cancel(); return }
        if run.recovery.isPending, DoubleTap.isReady {
            handleSingleTap(activity: activity, waitForDoubleTap: false)
            return
        }
        if onboardingDemoArmed, phase == .hidden, !run.isRunning {
            hotkeyPair.reset()
            notchAnchor = .mainDisplay
            beginNotchDemo(door: "hotkey tap")
            return
        }
        if DoubleTap.isEnabled {
            if hotkeyPair.register(key, at: time, activity: activity, window: DoubleTap.window,
                                   lastInputTime: ShortcutActivity.lastInputTime) {
                pendingSingleTap?.cancel(); pendingSingleTap = nil
                guard !interceptForOnboarding() else { return }
                fireDoubleTap()
                return
            }
        } else {
            hotkeyPair.reset()
        }
        pendingSingleTap?.cancel(); pendingSingleTap = nil
        if DoubleTap.isEnabled && !DoubleTap.isReady {
            // Wait before any notch reveal or setup check. Two early taps show cursor feedback;
            // one still opens Sidekick after the same gesture window as a completed install.
            let token = phaseToken
            pendingSingleTap = Task { [weak self] in
                try? await Task.sleep(for: .seconds(DoubleTap.window))
                guard !Task.isCancelled, let self, self.phaseToken == token,
                      ShortcutActivity.current == activity else { return }
                self.pendingSingleTap = nil
                self.handleSingleTap(activity: activity, waitForDoubleTap: false)
            }
            return
        }
        handleSingleTap(activity: activity, waitForDoubleTap: DoubleTap.isEnabled)
    }

    private func handleSingleTap(activity: ShortcutActivity, waitForDoubleTap: Bool) {
        guard !run.isClearingChat else { return }
        if run.recovery.isPending {
            hotkeyPair.reset()
            if run.recovery.isVisible { run.recovery.dismiss() }
            else { run.recovery.reopen() }
            return
        }
        // A single tap cannot stop a real task. Double Tap remains available beside that task.
        guard !run.isRunning else { return }
        switch phase {
        case .typing:
            dismissTyping()
            return
        case .listening, .transcribing:
            cancelCurrent()
            return
        default:
            break
        }
        notchAnchor = .mainDisplay
        guard !interceptForOnboarding() else { hotkeyPair.reset(); return }
        summaryDisplayID = ScreenCapture.summaryDisplay(); summaryTarget = SummaryAccessibility.target()
        prepareProofreadSelection()
        ComputerUseGate.shared.refresh()
        guard waitForDoubleTap else {
            setPhase(.typing)
            return
        }
        setPhase(.opening)
        let token = phaseToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(DoubleTap.window))
            guard let self, self.phaseToken == token, self.phase == .opening else { return }
            // Typing or clicking during the pending gesture must not steal focus afterwards.
            guard ShortcutActivity.current == activity || self.proofread.selectionActivity == ShortcutActivity.current else {
                self.interruptHotkeyGesture()
                return
            }
            self.setPhase(.typing)
        }
    }

    // MARK: Dictation (shortcut/notch hold and the field's microphone)

    private func beginHotkeyDictation(_ key: ShortcutKey) -> Bool {
        guard key == ShortcutPreferences.current, !ShortcutPreferences.isRecording,
              !onboardingReplyLessonActive, !onboardingDemoArmed, Self.hasCompletedOnboarding else { return false }
        interruptHotkeyGesture()
        guard phase == .hidden || phase == .typing || phase == .message else { return false }
        notchAnchor = .mainDisplay
        guard beginDictation() else { return false }
        hotkeyVoiceSessionID = voiceSessionID
        return true
    }

    private func endHotkeyDictation(send: Bool) {
        guard let id = hotkeyVoiceSessionID else { return }
        hotkeyVoiceSessionID = nil
        guard voiceSessionID == id, phase == .listening else { return }
        if send { finishListening() }
        else { cancelCurrent() }
    }

    /// A physical hold enters directly without opening a typing field or changing hotkeys.
    @discardableResult
    func beginNotchDictation(anchor: NotchAnchor = .builtInNotch, preparedHomeDraft: UUID? = nil) -> Bool {
        guard notchButtonAvailable, (phase == .hidden || phase == .typing || phase == .message),
              (!run.isRunning || (phase == .message && run.hasDeliveredFinalAnswer)), !run.isClearingChat,
              !run.recovery.isPending, !onboardingDemoArmed, Self.hasCompletedOnboarding else { return false }
        notchAnchor = anchor
        return beginDictation(preparedHomeDraft: preparedHomeDraft)
    }

    func notchMouseDown(anchor: NotchAnchor = .builtInNotch) {
        guard !notchPress.isTracking else { return }
        let homeDraft = phase == .hidden && prepareHomeProofreadDraft() ? proofread.preparedDraftToken : nil
        notchPress.begin(tap: { [weak self] in self?.notchClicked(anchor: anchor, preparedHomeDraft: homeDraft) },
            hold: { [weak self] in self?.beginNotchDictation(anchor: anchor, preparedHomeDraft: homeDraft) ?? false },
            release: { [weak self] in self?.finishListening() },
            releaseAway: { [weak self] in self?.finishListening(send: false) })
    }

    func microphoneMouseDown() {
        // The mic itself is explicit voice intent: reveal dictation on mouse-down. A quick
        // click latches recording; holding uses the same release-to-send behavior as the notch.
        guard (phase == .typing || phase == .message), beginDictation(), let id = voiceSessionID else { return }
        notchPress.begin(tap: {},
            hold: { [weak self] in
                guard let self else { return false }
                return self.voiceSessionID == id && self.phase == .listening
            }, release: { [weak self] in
                guard let self, self.voiceSessionID == id else { return }
                self.finishListening()
            }, releaseAway: { [weak self] in
                guard let self, self.voiceSessionID == id else { return }
                self.finishListening(send: false)
            }, cancelOnEarlyDrag: false)
    }

    func startListening() {
        guard phase == .typing || phase == .message else { return }
        _ = beginDictation()
    }

    private func beginDictation(preparedHomeDraft: UUID? = nil) -> Bool {
        composerDictation.cancel()
        guard (!run.isRunning || (phase == .message && run.hasDeliveredFinalAnswer)),
              !run.isClearingChat, !run.recovery.isPending, !proofread.isRunning, !DoubleTap.shared.isDrafting,
              !onboardingDemoArmed, voiceSessionID == nil else { return false }
        guard !interceptForOnboarding() else { return false }
        if phase != .typing {
            summaryDisplayID = ScreenCapture.summaryDisplay(); summaryTarget = SummaryAccessibility.target()
            prepareProofreadSelection(preservingHomeDraft: preparedHomeDraft)
        }
        if !VoiceCapture.isAuthorized, ComputerUseGate.shared.presentVoiceFixIfDenied() { return false }
        let id = UUID(); voiceSessionID = id
        let reply = phase == .message ? notchMessage : nil
        if let reply {
            prepareMessageReply(nil, messageID: reply.event.id)
            messageTimer?.cancel(); messageTimer = nil
        }
        let context: DictationPresentation.Context = reply.map { .reply($0) }
            ?? (phase == .typing ? .composer : .activity)
        dictation.reset(context: context, baseDraft: phase == .typing || reply != nil ? notchDraft : "")
        setPhase(.listening)
        voice.onTranscript = { [weak self] text in
            guard let self, self.voiceSessionID == id else { return }
            self.dictation.text = text
        }
        voice.onLevel = { [weak self] level in
            guard let self, self.voiceSessionID == id, self.phase == .listening else { return }
            self.dictation.push(level)
        }
        voice.onReady = { [weak self] in
            guard let self, self.voiceSessionID == id else { return }
            self.dictation.connected = true
        }
        voice.onFailure = { [weak self] error in
            guard let self, self.voiceSessionID == id else { return }
            self.dictationFailed(error, id: id)
        }
        voiceStartTask = Task { [weak self] in
            guard let self, self.voiceSessionID == id, self.phase == .listening else { return }
            do {
                await self.proofread.waitForSelection()
                guard self.voiceSessionID == id, self.phase == .listening else { return }
                try await self.voice.start()
                guard self.voiceSessionID == id, self.phase == .listening else { return }
                self.dictation.capturing = true
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            } catch {
                guard self.voiceSessionID == id else { return }
                if error is CancellationError { self.cancelDictation(); self.setPhase(.hidden) }
                else { self.dictationFailed(error, id: id) }
            }
        }
        voiceLimitTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(VoiceCapture.maxCaptureDuration)) } catch { return }
            guard let self, self.voiceSessionID == id, self.phase == .listening else { return }
            self.finalizeVoice(send: false)
        }
        return true
    }

    @discardableResult
    func finishListening(send: Bool = true) -> Bool {
        guard phase == .listening, voiceSessionID != nil else { return false }
        // A release during first-use permission setup has no audio to finalize. Permission
        // may finish in its own dialog, but this gesture must never open the mic afterwards.
        if !dictation.capturing {
            let reply = dictation.replyMessage
            voice.stopCapturing()
            cancelDictation()
            if let reply { restoreDictationEditor(reply: reply) }
            else { setPhase(.hidden) }
            return true
        }
        finalizeVoice(send: send)
        return true
    }

    // MARK: Double Tap (DoubleTap.swift)

    /// The second press landed: draft the reply or explain missing setup at the cursor. Double Tap never shows on the notch and
    /// never takes the one-task lock, so it runs beside computer use and beside whatever the notch
    /// is doing; drafting ends with the paste (or nothing), and the log and Dev Tools' timing
    /// readout carry failures. From `.opening` (the idle path, where the first press already passed
    /// the onboarding, plan, and permission doors) the reveal retracts first; from a running task
    /// the notch is left exactly as it was.
    private func fireDoubleTap() {
        proofread.clearPreparedSelection()
        hotkeyPair.reset()
        // Never paste into the Sidekick field or disturb an active voice capture.
        guard phase != .typing, phase != .listening, phase != .transcribing else { return }
        if phase == .opening { setPhase(.hidden) }
        Log("⌘⌘ double tap → checking readiness" + (run.isRunning ? " (beside the running task)" : ""))
        DoubleTap.shared.start { result in
            switch result {
            case .pasted:          Log("⌘⌘ reply pasted")
            case .notAMessage:     Log("⌘⌘ not a reply box — nothing pasted")
            case .stopped:         Log("⌘⌘ draft stopped")
            case .failed(let why): Log("⌘⌘ draft failed: \(why)")
            }
        }
    }

    private func finalizeVoice(send: Bool) {
        guard let id = voiceSessionID, phase == .listening else { return }
        // This must precede every await, animation or network operation.
        voice.stopCapturing()
        dictation.capturing = false
        dictation.finalizing = true
        voiceLimitTask?.cancel(); voiceLimitTask = nil
        setPhase(.transcribing)
        voiceFinalizeTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                guard let self, self.voiceSessionID == id else { return }
                self.dictationFailed(DictationFailure.timedOut, id: id)
            }
            defer { deadline.cancel() }
            await self.voiceStartTask?.value
            guard self.voiceSessionID == id else { return }
            do {
                let text = try await self.voice.stopAndTranscribe()
                guard self.voiceSessionID == id else { return }
                let reply = self.dictation.replyMessage
                let keepsDraft = self.dictation.keepsDraft
                let request = self.dictation.composedText(text)
                // A final answer can appear before its provider finishes cleanup. Capture
                // may begin immediately, but never launch overlapping agent executions.
                if send && self.run.hasDeliveredFinalAnswer {
                    let drainingRun = self.run.runID
                    for _ in 0..<100 {
                        guard self.run.isRunning, self.run.runID == drainingRun else { break }
                        try await Task.sleep(for: .milliseconds(20))
                        guard self.voiceSessionID == id else { return }
                    }
                }
                self.voiceSessionID = nil
                self.dictation.finalizing = false
                self.voiceStartTask = nil; self.voiceFinalizeTask = nil
                if !send || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.notchDraft = request
                    self.restoreDictationEditor(reply: reply)
                } else if !self.submit(request, mode: .computer, source: .voice) {
                    self.notchDraft = request
                    self.dictation.error = "Your spoken request has been kept. Send it when you’re ready."
                    self.restoreDictationEditor(reply: reply)
                } else if keepsDraft {
                    self.notchDraft = ""
                }
            } catch {
                guard self.voiceSessionID == id else { return }
                self.dictationFailed(error, id: id)
            }
        }
    }

    private func restoreDictationEditor(reply: SidekickConversationStore.Record?) {
        if let reply {
            notchMessage = reply
            setPhase(.message)
            // Keep the recovered transcript on screen while the user edits it.
            setMessageReplyFocused(true, messageID: reply.event.id)
        } else {
            setPhase(.typing)
        }
    }

    private func keepDictationDraft(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let existing = notchDraft
        notchDraft = existing.isEmpty ? text : existing + "\n" + text
    }

    private func dictationFailed(_ error: Error, id: UUID) {
        guard voiceSessionID == id else { return }
        let reply = dictation.replyMessage
        keepDictationDraft(dictation.text)
        let message: String
        if let failure = error as? DictationFailure { message = failure.localizedDescription }
        else if let failure = error as? VoiceError { message = failure.localizedDescription }
        else { message = "Dictation isn’t available right now. Your available text has been kept." }
        cancelDictation()
        dictation.error = message
        restoreDictationEditor(reply: reply)
        Log("dictation failed (available text retained)")
    }

    private func cancelDictation() {
        proofread.clearPreparedSelection()
        voiceSessionID = nil
        notchPress.cancel()
        voiceStartTask?.cancel(); voiceStartTask = nil
        voiceFinalizeTask?.cancel(); voiceFinalizeTask = nil
        voiceLimitTask?.cancel(); voiceLimitTask = nil
        voice.cancel()
        dictation.capturing = false
        dictation.finalizing = false
    }

    // MARK: Tap-to-type (the notch's text field)

    /// ⏎ from the notch field — fire it as a computer-use task (empty just closes).
    @discardableResult
    func submitTyped(_ text: String) -> Bool {
        guard !run.isClearingChat else { return false }
        guard phase == .typing else { return false }
        // While the onboarding demo owns the field, a stray user ⏎ must never reach the real
        // submit path (the script fires the demo itself).
        guard !onboardingDemoArmed else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return submit(trimmed, mode: .computer, source: .notchTyped)   // typed → no read-back
    }

    /// Inline replies use the same task gate and exact message reference as Home.
    /// Rejected submissions keep both the text and reference for the user to edit.
    @discardableResult
    func submitMessageReply(_ text: String, messageID: String) -> Bool {
        guard phase == .message, notchMessage?.event.id == messageID,
              !run.isRunning, !run.isClearingChat else { return false }
        let existing = run.conversation.replyReference
        let reference = existing?.messageID == messageID ? existing : .init(messageID: messageID)
        guard submit(text, mode: .computer, source: .notchTyped, reply: reference) else { return false }
        notchDraft = ""
        dismissMessagePreview()
        return true
    }

    func prepareMessageReply(_ quote: String?, messageID: String) {
        guard phase == .message, let message = notchMessage, message.event.id == messageID,
              quote.map({ !$0.isEmpty && message.event.text.contains($0) }) ?? true else { return }
        run.conversation.replyReference = .init(messageID: messageID, selectedText: quote)
    }

    func setMessageReplyFocused(_ focused: Bool, messageID: String) {
        guard phase == .message, notchMessage?.event.id == messageID else { return }
        messageReplyFocused = focused
        if focused, run.conversation.replyReference?.messageID != messageID {
            prepareMessageReply(nil, messageID: messageID)
        }
        let editing = focused || !notchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if attentionPolicy.setEditing(editing) { messageInteractionChanged() }
    }

    /// Leave a brief visual invitation after a pointer dismissal, without keeping
    /// the input field active or delaying a subsequent physical tap.
    func dismissTypingFromPointer() {
        pointerDismissal = true
        defer { pointerDismissal = false }
        dismissTyping()
    }

    /// Esc · click-away · empty-⏎ — close the type field with no action.
    func dismissTyping() {
        guard phase == .typing else { return }
        cancelQuickActionPreparation()
        proofread.clearPreparedSelection()
        deferredSubmission = nil
        setPhase(.hidden)
        Log("notch typing dismissed")
    }

    // MARK: The notch as a button (the hover affordance)

    /// NotchWindowController's seam for the hover state (it owns the cursor geometry; the view
    /// renders the swell + shadow off this).
    func setNotchHovering(_ hovering: Bool, anchor: NotchAnchor? = nil) {
        if hovering, let anchor { notchAnchor = anchor }
        guard notchHovering != hovering else { return }
        notchHovering = hovering
    }

    /// A click on the idle, hover-swollen notch — the pointer's twin of a hotkey TAP: open the
    /// type field. Mirrors hotkeyTapped's doors without the double-tap wait (a click can only mean
    /// the field): the knowledge-base-only aside, then the field. Permissions are checked when
    /// submitting. The window controller makes the panel key on .typing, same as the hotkey path.
    func notchClicked(anchor: NotchAnchor = .builtInNotch, preparedHomeDraft: UUID? = nil) {
        guard NotchPreferences.clickEnabled() else { return }
        // The physical lesson is answered by a finger; the keyboard remains accessible.
        if onboardingPhysicalTapAvailable, PhysicalNotchTap.shared.status == .ready { return }
        openNotchInput(anchor: anchor, door: "notch click", preparedHomeDraft: preparedHomeDraft)
    }

    /// An explicit Home action is available even when idle notch clicks pass to other apps.
    /// It opens the same field as the shortcut without changing that preference.
    func openNotchFromHome() {
        openNotchInput(anchor: .mainDisplay, door: "Home hint")
    }

    private func openNotchInput(anchor: NotchAnchor, door: String, preparedHomeDraft: UUID? = nil) {
        guard !run.isClearingChat, !onboardingReplyLessonActive || onboardingDemoArmed else { return }
        // One draft/question/reader can move between entry points without being recreated.
        if phase == .typing || phase == .message || run.recovery.isPending {
            notchAnchor = anchor
            notchFocusRequest &+= 1
            if run.recovery.isPending { _ = run.recovery.reopen() }
            return
        }
        guard phase == .hidden, !run.isRunning, !DoubleTap.shared.isDrafting else { return }
        notchAnchor = anchor
        if onboardingDemoArmed { beginNotchDemo(door: door); return }
        // Before home: silence pre-beat (the swell is off then anyway), the aside after.
        if interceptForOnboarding() { return }
        summaryDisplayID = ScreenCapture.summaryDisplay(); summaryTarget = SummaryAccessibility.target()
        prepareProofreadSelection(preservingHomeDraft: preparedHomeDraft)
        setPhase(.typing)
        Log("\(door) → typing")
        #if DEBUG
        // Native UI fixtures may open the real field without starting helper health probes.
        guard !run.preventsTaskExecutionForUIFixture else { return }
        #endif
        ComputerUseGate.shared.refresh()   // background preparation never holds the input field
    }

    // MARK: The onboarding notch action demonstrations

    /// A lesson waits for a physical tap or fallback to open the real notch.
    /// The action-row cue is presentation only; it never invokes a quick-action handler.
    func armOnboardingNotchDemo(id: UUID = UUID(), in window: NSWindow? = nil,
                                action: OnboardingNotchAction = .takeOver, ready: Bool = true,
                                onFired: @escaping () -> Void) {
        cancelOnboardingActionAnimation()
        onboardingDemoOwnerID = id
        onboardingDemoAction = action
        onboardingDemoWindow = window
        onboardingDemoArmed = ready
        onboardingDemoFired = onFired
        PhysicalNotchTap.shared.refresh()
        Log("onboarding notch demo ARMED")
    }

    /// A reply lesson retains its window/owner while showing its draft, but admits taps only
    /// once the email has settled. An old view cannot pause or disarm a newer lesson.
    func setOnboardingNotchDemoReady(_ ready: Bool, id: UUID) {
        guard onboardingDemoOwnerID == id, onboardingDemoAction == .magicReply else { return }
        if !ready {
            cancelOnboardingActionAnimation()
            if phase == .typing { setPhase(.hidden) }
        }
        onboardingDemoArmed = ready
        PhysicalNotchTap.shared.refresh()
    }

    func disarmOnboardingNotchDemo(id: UUID? = nil) {
        if let id, onboardingDemoOwnerID != id { return }
        if run.isDemo && run.isRunning { run.stop() }
        let wasPresenting = onboardingDemoArmed && phase == .typing
        onboardingDemoArmed = false
        onboardingDemoOwnerID = nil
        onboardingDemoFired = nil
        onboardingDemoWindow = nil
        cancelOnboardingActionAnimation()
        if wasPresenting { setPhase(.hidden) }
        PhysicalNotchTap.shared.refresh()
    }

    private func cancelOnboardingActionAnimation() {
        demoAnimationID = nil
        demoTask?.cancel(); demoTask = nil
        onboardingActionCue = .idle
    }

    /// Let the shell settle, bloom the spectrum once, press, then release into the lesson.
    /// Every wait belongs to this opening; dismissal/reopening cannot revive an old cue.
    private func beginNotchDemo(door: String) {
        cancelOnboardingActionAnimation()
        let id = UUID()
        demoAnimationID = id
        setPhase(.typing)
        Log("\(door) → onboarding demo (\(onboardingDemoAction.title))")
        demoTask = Task { [weak self] in
            do {
                for cue in OnboardingActionCue.sequence {
                    try await Task.sleep(for: .seconds(cue.delay))
                    guard let self, self.demoAnimationID == id, self.onboardingDemoArmed,
                          self.phase == .typing else { return }
                    self.onboardingActionCue = cue.state
                }
                try await Task.sleep(for: .seconds(OnboardingActionCue.handoffDelay))
                guard let self, self.demoAnimationID == id, self.onboardingDemoArmed,
                      self.phase == .typing else { return }
                self.demoTask = nil
                self.demoAnimationID = nil
                self.onboardingActionCue = .idle
                self.onboardingDemoArmed = false
                let fired = self.onboardingDemoFired
                switch self.onboardingDemoAction {
                case .takeOver:
                    self.onboardingDemoWindow = nil
                    self.onboardingDemoOwnerID = nil
                    self.onboardingDemoFired = nil
                    UserDefaults.standard.set(true, forKey: Self.notchDemoPlayedKey)
                    self.run.startOnboardingDemo()
                    self.setPhase(.running)
                case .magicReply:
                    // Only the local sample view drafts. No real reply/provider path runs.
                    self.setPhase(.hidden)
                }
                PhysicalNotchTap.shared.refresh()
                fired?()
            } catch {
                // The cancelling owner resets the cue; an old task cannot clear a new one.
            }
        }
    }

    /// Cancel — back out of whatever the notch is doing, mirroring the obvious one-tap action for each state:
    /// retract a just-opened notch · dismiss the type field · abandon a listening/transcribing voice
    /// capture (so a stuck finalize can always be bailed) ·
    /// or, ONLY while the voice transcript is still on screen, cancel the just-fired run and dismiss INSTANTLY
    /// (no "Stopped" flourish — that's reserved for interrupting live computer use via STOP) so a misheard
    /// command can be killed and redone at a glance. The instant the transcript dissolves into the working /
    /// "Remembering" line, cancel is left ALONE — computer use is now quietly running. Returns whether it
    /// consumed the event (so the key monitor swallows it). Reached via the window's LOCAL Esc monitor
    /// (works whenever Sentient is frontmost — no global keyDown tap, that's Input-Monitoring-gated) and
    /// via a hotkey press for the listening and transcribing beats (hotkeyTapped).
    @discardableResult
    func cancelCurrent() -> Bool {
        if DoubleTap.shared.isDrafting { DoubleTap.shared.cancel(); return true }
        if proofread.isRunning { proofread.cancel(); return true }
        if phase == .message { dismissMessagePreview(); return true }
        if phase == .recovery { run.recovery.dismiss(); return true }
        switch phase {
        case .opening:
            setPhase(.hidden)
            Log("notch dismissed (Esc)")
            return true
        case .typing:
            dismissTyping()
            return true
        case .listening, .transcribing:
            cancelDictation()
            setPhase(.hidden)
            Log("notch voice capture cancelled")
            return true
        case .running where run.isPreparing:
            stop()
            Log("Sidekick preparation cancelled (Esc)")
            return true
        // Only while the transcript is actually shown (readBack up AND not yet replaced by "Remembering") —
        // not once computer use is working, so Esc stays free for the user's own apps then.
        case .running where readBack != nil && run.remembering == nil && !run.isPersonalizing:
            stop()                       // transcript shown → stop() dismisses instantly (no flourish), run cancelled
            Log("notch transcript cancelled (Esc) — immediate dismiss")
            return true
        default:
            return ComputerUseGate.shared.cancelBeforePresentation()
        }
    }

    // MARK: Run completion → the notch's finishing flourish

    private func runFinished(_ outcome: CommandRunModel.Outcome) {
        guard !run.isClearingChat else { return }
        if returningFromRecovery {
            returningFromRecovery = false
            if let (text, mode, source) = deferredSubmission {
                deferredSubmission = nil; submit(text, mode: mode, source: source)
            }
            return
        }
        clearReadBack()
        // A progress update is not the final result. Retire it before deciding the
        // terminal cue, but never replace a reply the user is actively editing.
        let showingProgress = phase == .message && notchMessage?.event.messageKind == .update && !messageReplyFocused
        guard phase == .running || showingProgress else { return }
        if showingProgress { dismissMessagePreview() }
        guard !homeWindowFocused, !composerDictation.isActive else {
            setPhase(.hidden)
            return
        }
        if outcome == .success, run.completionHasAnswer {
            // Reconcile from committed history even if its notification has not run yet.
            // A dismissed/read answer is consumed by the attention policy, not replayed.
            routeAttention()
            if phase == .running { setPhase(.hidden) }
            return
        }
        setPhase(.finishing(outcome))
        // Success and stopped statuses are brief; failures leave time to read the reason.
        scheduleHide(after: outcome == .failed ? 5.0 : outcome == .success ? 1.15 : 1.5)
    }

    // Presentation consumes only newly committed high-priority messages. Historic unread
    // replies remain reachable without replaying a backlog when the app launches.
    private func routeAttention() {
        let store = run.conversation.store
        // A failed read is not permission to display a possibly stale captured message.
        let generation: UUID?
        let latest: Int64
        let record: SidekickConversationStore.Record?
        do {
            generation = try store?.generation
            latest = try store?.latestSequence ?? 0
            record = try store?.latestUnreadHighPriorityMessage
        } catch { return }
        let decision = attentionPolicy.update(generation: generation, latestSequence: latest,
            latestUnreadHigh: record.map { .init(id: $0.event.id, sequence: $0.sequence) },
            homeVisible: run.conversation.isVisible,
            inputBlocked: run.isClearingChat || run.recovery.isPending || phase == .typing || phase == .listening
                || phase == .transcribing || phase == .opening,
            previewVisible: phase == .message)
        switch decision {
        case .unchanged:
            if attentionPolicy.presented == nil { notchMessage = nil }
        case .dismiss:
            dismissMessagePreview()
        case .present(let message):
            guard let record, record.event.id == message.id else { return }
            notchMessage = record
            clearReadBack()
            setPhase(.message)
            scheduleMessageRetraction()
            SidekickDiagnostics.event(.attention, source: .notchTyped, counts: [.messages: 1])
        }
    }

    func dismissMessagePreview() {
        messageTimer?.cancel(); messageTimer = nil
        messageReplyFocused = false
        attentionPolicy.dismiss()
        notchMessage = nil
        guard phase == .message else { return }
        setPhase(run.isRunning ? .running : .hidden)
    }

    func setMessagePreviewHovering(_ value: Bool) {
        guard phase == .message, attentionPolicy.setHovering(value) else { return }
        messageInteractionChanged()
    }

    /// Separate from pointer geometry: leaving the panel must not dismiss selected text.
    /// The message identity rejects an outgoing view's late selection callback after a swap.
    func setMessagePreviewSelecting(_ value: Bool, messageID: String) {
        guard phase == .message, notchMessage?.event.id == messageID,
              attentionPolicy.setSelecting(value) else { return }
        messageInteractionChanged()
    }

    private func messageInteractionChanged() {
        messageTimer?.cancel(); messageTimer = nil
        guard !attentionPolicy.isInteracting else { return }
        // Requery read receipts and immediately coalesce a newer deferred high message.
        routeAttention()
        if phase == .message { scheduleMessageRetraction() }
    }

    private func scheduleMessageRetraction() {
        messageTimer?.cancel()
        guard phase == .message, !attentionPolicy.isInteracting else { return }
        let id = notchMessage?.event.id
        let generation = attentionPolicy.generation
        messageTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.attentionPolicy.canRetract(generation: generation,
                messageID: id, previewVisible: self.phase == .message) else { return }
            self.dismissMessagePreview()
        }
    }

    // MARK: Phase + read-back plumbing (generation-guarded so a delayed change never clobbers a newer one)

    private func setPhase(_ newPhase: NotchPhase) {
        if newPhase != .typing, demoTask != nil { cancelOnboardingActionAnimation() }
        let preview = newPhase == .hidden && phase != .hidden && (physicalTapTransition || pointerDismissal)
        dismissalPreviewTask?.cancel(); dismissalPreviewTask = nil
        notchDismissalPreview = preview
        notchAnimationSpeed = physicalTapTransition ? 1.35 : 1
        notchPhysicalSpringResponse = physicalTapTransition ? physicalTapSpringResponse : nil
        phase = newPhase
        if newPhase != .listening && newPhase != .transcribing { dictation.endContext() }
        phaseToken &+= 1
        if preview {
            let token = phaseToken
            dismissalPreviewTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.phaseToken == token, self.phase == .hidden else { return }
                self.notchDismissalPreview = false
                self.dismissalPreviewTask = nil
            }
        }
        Log("notch → \(newPhase)")
        if newPhase != .message {
            messageReplyFocused = false
            Task { @MainActor [weak self] in self?.routeAttention() }
        }
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
        let seconds = NotchMetrics.readBackDuration(for: text)   // 0.5s (one line) → 2.5s (long), scaled to length
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
