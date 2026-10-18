//
//  NotchView.swift
//  Sentient OS macOS
//
//  The notch overlay's content — a Dynamic-Island-grade living object. `NotchView` is the thin
//  reactive binder (reads CommandCoordinator); `NotchContent` is the pure, previewable visual that
//  draws the morphing NotchShape, the camera-flanking content (spinning logo · status · STOP), the
//  serif→mono read-back dissolve, and the flowing Sentient edge glow that says "the AI is working".
//
//  The shape, size, radii, content and glow all animate together off `phase` (one spring) so nothing
//  ever hard-cuts. Only the controls are hit-testable (the type field with its mic button, the send
//  button, the listening stop button, the running STOP); everything else passes clicks through. The panel
//  host + positioning live in NotchWindowController. Doc: the two Documentation - Sidekick - *.md files in this folder.
//

import SwiftUI
import AppKit

// MARK: - Sizing (per phase), derived from the display's real notch (or a default)

struct NotchMetrics: Equatable {
    var availableSize = CGSize(width: 1440, height: 900)
    var hardwareNotch: CGSize?              // nil = this display has no physical notch

    var hasPhysicalNotch: Bool { hardwareNotch != nil }
    var baseWidth: CGFloat { max(hardwareNotch?.width ?? 0, 200) }
    var baseHeight: CGFloat { max(hardwareNotch?.height ?? 0, 32) }

    var topRowHeight: CGFloat { baseHeight }   // the camera band — logo/control sit at its level
    var captionHeight: CGFloat { 18 }          // the status text row — kept tight so the notch stays short
    var centerGap: CGFloat { 64 }              // keep logo/control clear of the camera
    var hPad: CGFloat { 18 }                   // clearance so the logo/mic clear the rounded corners
    var controlSlot: CGFloat { 17 }            // the square both the logo AND every right control fill, so they twin exactly (same size, same optical center)
    var topPad: CGFloat { 0 }
    var bottomPad: CGFloat { 4 }
    var fieldRowHeight: CGFloat { 30 }         // the type field row (below the camera band); listening/transcribing keep it
    /// `baseHeight` (auxiliaryTopLeftArea) reports a hair shallower than the notch's real black cutout, so
    /// the opening state (sized to exactly baseHeight) falls short and the hardware lip peeks below. Add a
    /// small cover so it fully fills the hardware notch. (Other states are taller and already overshoot.)
    var notchBottomCover: CGFloat { 2 }
    /// The most the notch grows to fit a long spoken instruction before the caption truncates.
    var maxReadBackLines: Int { 10 }

    var runningWidth: CGFloat { max(baseWidth + 160, 360) }

    // MARK: Hover — the click-to-type affordance (the idle notch swells under the cursor)

    /// The grown silhouette while the cursor hovers the IDLE notch: noticeably wider, only a touch
    /// deeper than the hardware cutout — enough to read as "press me", small enough to stay a notch,
    /// not a state. (Tuned on Jesai's bezel: the swell reads mostly sideways; too much depth looks
    /// like the notch drooping.)
    var hoverSize: CGSize {
        let base = hardwareNotch ?? CGSize(width: baseWidth, height: baseHeight)
        return CGSize(width: base.width + 22, height: base.height + 3)
    }

    /// The genuine notch radius (height / 3) scaled to the hover depth, so the swollen shape keeps
    /// the real cutout's character instead of going balloon-round.
    var hoverRadii: (top: CGFloat, bottom: CGFloat) {
        let r = hoverSize.height / 3
        return (top: max(r - 4, 0), bottom: r)
    }

    /// The running/finishing notch height for a given caption-row height (the only variable bit). Kept as
    /// tight as possible — camera band + the text + a small bottom pad — so it eats minimally into apps.
    func runningHeight(caption: CGFloat) -> CGFloat { baseHeight + caption + bottomPad }

    /// Size for a phase. When a voice read-back is showing, the running notch grows DOWN to fit the whole
    /// heard instruction (capped at `maxReadBackLines`); once it dissolves to the codex line it shrinks back.
    func size(for phase: NotchPhase, readBack: String? = nil, remembering: String? = nil,
              personalizing: Bool = false, recoveryContent: SidekickRecoveryContent? = nil,
              messageContent: SidekickConversationStore.Record? = nil) -> CGSize {
        switch phase {
        case .hidden:
            // Retract target: collapse to the EXACT hardware notch (radius matched in `radii`) so the black
            // shell merges seamlessly into the real cutout, then orders out invisibly — a physical retract,
            // not a fade. (A notch-less display has nothing to merge into → the view fades instead, see
            // `shellOpacity`; base size keeps that fallback sane.)
            return hardwareNotch ?? CGSize(width: baseWidth, height: baseHeight)
        case .opening:
            return CGSize(width: baseWidth + 76, height: baseHeight + notchBottomCover)   // fully fill the hardware notch
        case .typing, .listening, .transcribing:
            // One geometry for the whole type-or-talk moment: the mic click swaps the field row's
            // content in place (placeholder → "Listening…", mic → stop), never the shape.
            return CGSize(width: max(baseWidth + 240, 480), height: baseHeight + fieldRowHeight + bottomPad + 4)
        case .running, .finishing:
            let caption: CGFloat
            if case .finishing(.failed) = phase { caption = captionHeight * 2 }        // room for the 2-line ✗ reason
            else if remembering != nil || personalizing { caption = captionHeight } // one context-status line
            else if readBack?.isEmpty == false { caption = readBackCaptionHeight(readBack!) }
            else { caption = captionHeight }
            return CGSize(width: runningWidth, height: runningHeight(caption: caption))
        case .recovery:
            if let recoveryContent { return SidekickRecoveryLayout(content: recoveryContent, metrics: self).size }
            // Without content, return the maximum so the panel reserves a fixed canvas.
            return CGSize(width: min(520, availableSize.width - 40), height: min(240, availableSize.height - 80))
        case .message:
            // A bounded reading surface inside the already-reserved fixed panel canvas.
            // Long answers scroll here and open at their exact message in the main window.
            let maximum = CGSize(width: min(520, availableSize.width - 40),
                                 height: min(SidekickNotchMessageLayout.maximumHeight, availableSize.height - 80))
            guard let messageContent else { return maximum }
            return SidekickNotchMessageLayout(markdown: messageContent.event.text, maximumSize: maximum,
                cameraHeight: topRowHeight, outerTopPad: topPad, outerBottomPad: bottomPad,
                horizontalPad: hPad).size
        case .notice:
            return CGSize(width: max(baseWidth + 120, 320), height: baseHeight + captionHeight + bottomPad)
        }
    }

    func radii(for phase: NotchPhase) -> (top: CGFloat, bottom: CGFloat) {
        switch phase {
        case .opening, .hidden:
            // The macOS notch's OWN corner radius (DynamicNotch's tuned match: baseHeight / 3), so at
            // the real notch height the opening state reads as the genuine notch — and the hidden state
            // collapses to that same shape so it merges cleanly into the physical cutout on dismiss.
            let r = baseHeight / 3
            return (top: max(r - 4, 0), bottom: r)
        default:
            return (top: 8, bottom: min(max(size(for: phase).height * 0.24, 8), 18))
        }
    }

    // MARK: Read-back sizing — grow the notch to fit the whole heard instruction (capped)

    /// Serif-italic font matching the read-back caption — used to measure the full spoken text's height.
    private static let readBackFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 13)
        let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return NSFont(descriptor: serif.withSymbolicTraits(.italic), size: 13) ?? base
    }()

    private var readBackLineHeight: CGFloat {
        let f = Self.readBackFont
        return f.ascender - f.descender + f.leading
    }

    /// The read-back wrapped in elegant curly quotes — used for BOTH the display and the height
    /// measurement, so they always agree (a long quoted instruction never clips its last line).
    static func quoted(_ text: String) -> String { "“\(text)”" }

    /// Rendered height of the (quoted) `text` wrapped at the running caption width (uncapped, unfloored).
    private func readBackMeasuredHeight(_ text: String) -> CGFloat {
        (Self.quoted(text) as NSString).boundingRect(
            with: CGSize(width: max(runningWidth - hPad * 2, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.readBackFont]).height
    }

    /// Caption-row height needed to show `text` in full at the running width — capped at `maxReadBackLines`
    /// and floored at the normal caption height (so a one-line instruction doesn't shrink the notch).
    func readBackCaptionHeight(_ text: String) -> CGFloat {
        max(min(ceil(readBackMeasuredHeight(text)) + 4, maxReadBackCaptionHeight), captionHeight)
    }

    /// The tallest the caption row can get (the read-back cap) — drives the fixed canvas size.
    var maxReadBackCaptionHeight: CGFloat { ceil(readBackLineHeight * CGFloat(maxReadBackLines)) + 4 }

    /// How many lines the read-back wraps to (1...maxReadBackLines).
    func readBackLineCount(_ text: String) -> Int {
        max(1, min(Int((readBackMeasuredHeight(text) / readBackLineHeight).rounded()), maxReadBackLines))
    }

    /// How long to linger on the read-back, scaling LINEARLY by line count: 4s for a one-liner up to 9s
    /// at the line cap. (Running width is constant across screens, so a default `NotchMetrics` reads true.)
    static func readBackDuration(for text: String) -> Double {
        let m = NotchMetrics(hardwareNotch: nil)
        let t = Double(m.readBackLineCount(text) - 1) / Double(max(m.maxReadBackLines - 1, 1))
        return 4 + t * 5
    }

    static let preview = NotchMetrics(hardwareNotch: CGSize(width: 200, height: 37))
}

// MARK: - The reactive binder

struct NotchView: View {
    let coordinator: CommandCoordinator
    let metrics: NotchMetrics

    var body: some View {
        NotchContent(phase: coordinator.phase,
                     readBack: coordinator.readBack,
                     statusLine: coordinator.run.statusLine,
                     activity: coordinator.run.isRunning && !coordinator.run.isOffline
                         ? coordinator.run.conversation.latestActivity.flatMap { SidekickActivityPresentation.steps([$0]).first } : nil,
                     remembering: coordinator.run.remembering,
                     personalizing: coordinator.run.isPersonalizing,
                     hovering: coordinator.notchHovering,
                     demoText: coordinator.demoDraft,
                     showStop: !coordinator.run.isDemo,
                     metrics: metrics,
                     recovery: coordinator.run.recovery,
                     message: coordinator.notchMessage,
                     isTaskRunning: coordinator.run.isRunning,
                     messageReplyFocused: coordinator.messageReplyFocused,
                     messageReplySelection: coordinator.run.conversation.replyReference?.messageID == coordinator.notchMessage?.event.id
                         ? coordinator.run.conversation.replyReference?.selectedText : nil,
                     draft: Binding(get: { coordinator.run.conversation.draft },
                                    set: { coordinator.run.conversation.draft = $0 }),
                     onBack: { coordinator.backFromRecovery() },
                     onStop: { coordinator.stop() },
                     onSubmitText: { coordinator.submitTyped($0) },
                     onOpenConversation: {
                         let messageID = coordinator.phase == .message ? coordinator.notchMessage?.event.id : nil
                         coordinator.run.conversation.show(messageID: messageID)
                         if coordinator.phase == .message { coordinator.dismissMessagePreview() }
                     },
                     onDismissMessage: { coordinator.dismissMessagePreview() },
                     onMessageSelecting: { coordinator.setMessagePreviewSelecting($0, messageID: $1) },
                     onMessageReplyFocusChanged: { coordinator.setMessageReplyFocused($0, messageID: $1) },
                     onMessageReplySubmit: { coordinator.submitMessageReply($0, messageID: $1) },
                     onReply: { quote in
                         guard let message = coordinator.notchMessage else { return }
                         coordinator.prepareMessageReply(quote, messageID: message.event.id)
                     },
                     onMic: { coordinator.startListening() },
                     onFinishListening: { coordinator.finishListening() },
                     onNotchClick: { coordinator.notchClicked() })
    }
}

// MARK: - The pure visual

struct NotchContent: View {
    let phase: NotchPhase
    let readBack: String?
    let statusLine: String
    var activity: SidekickActivityPresentation.Step? = nil
    var remembering: String? = nil
    var personalizing = false
    /// The cursor is over the IDLE notch (the click-to-type affordance): the shell swells with a
    /// drop shadow — no glow, no content — and a click opens the type field. Honored only while
    /// `.hidden`; any real phase owns the shape.
    var hovering: Bool = false
    /// The onboarding demo's auto-typing: when set, the type field's draft mirrors it (the show
    /// runs through the REAL TextField). nil = the user owns the field.
    var demoText: String? = nil
    /// False during the onboarding demo run — scripted theater has nothing to STOP.
    var showStop: Bool = true
    let metrics: NotchMetrics
    var recovery: SidekickRecovery? = nil
    var message: SidekickConversationStore.Record? = nil
    var isTaskRunning = false
    var messageReplyFocused = false
    var messageReplySelection: String? = nil
    var draft: Binding<String> = .constant("")
    var onBack: () -> Void = {}
    var onStop: () -> Void = {}
    var onSubmitText: (String) -> Bool = { _ in false }
    var onOpenConversation: () -> Void = {}
    var onDismissMessage: () -> Void = {}
    var onMessageSelecting: (Bool, String) -> Void = { _, _ in }
    var onMessageReplyFocusChanged: (Bool, String) -> Void = { _, _ in }
    var onMessageReplySubmit: (String, String) -> Bool = { _, _ in false }
    var onReply: (String?) -> Void = { _ in }
    /// The field's mic button → open the mic; the listening stop button → transcribe and fire.
    var onMic: () -> Void = {}
    var onFinishListening: () -> Void = {}
    var onNotchClick: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reduceMotion: Bool { motionOverride ?? systemReduceMotion }
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let hoverIdle = hovering && phase == .hidden     // the swollen click affordance — idle only
        let size = hoverIdle ? metrics.hoverSize
                             : metrics.size(for: phase, readBack: readBack, remembering: remembering, personalizing: personalizing,
                                            recoveryContent: recovery?.content, messageContent: message)
        let radii = hoverIdle ? metrics.hoverRadii : metrics.radii(for: phase)
        let visible = phase != .hidden
        // The notch sits FLUSH at the screen's top edge — its concave top corners visible on the bezel
        // (the genuine-notch flare). The glow traces only the sides + bottom (NotchSkirtShape), so the
        // bezel line never lights up and there's no need to bleed the window off-screen to hide a top glow.

        ZStack(alignment: .top) {
            // The depth bed — the silhouette's drop shadow, at the very BOTTOM of the stack so it
            // sits BEHIND the color glow: the spectrum reads against darkness instead of the user's
            // wallpaper, and the hover swell reads solid (hover deliberately has NO glow — the shadow
            // alone says "pressable"). The bed's own fill never shows (the real shell covers it
            // exactly); only its shadow escapes. Opacity-only fade, so it rides whichever morph is
            // driving (the phase spring or the hover spring) and vanishes for the retract-merge.
            NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
                .fill(.black)
                .shadow(color: .black.opacity(0.55), radius: 9, y: 3)
                .opacity(visible || hoverIdle ? 1 : 0)
                .allowsHitTesting(false)
            glow(radii, lineWidth: 13, blur: 17, strength: 0.75)   // wide soft outer halo (behind the fill)
            glow(radii, lineWidth: 6,  blur: 6,  strength: 0.95)   // denser halo hugging the edge
            NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
                .fill(.black)
                // Clickable ONLY as the hover affordance — every other state keeps the shell
                // hit-transparent (STOP / the type field stay the notch's only interactive elements).
                // The generous contentShape makes a click pinned against the screen's top edge (a point
                // ON the shape's boundary, which path hit-testing excludes) still land on the tap; the
                // window only delivers clicks over the silhouette anyway, so this over-claims nothing.
                .contentShape(Rectangle().inset(by: -4))
                .onTapGesture(perform: onNotchClick)
                .allowsHitTesting(hoverIdle)
            glow(radii, lineWidth: 3,  blur: 0.6, strength: 1.0)   // crisp bright rim, over the fill
            content(size: size)
                .opacity(visible ? 1 : 0)              // icons + caption dissolve as the shell retracts into the cutout
                .blur(radius: reduceMotion || visible ? 0 : 7)
                .scaleEffect(reduceMotion || visible ? 1 : 0.97, anchor: .top)
                .clipShape(NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom))
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)        // on the notch itself, never the full canvas
        .accessibilityLabel(a11yLabel)
        .scaleEffect(reduceMotion || visible || hoverIdle ? 1 : 0.94, anchor: .top)
        .opacity(shellOpacity)                           // shell stays opaque & MERGES into a real notch on dismiss (fades only if there's none)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(morph, value: phase)
        .animation(morph, value: readBack)               // grow/shrink the notch as the read-back appears/clears
        .animation(morph, value: personalizing)
        .animation(morph, value: remembering)            // shrink back to one line when "Remembering" takes over
        .animation(morph, value: recovery?.content?.id) // successive presentations can need different heights
        .animation(morph, value: message?.event.id)
        .animation(hoverMorph, value: hovering)          // the hover swell/settle — snappier than the phase morph
        .onChange(of: phase) { _, newPhase in
            if newPhase == .typing {
                DispatchQueue.main.async { fieldFocused = true }   // focus once the panel has become key
            } else {
                fieldFocused = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private var ambientAnimationPaused: Bool {
        if reduceMotion || lowPowerMode { return true }
        switch phase {
        case .running, .listening, .transcribing, .finishing: return false
        default: return true // no clocks behind an ordered-out panel or while reading/typing
        }
    }

    private var morph: Animation {
        // Longer + bouncier than a flat ease — fast out of the gate, then a gentle overshoot-and-settle
        // (the Dynamic Island "alive" curve). Lower damping = visible bounce; ~0.52 response = slightly slower.
        reduceMotion ? .easeInOut(duration: 0.24) : .spring(response: 0.52, dampingFraction: 0.72)
    }

    private var hoverMorph: Animation {
        // The hover swell — a quick ease-out with one tiny overshoot at the end (the Dynamic Island
        // "press me" bounce), snappier than the phase morph. The EXIT is slower and with the bounce
        // damped out: a shrink's overshoot lands INSIDE the black cutout where it's invisible, and a
        // fully-damped spring spends its tail creeping imperceptibly — so the exit needs extra time
        // on paper for its VISIBLE portion to match the entry (tuned on Jesai's bezel).
        // (`hovering` is already the new value when this is read, so it picks the right direction.)
        if reduceMotion { return .easeOut(duration: 0.18) }
        return hovering ? .spring(response: 0.38, dampingFraction: 0.6)
                        : .spring(response: 0.52, dampingFraction: 0.95)
    }

    // MARK: Content

    private func content(size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if phase == .recovery {
                    Button(action: onBack) {
                        Image(systemName: isTaskRunning ? "stop.fill" : "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: metrics.controlSlot, height: metrics.controlSlot)
                            .contentShape(Rectangle().inset(by: -6))
                    }
                    .buttonStyle(.plain)
                    .help(isTaskRunning ? "Stop this task and write a new request" : "Write a new request")
                    .accessibilityLabel(isTaskRunning ? "Stop this task and write a new request" : "Write a new request")
                } else {
                    NotchIdentityMark(size: metrics.controlSlot, working: phase == .running || isTaskRunning,
                        animated: !ambientAnimationPaused)
                }
                Spacer(minLength: metrics.centerGap)
                HStack(spacing: 12) {
                    if showsHistoryControl {
                        Button(action: onOpenConversation) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: metrics.controlSlot, height: metrics.controlSlot)
                        }
                        .buttonStyle(NotchIconButtonStyle())
                        .help("Open conversation in Sentient")
                        .accessibilityLabel("Open Sidekick conversation in Sentient")
                    }
                    rightControl
                        .frame(width: metrics.controlSlot, height: metrics.controlSlot)
                        .id(controlKey)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .frame(height: metrics.topRowHeight)

            if phase == .message, let message {
                SidekickNotchMessageView(message: message, isTaskRunning: isTaskRunning,
                    onOpen: onOpenConversation, onReply: onReply, onStop: onStop,
                    onSelecting: { onMessageSelecting($0, message.event.id) },
                    draft: draft, replyFocused: messageReplyFocused,
                    replyingToSelection: messageReplySelection != nil,
                    onReplyFocusChanged: { onMessageReplyFocusChanged($0, message.event.id) },
                    onSend: { onMessageReplySubmit($0, message.event.id) })
                    // Layout at the final readable width before the shell reveals it. The
                    // contents never rewrap through the intermediate notch-morph widths.
                    .frame(width: size.width - metrics.hPad * 2,
                           height: size.height - metrics.topRowHeight - metrics.topPad - metrics.bottomPad)
                    .id(message.event.id)
                    .transition(contentReveal)
            } else if phase == .recovery, let recovery, let content = recovery.content {
                SidekickRecoveryView(recovery: recovery, content: content,
                                     layout: SidekickRecoveryLayout(content: content, metrics: metrics))
                    .id(content.id)
                    .transition(contentReveal)
            } else if phase == .typing {
                typingField
                    .frame(height: metrics.fieldRowHeight)
                    .transition(contentReveal)
            } else if phase == .listening || phase == .transcribing {
                voiceRow
                    .frame(height: metrics.fieldRowHeight)
                    .transition(contentReveal)
            } else if showsCaption {
                caption
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(contentReveal)
            }
        }
        .padding(.horizontal, metrics.hPad)
        .padding(.top, metrics.topPad)
        .padding(.bottom, metrics.bottomPad)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    @ViewBuilder private var rightControl: some View {
        switch phase {
        case .typing, .listening, .transcribing:
            // One identity (controlKey) across the type-or-talk moment, so the send button sits still
            // while the field row underneath changes. Solid and clickable when there is something to
            // send (a typed draft, or an open mic, where a click ends the recording and fires, same
            // as the stop button), a faint ghost otherwise. Transcribing has nothing to send yet, so
            // it waits dim.
            NotchSendButton(enabled: phase == .listening || (phase == .typing && !isTaskRunning && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                            help: phase == .listening ? "Stop and send" : "Send") {
                if phase == .listening { onFinishListening() } else { submitDraft() }
            }
        case .running:
            // The onboarding demo is theater — nothing real to stop, so no STOP.
            if showStop { NotchStopButton(action: onStop) } else { Color.clear.frame(width: 1, height: 18) }
        case .finishing(let outcome):
            Image(systemName: Self.outcomeSymbol(outcome))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Self.outcomeColor(outcome))
                .allowsHitTesting(false)
        case .recovery:
            Button { recovery?.dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .contentShape(Rectangle().inset(by: -6))
            }
            .buttonStyle(.plain).help("Hide for now").accessibilityLabel("Hide for now")
        case .message:
            Button(action: onDismissMessage) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: metrics.controlSlot, height: metrics.controlSlot)
            }
            .buttonStyle(NotchIconButtonStyle())
            .help("Hide response")
            .accessibilityLabel("Hide response. It stays in your conversation history.")
        case .hidden, .opening, .notice:
            Color.clear.frame(width: 1, height: 18)
        }
    }

    /// The type field — a focused TextField that fires the typed task on ⏎ or the send button (Esc /
    /// empty cancels) — with the mic button at its trailing end, directly under the send button (same
    /// slot width, same axis).
    /// The mic is the way to talk instead; it dissolves the moment the draft has text, since the field
    /// is now a typed task. Its slot stays reserved so nothing else shifts.
    private var typingField: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if draftText.isEmpty {
                    Text("What can I take over for you?")
                        .font(.system(size: 13, design: .serif)).italic()
                        .foregroundStyle(.white.opacity(0.4))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: draftBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .focused($fieldFocused)
                    .onSubmit(submitDraft)
                    .accessibilityLabel("Message Sidekick")
            }
            ZStack {
                if draftText.isEmpty {
                    NotchMicButton(action: onMic)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .frame(width: metrics.controlSlot, height: metrics.controlSlot)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8), value: draftText.isEmpty)
        }
    }

    /// Fire the typed draft (the field's ⏎ and the send button land here) and clear the field.
    private func submitDraft() {
        guard demoText == nil else { return }
        let text = draft.wrappedValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if onSubmitText(text) { draft.wrappedValue = "" }
    }

    private var draftText: String { demoText ?? draft.wrappedValue }
    private var draftBinding: Binding<String> {
        Binding(get: { draftText }, set: { if demoText == nil { draft.wrappedValue = $0 } })
    }

    private var contentReveal: AnyTransition { reduceMotion ? .opacity : .blurDissolve }
    private var showsHistoryControl: Bool {
        switch phase {
        case .typing, .running, .message, .recovery: true
        default: false
        }
    }

    /// The field row while the mic is open, and while the transcript finalizes: the same row, its
    /// content swapped in place — the serif whisper on the left, and in the mic's slot the stop
    /// button (ends the recording and fires the task) or the finalize spinner.
    private var voiceRow: some View {
        HStack(spacing: 10) {
            Group {
                if phase == .listening {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: ambientAnimationPaused)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let breathe = ambientAnimationPaused ? 0.5 : (sin(t * 2 * .pi / 1.6) + 1) / 2   // the "I'm hearing you" breath
                        Text("Listening…")
                            .opacity(0.55 + 0.35 * breathe)
                    }
                } else {
                    Text("Transcribing…")
                        .opacity(0.55)
                }
            }
            .font(.system(size: 13, design: .serif)).italic()
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            ZStack {
                if phase == .listening {
                    NotchListenStopButton(action: onFinishListening)
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                } else {
                    ProgressView().controlSize(.small).tint(.white).scaleEffect(0.8)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: metrics.controlSlot, height: metrics.controlSlot)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: phase)
        }
    }

    /// Read-back dissolves into the same app icon and readable activity used in chat.
    @ViewBuilder private var caption: some View {
        switch phase {
        case .running:
            Group {
                if personalizing {
                    Text("Personalizing Sidekick…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Self.rememberingGradient)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Personalizing Sidekick")
                } else if let remembering {
                    rememberingCaption(remembering)                 // gradient, blooming "Remembering" + the note
                } else if let readBack {
                    Text(NotchMetrics.quoted(readBack))              // the heard instruction, in quotes — wraps in full
                        .font(.system(size: 13, design: .serif)).italic()
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(metrics.maxReadBackLines)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    HStack(spacing: 7) {
                        if let shownActivity {
                            ZStack {
                                SidekickActivityIcon(identifier: shownActivity.appIdentifier, symbol: shownActivity.symbol)
                                    .id(shownActivity.appIdentifier ?? shownActivity.symbol)
                                    .transition(contentReveal)
                            }.frame(width: 16, height: 16)
                        }
                        ZStack(alignment: .leading) {
                            Text(progressCaption)
                                .font(.system(size: 12, weight: shownActivity == nil ? .regular : .medium))
                                .lineLimit(shownActivity == nil ? 2 : 1).truncationMode(.tail)
                                .id(progressCaption)
                                .transition(contentReveal)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.22), value: progressCaption)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(runningCaptionKey)
            .transition(contentReveal)
            .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(duration: 0.55, bounce: 0.18), value: runningCaptionKey)
            .animation(.easeInOut(duration: 0.35), value: statusLine)
            .allowsHitTesting(false)
        case .finishing(let outcome):
            // Failures get a second line so the reason remains readable.
            Text(statusLine)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(outcome == .failed ? 2 : 1).truncationMode(.tail)
                .allowsHitTesting(false)
        case .notice(let message):
            Text(message)
                .font(.system(size: 13, design: .serif)).italic()
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    /// Narration and connection notices keep their own words. Raw tool IDs use durable
    /// structured activity; while its projection catches up, show a quiet working label.
    private var notchStatus: SidekickActivityPresentation.NotchStatus {
        SidekickActivityPresentation.notchStatus(statusLine, activity: activity)
    }
    private var shownActivity: SidekickActivityPresentation.Step? { notchStatus.activity }
    private var progressCaption: String { notchStatus.text }

    /// Distinct identities let personalization, remembering, read-back and progress blur-dissolve.
    /// (note / status changes WITHIN a state morph in place instead).
    private var runningCaptionKey: Int {
        if personalizing { return 3 }
        if remembering != nil { return 2 }
        if readBack != nil { return 1 }
        return 0
    }

    /// The "it knows me" beat: a gradient, gently-blooming "Remembering" with the note codex is reading
    /// morphing alongside it (the word stays still while the file flickers by). Gradient = the analysis
    /// screen's "Everything." palette.
    private func rememberingCaption(_ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: ambientAnimationPaused)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let bloom = ambientAnimationPaused ? 0.5 : (sin(t * 2 * .pi / 1.5) + 1) / 2   // a 1.5s breathing glow
                Text("Remembering")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Self.rememberingGradient)
                    .opacity(0.78 + 0.22 * bloom)                                   // breathe via opacity only — no scale bounce
            }
            .fixedSize()
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.middle)
                    .contentTransition(.interpolate)               // morph the note per file; "Remembering" stays put
                    .animation(.easeInOut(duration: 0.3), value: note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The analysis screen's "Everything." gradient (ProcessingView), reused for the "Remembering" word.
    private static let rememberingGradient = LinearGradient(
        colors: [Color(red: 0.66, green: 0.42, blue: 0.85),
                 Color(red: 0.91, green: 0.45, blue: 0.75),
                 Color(red: 0.96, green: 0.55, blue: 0.50),
                 Color(red: 0.95, green: 0.70, blue: 0.35)],
        startPoint: .leading, endPoint: .trailing)

    // MARK: Edge glow (the "AI is working" signal — running + finishing)

    /// One glow layer at a given thickness/softness, faded by `glowStrength * strength`. Stacking a few of
    /// these (wide haze → dense halo → crisp rim) builds the thick, vivid edge glow.
    private func glow(_ radii: (top: CGFloat, bottom: CGFloat),
                      lineWidth: CGFloat, blur: CGFloat, strength: Double) -> some View {
        glowLayer(radii, lineWidth: lineWidth, blur: blur)
            .opacity(glowStrength * strength)
            .allowsHitTesting(false)
    }

    /// The rotating spectrum, MASKED by the notch-skirt stroke. The mask shape lives in the regular body
    /// (NOT inside the TimelineView), so its geometry interpolates in LOCKSTEP with the black fill during
    /// a morph — the edges light up in place, never a separate rounded-rect snapping on. The layer is
    /// always present; its brightness rides `glowStrength` via opacity. Only the gradient ANGLE ticks
    /// per-frame; the skirt (sides + rounded bottom, no top) keeps the glow off the bezel line.
    private func glowLayer(_ radii: (top: CGFloat, bottom: CGFloat),
                           lineWidth: CGFloat, blur: CGFloat) -> some View {
        // The gradient must extend PAST the stroke + blur on every edge — including the bottom, which sits
        // right at the notch's frame edge. So we grow the layer (negative padding) and inset the skirt mask
        // by the same margin: the gradient then bleeds beyond ALL sides equally (no thin bottom edge).
        let m = lineWidth / 2 + blur + 6
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: ambientAnimationPaused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = ambientAnimationPaused ? 0 : (t.truncatingRemainder(dividingBy: 6.5) / 6.5) * 360
            let breathe = ambientAnimationPaused ? 0.5 : (sin(t * 2 * .pi / 3.2) + 1) / 2
            AngularGradient(colors: GlowHalo.stops, center: .center, angle: .degrees(angle))
                .opacity(0.88 + 0.12 * breathe)
        }
        .mask(
            NotchSkirtShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .padding(m)
        )
        .blur(radius: blur)
        .padding(-m)
    }

    private var glowStrength: Double {
        switch phase {
        case .hidden:    return 0
        case .message, .recovery: return 0.35
        case .finishing: return 0.9
        default:         return 1.0   // alive from the moment the notch appears — opening, listening, typing, running…
        }
    }

    /// The black shell's opacity. On dismiss into a REAL notch it stays fully opaque — the shape collapses to
    /// the cutout's exact silhouette and merges (then the window orders out invisibly), so the retract reads
    /// as a physical "suck back into the notch", never a fade. With no hardware notch there's nothing to merge
    /// into, so the shell simply fades out. (The inner content + glow dissolve on their own regardless.)
    private var shellOpacity: Double {
        if phase != .hidden { return 1 }
        return metrics.hasPhysicalNotch ? 1 : 0
    }

    // MARK: Helpers

    private var showsCaption: Bool {
        switch phase { case .running, .finishing, .notice: return true; default: return false }
    }

    /// Identity for the right-control cross-fade (⏎ glyph → STOP → outcome glyph).
    private var controlKey: Int {
        switch phase {
        case .hidden: return 0
        case .opening: return 1
        case .typing, .listening, .transcribing: return 2   // shared identity → the send button holds still across type-or-talk
        case .running: return 3
        case .finishing: return 4
        case .notice: return 5
        case .recovery: return 6
        case .message: return 7
        }
    }

    private var a11yLabel: String {
        switch phase {
        case .hidden: return hovering ? "Sentient — click to type a task" : ""
        case .opening: return "Sentient"
        case .typing: return "Type a task for Sentient, or click the microphone to say it"
        case .listening: return "Sentient is listening. Click stop, or press Return, when you're done"
        case .transcribing: return "Sentient is transcribing"
        case .running: return "Sentient is working. \(progressCaption)"
        case .finishing: return statusLine
        case .notice(let m): return m
        case .recovery: return "Sidekick needs your help"
        case .message: return "A response from Sidekick. Open it in Sentient or reply."
        }
    }

    private static func outcomeSymbol(_ o: CommandRunModel.Outcome) -> String {
        switch o { case .success: return "checkmark"; case .stopped: return "stop.fill"; case .failed: return "xmark" }
    }
    private static func outcomeColor(_ o: CommandRunModel.Outcome) -> Color {
        switch o {
        case .success: return Theme.Ink.green
        case .stopped: return .white.opacity(0.6)
        case .failed:  return Color(red: 1.0, green: 0.45, blue: 0.45)
        }
    }
}

// MARK: - The notch's interactive elements (each fills the 17 pt control slot, like the logo)

/// The brand stays still when Reduce Motion is enabled, including its wall-clock spin.
private struct NotchIdentityMark: View {
    let size: CGFloat
    let working: Bool
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reduceMotion: Bool { motionOverride ?? systemReduceMotion }

    var body: some View {
        Group {
            if reduceMotion || !animated {
                Circle()
                    .strokeBorder(AngularGradient(colors: GlowHalo.stops, center: .center), lineWidth: 2.5)
                    .overlay(alignment: .top) {
                        Circle().fill(.white).frame(width: 3, height: 3).offset(y: -0.5)
                    }
                    .frame(width: size, height: size)
            } else {
                SpinningLogo(size: size, fast: working)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct NotchIconButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 1 : (hovering ? 0.96 : 0.58)))
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.09 : 0))
                    .padding(-4)
            }
            .contentShape(Rectangle().inset(by: -5))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.13), value: hovering)
    }
}

/// The running STOP: a circle, because it interrupts the work.
private struct NotchStopButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(0.16)))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Stop")
        .accessibilityLabel("Stop current Sidekick task")
    }
}

/// The send button in the camera band: the pointer's twin of pressing Return, drawn as the familiar
/// up-arrow in a filled circle. Solid white and clickable only when there is something to send (it
/// brightens fully under the cursor); a faint ghost of itself and hit-transparent otherwise, so it
/// never swallows a click as a dead button.
private struct NotchSendButton: View {
    let enabled: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? Color.black : .white.opacity(0.3))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(!enabled ? 0.12 : hovering ? 1.0 : 0.88)))
                .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .allowsHitTesting(enabled)
        .onHover { hovering = $0 }
        .onChange(of: enabled) { _, on in if !on { hovering = false } }   // hover exits don't reach a hit-transparent view
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The type field's mic: a quiet glyph that brightens under the cursor. Its hit area is padded past
/// the 17 pt slot so a click near it lands.
private struct NotchMicButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.55))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Say it instead")
        .accessibilityLabel("Speak to Sidekick")
    }
}

/// The listening stop: a rounded square holding a white square (the recording-stop shape), sitting
/// exactly where the mic was so the second click lands on the first. Ends the recording AND fires
/// the task; it is not a cancel (Esc and a hotkey press are).
private struct NotchListenStopButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(.white)
                .frame(width: 7, height: 7)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.3 : 0.18)))
                .overlay(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Stop and send")
        .accessibilityLabel("Finish recording and send to Sidekick")
    }
}

// MARK: - Blur-dissolve transition (the serif read-back ⇄ mono codex line morph)

private struct BlurFadeScale: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    let scale: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity).scaleEffect(scale)
    }
}

private extension AnyTransition {
    /// A fancy swap: the outgoing text blurs, fades, and gently expands away while the incoming blurs in,
    /// fades up, and springs from slightly small — a dissolve with a satisfying pop. Pair with a bouncy spring.
    static var blurDissolve: AnyTransition {
        .asymmetric(
            insertion: .modifier(active:   BlurFadeScale(radius: 8, opacity: 0, scale: 0.92),
                                 identity: BlurFadeScale(radius: 0, opacity: 1, scale: 1)),
            removal:   .modifier(active:   BlurFadeScale(radius: 8, opacity: 0, scale: 1.05),
                                 identity: BlurFadeScale(radius: 0, opacity: 1, scale: 1)))
    }
}

// MARK: - Previews (Claude's eyes — static look only; motion is tested live)

private struct NotchPreviewStage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.18), .black], startPoint: .top, endPoint: .bottom)
            content
        }
        .frame(width: 560, height: 230)
    }
}

#Preview("hover (click affordance)") {
    NotchPreviewStage { NotchContent(phase: .hidden, readBack: nil, statusLine: "", hovering: true, metrics: .preview) }
}
#Preview("opening") {
    NotchPreviewStage { NotchContent(phase: .opening, readBack: nil, statusLine: "", metrics: .preview) }
}
#Preview("typing (mic in the field)") {
    NotchPreviewStage { NotchContent(phase: .typing, readBack: nil, statusLine: "", metrics: .preview) }
}
#Preview("listening (stop in the field)") {
    NotchPreviewStage { NotchContent(phase: .listening, readBack: nil, statusLine: "", metrics: .preview) }
}
#Preview("transcribing") {
    NotchPreviewStage { NotchContent(phase: .transcribing, readBack: nil, statusLine: "", metrics: .preview) }
}
#Preview("running · read-back") {
    NotchPreviewStage { NotchContent(phase: .running, readBack: "register me for ZFellows", statusLine: "", metrics: .preview) }
}
#Preview("running · streaming") {
    NotchPreviewStage { NotchContent(phase: .running, readBack: nil, statusLine: "→ filling out the application…", metrics: .preview) }
}
#Preview("finishing · offline") {
    NotchPreviewStage { NotchContent(phase: .finishing(.failed), readBack: nil,
                                     statusLine: CommandRunModel.offlineMessage, metrics: .preview) }
}
#Preview("finishing") {
    NotchPreviewStage { NotchContent(phase: .finishing(.success), readBack: nil, statusLine: "✓ done", metrics: .preview) }
}
#Preview("finishing · failed (reason)") {
    NotchPreviewStage { NotchContent(phase: .finishing(.failed), readBack: nil,
                                     statusLine: "✗ the Canva billing page needs a re-login before the trial can be cancelled",
                                     metrics: .preview) }
}
#Preview("notice") {
    NotchPreviewStage { NotchContent(phase: .notice("didn’t catch that"), readBack: nil, statusLine: "", metrics: .preview) }
}
