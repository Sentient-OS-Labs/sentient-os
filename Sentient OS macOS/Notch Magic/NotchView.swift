//
//  NotchView.swift
//  Sentient OS macOS
//
//  The notch overlay's content — a Dynamic-Island-grade living object. `NotchView` is the thin
//  reactive binder (reads CommandCoordinator); `NotchContent` is the pure, previewable visual that
//  draws the morphing NotchShape, the camera-flanking content (spinning logo · status · STOP), the
//  continuous voice/status row, and the flowing Sentient edge glow that says "the AI is working".
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
    enum SurfaceMode { case notch, floatingIsland, hardwareIsland }
    var availableSize = CGSize(width: 1440, height: 900)
    /// macOS's protected camera band, not a measurement of the physical black pixels.
    var hardwareNotch: CGSize?
    var hardwareIsland = false
    var cameraCenterOffset: CGFloat = 0
    var menuBarHeight: CGFloat = 0
    /// Recording and working share one silhouette.
    var dictationWidth: CGFloat { runningWidth }
    var dictationLeftWidth: CGFloat { (dictationWidth - (hardwareNotch?.width ?? 0)) / 2 }
    var dictationRightWidth: CGFloat { dictationLeftWidth }
    var dictationHeight: CGFloat { hasHardwareCutout ? headerContentHeight + captionHeight + bottomPad : islandActivityHeight }
    var compactMode = false
    var setupVisible = false
    var quickActionsAvailable = true
    var quickActionsHeight: CGFloat { quickActionsAvailable ? 20 : 0 }

    func showingQuickActions(_ available: Bool) -> Self {
        var result = self; result.quickActionsAvailable = available; return result
    }

    func showingSetup(_ visible: Bool) -> Self {
        var result = self
        result.setupVisible = visible
        return result
    }

    var surfaceMode: SurfaceMode { hardwareNotch == nil ? .floatingIsland : hardwareIsland ? .hardwareIsland : .notch }
    var hasHardwareCutout: Bool { hardwareNotch != nil }
    var hasPhysicalNotch: Bool { surfaceMode == .notch }
    var hasHardwareIsland: Bool { surfaceMode == .hardwareIsland }
    static func detectsHardwareIsland(isBuiltIn: Bool, hasMultiTouch: Bool, hasProtectedCameraArea: Bool) -> Bool {
        isBuiltIn && hasMultiTouch && hasProtectedCameraArea
    }
    var islandRestingSize: CGSize { CGSize(width: 72, height: 6) }
    var hardwareMenuHeight: CGFloat { max(menuBarHeight, hardwareNotch?.height ?? 0, 32) }
    private var hardwareBarHeight: CGFloat { min(48, hardwareMenuHeight - 8) }
    var topInset: CGFloat { hasHardwareIsland ? (hardwareMenuHeight - hardwareBarHeight) / 2 : hasPhysicalNotch ? 0 : 9 }
    var hoverTopInset: CGFloat { hasHardwareIsland ? (hardwareMenuHeight - hoverSize.height) / 2 : topInset }
    var baseWidth: CGFloat { max(hardwareNotch?.width ?? 0, 200) }
    var baseHeight: CGFloat { hasHardwareIsland ? hardwareBarHeight : max(hardwareNotch?.height ?? 0, 32) }

    var islandCornerRadius: CGFloat { hasHardwareIsland ? topRowHeight / 2 : 24 }
    var islandActivityHeight: CGFloat { 48 }
    var topRowHeight: CGFloat { hasHardwareCutout ? baseHeight : islandActivityHeight }
    /// The centered header stays still; expanded content starts below the menu bar.
    var bodyTopPad: CGFloat { hasHardwareIsland ? hardwareMenuHeight - topInset - topRowHeight : 0 }
    var headerContentHeight: CGFloat { topRowHeight + bodyTopPad }
    var captionHeight: CGFloat { 18 }          // the status text row — kept tight so the notch stays short
    var centerGap: CGFloat { hasHardwareIsland ? baseWidth : hasPhysicalNotch ? 64 : 24 }
    var hPad: CGFloat { hasPhysicalNotch ? 18 : islandCornerRadius - controlSlot / 2 }
    var controlSlot: CGFloat { hasPhysicalNotch ? 17 : hasHardwareIsland ? min(24, hardwareBarHeight - 8) : 24 }
    var topPad: CGFloat { 0 }
    var bottomPad: CGFloat { hasPhysicalNotch ? 4 : 2 } // response's inner 10 pt + 2 pt = its 12 pt side inset
    var fieldRowHeight: CGFloat { hasPhysicalNotch ? 34 : 40 }
    var typingBottomPad: CGFloat { hasPhysicalNotch ? 12 : hPad }
    var quickActionGap: CGFloat { quickActionsAvailable ? 10 : 0 }
    /// The typed prompt and the reply composer share one glass field shape.
    var composerCornerRadius: CGFloat { hasPhysicalNotch ? 12 : islandCornerRadius - hPad }
    /// `baseHeight` (auxiliaryTopLeftArea) reports a hair shallower than the notch's real black cutout, so
    /// the opening state (sized to exactly baseHeight) falls short and the hardware lip peeks below. Add a
    /// small cover so it fully fills the hardware notch. (Other states are taller and already overshoot.)
    var notchBottomCover: CGFloat { 2 }
    /// The most the notch grows to fit a long spoken instruction before the caption truncates.
    var maxReadBackLines: Int { 10 }

    var runningWidth: CGFloat { hasHardwareIsland ? baseWidth + 2 * (hPad + controlSlot * 2 + 16) : max(baseWidth + 140, 340) }
    var compactRowHeight: CGFloat { hasHardwareCutout ? topRowHeight : 34 }
    var compactControlSlot: CGFloat { 17 }
    var compactHPad: CGFloat { hasPhysicalNotch ? hPad : (compactRowHeight - compactControlSlot) / 2 }
    var compactLeadingWidth: CGFloat { (hasPhysicalNotch ? 82 : 101) + compactHPad }
    var compactTrailingWidth: CGFloat { hasHardwareIsland ? compactLeadingWidth : 54 + compactHPad }
    var compactCameraWidth: CGFloat { hasHardwareCutout ? baseWidth : 0 }

    /// Small hardware-notch states stay solid black. Glass is reserved for surfaces
    /// with input or reading content; external displays retain their floating glass.
    func usesGlassSurface(for phase: NotchPhase) -> Bool {
        guard hasPhysicalNotch else { return true }
        switch phase {
        case .typing, .message, .recovery: return true
        default: return false
        }
    }

    func isCompact(for phase: NotchPhase) -> Bool {
        guard compactMode, !setupVisible else { return false }
        switch phase {
        case .listening, .transcribing, .running, .finishing(.success), .finishing(.stopped): return true
        default: return false
        }
    }

    func glowScale(for phase: NotchPhase) -> CGFloat { isCompact(for: phase) ? 0.9 : 1 }

    func glowRotationPeriod(for phase: NotchPhase) -> TimeInterval { isCompact(for: phase) ? 8.5 : 6.5 }

    /// Unequal wings keep the real camera centered while giving the status more room.
    func horizontalOffset(for phase: NotchPhase) -> CGFloat {
        cameraCenterOffset + (isCompact(for: phase) && hasHardwareCutout ? (compactTrailingWidth - compactLeadingWidth) / 2 : 0)
    }

    // MARK: Hover — the click-to-type affordance (the idle notch swells under the cursor)

    /// The grown silhouette while the cursor hovers the IDLE notch: noticeably wider, only a touch
    /// deeper than the hardware cutout — enough to read as "press me", small enough to stay a notch,
    /// not a state. (Tuned on Jesai's bezel: the swell reads mostly sideways; too much depth looks
    /// like the notch drooping.)
    var hoverSize: CGSize {
        guard hasHardwareCutout else { return CGSize(width: 84, height: 9) }
        if hasHardwareIsland { return CGSize(width: baseWidth + 16, height: baseHeight + 4) }
        let base = hardwareNotch ?? CGSize(width: baseWidth, height: baseHeight)
        return CGSize(width: base.width + 22, height: base.height + 3)
    }

    /// The genuine notch radius (height / 3) scaled to the hover depth, so the swollen shape keeps
    /// the real cutout's character instead of going balloon-round.
    var hoverRadii: (top: CGFloat, bottom: CGFloat) {
        if !hasPhysicalNotch { let r = hoverSize.height / 2; return (top: r, bottom: r) }
        let r = hoverSize.height / 3
        return (top: max(r - 4, 0), bottom: r)
    }

    /// Hardware keeps its camera band and caption. A floating island uses one centered activity row.
    func runningHeight(caption: CGFloat) -> CGFloat { hasHardwareCutout ? headerContentHeight + caption + bottomPad : islandActivityHeight }

    func isInlineIsland(for phase: NotchPhase) -> Bool {
        guard !hasHardwareCutout else { return false }
        switch phase {
        case .opening, .running, .listening, .transcribing, .finishing, .notice: return true
        default: return false
        }
    }

    /// Size for a phase. Voice and submitted speech retain the same activity footprint.
    func size(for phase: NotchPhase, readBack: String? = nil, remembering: String? = nil,
              personalizing: Bool = false, recoveryContent: SidekickRecoveryContent? = nil,
              messageContent: SidekickConversationStore.Record? = nil) -> CGSize {
        if isCompact(for: phase) {
            return CGSize(width: compactLeadingWidth + compactCameraWidth + compactTrailingWidth,
                          height: compactRowHeight + (hasPhysicalNotch ? notchBottomCover : 0))
        }
        switch phase {
        case .hidden:
            // Retract target: collapse to the EXACT hardware notch (radius matched in `radii`) so the black
            // shell merges seamlessly into the real cutout, then orders out invisibly — a physical retract,
            // not a fade. Notchless displays retract into their persistent frosted handle.
            if hasHardwareIsland { return CGSize(width: baseWidth, height: baseHeight) }
            return hardwareNotch ?? islandRestingSize
        case .opening:
            return CGSize(width: hasHardwareIsland ? runningWidth : baseWidth + 76, height: hasPhysicalNotch ? baseHeight + notchBottomCover : topRowHeight)
        case .listening:
            return CGSize(width: dictationWidth, height: dictationHeight)
        case .transcribing:
            return CGSize(width: dictationWidth, height: dictationHeight)
        case .typing:
            // Typing keeps its editable field below the camera.
            return CGSize(width: max(baseWidth + 240, 480), height: headerContentHeight + fieldRowHeight + typingBottomPad + quickActionGap + quickActionsHeight)
        case .running, .finishing:
            let caption: CGFloat
            if case .finishing(.failed) = phase { caption = captionHeight * 2 }        // room for the 2-line ✗ reason
            else if setupVisible || remembering != nil || personalizing { caption = captionHeight } // one context-status line
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
                cameraHeight: headerContentHeight, outerTopPad: topPad, outerBottomPad: bottomPad,
                horizontalPad: hPad).size
        case .notice:
            return CGSize(width: max(baseWidth + 120, 320), height: runningHeight(caption: captionHeight))
        }
    }

    func radii(for phase: NotchPhase) -> (top: CGFloat, bottom: CGFloat) {
        if !hasPhysicalNotch {
            let r = min(size(for: phase).height / 2, islandCornerRadius)
            return (top: r, bottom: r)
        }
        if isCompact(for: phase) {
            return (top: 9, bottom: min(max(size(for: phase).height * 0.3, 10), 14))
        }
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

    // MARK: Submitted transcript — retain the live row and its reading grace period

    /// Match the live transcript. Submission must not restyle or reflow the user's words.
    private static let readBackFont = NSFont.systemFont(ofSize: 13, weight: .medium)

    private var readBackLineHeight: CGFloat {
        let f = Self.readBackFont
        return f.ascender - f.descender + f.leading
    }

    /// Estimate reading length at the normal caption width, without changing layout.
    private func readBackMeasuredHeight(_ text: String) -> CGFloat {
        (text as NSString).boundingRect(
            with: CGSize(width: max(runningWidth - hPad * 2, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.readBackFont]).height
    }

    /// Submission preserves the horizontally scrolling live transcript row.
    func readBackCaptionHeight(_ text: String) -> CGFloat {
        captionHeight // Keep the same horizontal transcript row through submission.
    }

    /// Drives the fixed window canvas allocation.
    var maxReadBackCaptionHeight: CGFloat { captionHeight }

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
    var islandBackdrop: NSImage? = nil
    var displayID: CGDirectDisplayID = 0

    var body: some View {
        NotchContent(phase: coordinator.phase,
                     readBack: coordinator.readBack,
                     statusLine: coordinator.run.statusLine,
                     dictation: coordinator.dictation,
                     setupCaption: coordinator.setupCaption,
                     activity: coordinator.run.isRunning && !coordinator.run.isOffline
                         ? coordinator.run.conversation.latestActivity.flatMap { SidekickActivityPresentation.steps([$0]).first } : nil,
                     remembering: coordinator.run.remembering,
                     rememberingLabel: coordinator.run.isDemo ? "Remembering…" : "Remembering",
                     personalizing: coordinator.run.isPersonalizing,
                     isThinking: coordinator.run.isStarting && !coordinator.run.isOffline,
                     hovering: coordinator.notchHovering,
                     demoText: coordinator.demoDraft,
                     showStop: !coordinator.run.isDemo,
                     metrics: metrics.showingSetup(coordinator.setupCaption != nil),
                     islandBackdrop: islandBackdrop,
                     recovery: coordinator.run.recovery,
                     message: coordinator.dictation.replyMessage ?? coordinator.notchMessage,
                     isTaskRunning: coordinator.run.isRunning,
                     isTaskFinishing: coordinator.run.hasDeliveredFinalAnswer,
                     isProofreading: coordinator.proofread.isRunning,
                     inputReady: !coordinator.proofread.isCapturingSelection && !coordinator.proofread.captureWasInterrupted,
                     focusRequest: coordinator.notchFocusRequest,
                     shortcutProblems: coordinator.quickActionHotkeys.problems,
                     messageReplyFocused: coordinator.messageReplyFocused,
                     messageReplySelection: coordinator.run.conversation.replyReference?.messageID == coordinator.notchMessage?.event.id
                         ? coordinator.run.conversation.replyReference?.selectedText : nil,
                     draft: Binding(get: { coordinator.run.conversation.draft },
                                    set: { coordinator.run.conversation.draft = $0 }),
                     onBack: { coordinator.backFromRecovery() },
                     onStop: { coordinator.stop() },
                     onSubmitText: { coordinator.submitTyped($0) },
                     onSummarize: { coordinator.summarizeScreen() },
                     onProofread: { coordinator.proofreadSelection() },
                     onOpenConversation: {
                         let messageID = coordinator.dictation.replyMessage?.event.id
                             ?? (coordinator.phase == .message ? coordinator.notchMessage?.event.id : nil)
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
                     onMicPress: { coordinator.microphoneMouseDown() },
                     onFinishListening: { coordinator.finishListening() },
                     onStopListening: { coordinator.finishListening(send: false) },
                     onNotchClick: { coordinator.notchClicked(anchor: coordinator.notchAnchor) },
                     onCancelDictation: { coordinator.cancelCurrent() })
            .id(displayID)
    }
}

// MARK: - The pure visual

struct NotchContent: View {
    let phase: NotchPhase
    let readBack: String?
    let statusLine: String
    var dictation = DictationPresentation()
    var setupCaption: CommandCoordinator.SetupCaption? = nil
    var activity: SidekickActivityPresentation.Step? = nil
    var remembering: String? = nil
    var rememberingLabel = "Remembering"
    var personalizing = false
    var isThinking = false
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
    var islandBackdrop: NSImage? = nil
    /// The rendering lab can compare the previous black surface with the shipping glass.
    var islandGlassEnabled = true
    var recovery: SidekickRecovery? = nil
    var message: SidekickConversationStore.Record? = nil
    var isTaskRunning = false
    var isTaskFinishing = false
    var isProofreading = false
    var inputReady = true
    var focusRequest = 0
    var shortcutProblems: [QuickActionShortcut: QuickActionHotkeys.Problem] = [:]
    var messageReplyFocused = false
    var messageReplySelection: String? = nil
    var draft: Binding<String> = .constant("")
    var onBack: () -> Void = {}
    var onStop: () -> Void = {}
    var onSubmitText: (String) -> Bool = { _ in false }
    var onSummarize: () -> Void = {}
    var onProofread: () -> Void = {}
    var onOpenConversation: () -> Void = {}
    var onDismissMessage: () -> Void = {}
    var onMessageSelecting: (Bool, String) -> Void = { _, _ in }
    var onMessageReplyFocusChanged: (Bool, String) -> Void = { _, _ in }
    var onMessageReplySubmit: (String, String) -> Bool = { _, _ in false }
    var onReply: (String?) -> Void = { _ in }
    /// Send and stop are separate intents: stopping leaves an editable transcript.
    var onMic: () -> Void = {}
    var onMicPress: () -> Void = {}
    var onFinishListening: () -> Void = {}
    var onStopListening: () -> Void = {}
    var onNotchClick: () -> Void = {}
    var onCancelDictation: () -> Void = {}
    #if DEBUG
    var observeSurfaceSize: ((CGSize) -> Void)? = nil
    #endif

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reduceMotion: Bool { motionOverride ?? systemReduceMotion }
    @Environment(\.islandColorTreatment) private var colorTreatment
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var isVoice: Bool { phase == .listening || phase == .transcribing }
    private var layoutPhase: NotchPhase { dictation.layoutPhase(for: phase) }
    private var controlSize: CGFloat { metrics.isCompact(for: layoutPhase) ? metrics.compactControlSlot : metrics.controlSlot }
    private var usesGlass: Bool { islandGlassEnabled && metrics.usesGlassSurface(for: layoutPhase) }
    private var isReplyVoice: Bool { dictation.replyMessage != nil && isVoice }
    private var displayedMessage: SidekickConversationStore.Record? {
        isReplyVoice ? dictation.replyMessage : message
    }
    private var retainsTranscript: Bool {
        phase == .running && readBack != nil && setupCaption == nil && !personalizing && remembering == nil
    }
    private var thinkingLightVisible: Bool {
        phase == .running && isThinking && setupCaption == nil && !personalizing && remembering == nil
    }
    private var isResponseSurface: Bool { phase == .message || isReplyVoice }
    private var selectedColorTreatment: IslandColorTreatment { colorTreatment ?? .underlight }
    private var needsBackdropBlur: Bool {
        // External work uses native glass alone; the physical notch keeps its diffuse lower glass.
        if metrics.hasPhysicalNotch { return true }
        if #available(macOS 26.0, *) { return layoutPhase != .running }
        return true // Older systems still need their material fallback.
    }
    private struct TypingFocusKey: Equatable {
        let phase: NotchPhase
        let ready: Bool
        let request: Int
    }
    private struct MorphKey: Equatable {
        let phase: NotchPhase
        let size: CGSize
        let compact: Bool
        let readBack: String?
        let remembering: String?
        let personalizing: Bool
        let messageID: String?
        let recoveryID: UUID?
    }
    private struct MaterialKey: Equatable {
        let phase: NotchPhase
        let metrics: NotchMetrics
        let messageID: String?
        let recoveryID: UUID?
    }
    private var materialKey: MaterialKey {
        .init(phase: layoutPhase, metrics: metrics, messageID: layoutPhase == .message ? displayedMessage?.event.id : nil, recoveryID: layoutPhase == .recovery ? recovery?.content?.id : nil)
    }
    @State private var settledMaterial: MaterialKey?
    private var showsMaterial: Bool {
        usesGlass && settledMaterial == materialKey
    }
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var settledGlowID: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let hoverIdle = hovering && phase == .hidden     // the swollen click affordance — idle only
        let size = hoverIdle ? metrics.hoverSize
                             : metrics.size(for: layoutPhase, readBack: isVoice ? nil : readBack, remembering: remembering, personalizing: personalizing,
                                            recoveryContent: recovery?.content, messageContent: displayedMessage)
        let radii = hoverIdle ? metrics.hoverRadii : metrics.radii(for: layoutPhase)
        let glowScale = metrics.glowScale(for: layoutPhase)
        let visible = phase != .hidden
        // Hardware notches are bezel-flush with a skirt glow. Islands float below the bezel,
        // with convex corners and a closed glow perimeter. Both morph on the same fixed canvas.

        ZStack(alignment: .top) {
            if !islandGlassEnabled {
                glow(radii, lineWidth: 13 * glowScale, blur: 17 * glowScale, strength: 0.75)
                glow(radii, lineWidth: 6 * glowScale, blur: 6 * glowScale, strength: 0.95)
            }
            shell(radii: radii, visible: visible)
                .frame(width: size.width, height: size.height)
                .clipShape(NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom, isIsland: !metrics.hasPhysicalNotch))
                .shadow(color: .black.opacity(visible || hoverIdle ? 0.55 : 0), radius: 9, y: 3)
                .overlay {
                    if metrics.hasPhysicalNotch {
                        NotchThinkingUnderlight(visible: thinkingLightVisible,
                            protectedHeight: metrics.topRowHeight + metrics.notchBottomCover,
                            reduceMotion: reduceMotion || lowPowerMode)
                            .clipShape(NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom))
                    }
                }
                .overlay {
                    if islandGlassEnabled, metrics.hasPhysicalNotch {
                        // An overlay receives the shell's actual interpolated bounds.
                        // A sibling stack could negotiate a different size mid-morph.
                        ZStack {
                            notchLineGlow(radii, lineWidth: 10 * glowScale, blur: 12 * glowScale, strength: 0.30)
                            notchLineGlow(radii, lineWidth: 3 * glowScale, blur: 4 * glowScale, strength: 0.55)
                            notchLineGlow(radii, lineWidth: 1.4 * glowScale, blur: 0.45, strength: 1)
                        }
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if !metrics.hasHardwareCutout {
                        IslandRestingSurface(backdrop: islandBackdrop)
                            .opacity(visible ? 0 : 1)
                            .allowsHitTesting(false)
                    }
                }
                // Clickable ONLY as the hover affordance — every other state keeps the shell
                // hit-transparent (STOP / the type field stay the notch's only interactive elements).
                // The generous contentShape makes a click pinned against the screen's top edge (a point
                // ON the shape's boundary, which path hit-testing excludes) still land on the tap; the
                // window only delivers clicks over the silhouette anyway, so this over-claims nothing.
                .contentShape(Rectangle().inset(by: -4))
                .onTapGesture(perform: onNotchClick)
                .allowsHitTesting(hoverIdle)
            if islandGlassEnabled {
                if !metrics.hasPhysicalNotch {
                    IslandColorSurface(treatment: selectedColorTreatment,
                        shape: NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom,
                                          isIsland: !metrics.hasPhysicalNotch),
                        paused: materialAnimationPaused,
                        lightingStrength: underlightStrength,
                        blackBody: !usesGlass,
                        showsHalo: !metrics.hasPhysicalNotch)
                        .opacity(visible ? 1 : 0)
                }
            } else {
                glow(radii, lineWidth: 3 * glowScale, blur: 0.6 * glowScale, strength: 1)
            }
            content(size: size)
                .opacity(visible ? 1 : 0)              // icons + caption dissolve as the shell retracts into the cutout
                .blur(radius: reduceMotion || visible ? 0 : 7)
                .scaleEffect(reduceMotion || visible ? 1 : 0.97, anchor: .top)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom, isIsland: !metrics.hasPhysicalNotch))
        }
        .frame(width: size.width, height: size.height)
        .background {
            #if DEBUG
            if let observeSurfaceSize {
                Color.clear.onGeometryChange(for: CGSize.self) { $0.size } action: { observeSurfaceSize($0) }
            }
            #endif
        }
        .accessibilityElement(children: .contain)        // on the notch itself, never the full canvas
        .accessibilityLabel(a11yLabel)
        .scaleEffect(reduceMotion || visible || hoverIdle || !metrics.hasPhysicalNotch ? 1 : 0.94, anchor: .top)
        .offset(x: metrics.horizontalOffset(for: layoutPhase), y: hoverIdle ? metrics.hoverTopInset : metrics.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // One transaction owns the shell, border and content geometry throughout a handoff.
        .animation(morph, value: MorphKey(phase: phase, size: size, compact: metrics.compactMode,
            readBack: readBack, remembering: remembering, personalizing: personalizing,
            messageID: displayedMessage?.event.id, recoveryID: recovery?.content?.id))
        .animation(hoverMorph, value: hovering)          // the hover swell/settle — snappier than the phase morph
        .task(id: readingGlowID) { await settleReadingGlow() }
        .task(id: materialKey) { await settleMaterial() }
        .task(id: TypingFocusKey(phase: phase, ready: inputReady, request: focusRequest)) {
            fieldFocused = false
            guard phase == .typing, inputReady else { return }
            // Cancel a pending focus request when a click-away beats the opening.
            await Task.yield()
            guard !Task.isCancelled else { return }
            fieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    @ViewBuilder private func shell(radii: (top: CGFloat, bottom: CGFloat), visible: Bool) -> some View {
        let shape = NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom,
                               isIsland: !metrics.hasPhysicalNotch)
        ZStack {
            if metrics.hasPhysicalNotch {
                // Never replace the cheap, animatable hardware silhouette during a morph.
                shape.fill(.black)
                Group {
                    if showsMaterial && visible {
                        ZStack {
                            glassSurface(shape: shape)
                            IslandColorSurface(treatment: selectedColorTreatment, shape: shape,
                                paused: materialAnimationPaused, lightingStrength: underlightStrength,
                                showsHalo: false)
                            NotchBlackCrown(protectedHeight: (metrics.hardwareNotch?.height ?? 0) + metrics.notchBottomCover)
                                .clipShape(shape)
                        }
                        .compositingGroup()
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    }
                }
                .transaction { transaction in
                    if !showsMaterial || !visible {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
            } else {
                // Keep the same silhouette through pill → panel → pill. The live
                // material joins only after the spring; it never replaces the shell.
                shape.fill(.black.opacity(visible || (metrics.hasHardwareCutout && hovering) ? 1 : 0))
                Group {
                    if showsMaterial && visible {
                        glassSurface(shape: shape)
                            .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    }
                }
                .transaction { transaction in
                    if !showsMaterial || !visible {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
            }
        }
    }

    @ViewBuilder private func glassSurface(shape: NotchShape) -> some View {
        if reduceTransparency {
            shape.fill(Color(white: 0.075))
        } else {
            if needsBackdropBlur {
                // The native lens retints itself when its NSWindow becomes key, even
                // with appearsActive/materialActiveAppearance pinned. Reading/editing
                // surfaces instead keep the same active blur, fixed tint and spectrum.
                IslandBackdropBlur()
                    .overlay(Color.black.opacity(0.22))
                    .clipShape(shape)
                    .allowsHitTesting(false)
            } else if #available(macOS 26.0, *) {
                shape.fill(.clear)
                    .glassEffect(.clear.tint(.black.opacity(0.22)), in: shape)
                    .environment(\.colorScheme, .dark)
            }
        }
    }

    private func settleMaterial() async {
        settledMaterial = nil
        let key = materialKey
        guard usesGlass, phase != .hidden else { return }
        if !reduceMotion {
            do { try await Task.sleep(for: .milliseconds(metrics.hasPhysicalNotch ? 900 : 600)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        // Decorate only after the original spring has settled. The key also invalidates
        // the material synchronously on close, resize, or an interrupted opening.
        // Let the black notch breathe before its lower color slowly develops.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: metrics.hasPhysicalNotch ? 1.6 : 0.35)) {
            settledMaterial = key
        }
    }

    private var materialAnimationPaused: Bool {
        if reduceMotion || lowPowerMode { return true }
        switch layoutPhase {
        case .hidden, .message, .recovery: return true
        default: return false
        }
    }

    private var ambientAnimationPaused: Bool {
        if reduceMotion || lowPowerMode { return true }
        switch layoutPhase {
        case .running, .listening, .transcribing, .finishing: return false
        default: return true // no clocks behind an ordered-out panel or while reading/typing
        }
    }

    /// The same brand mark drifts slowly while waiting for a prompt. Keep the larger
    /// ambient effects paused during typing, and stop every clock when the notch is hidden.
    private var identityAnimationPaused: Bool { reduceMotion || lowPowerMode || phase == .hidden }

    private var morph: Animation {
        if phase == .hidden {
            // A bounded, monotonic retract finishes before the panel orders out.
            // Reusing the opening spring left a bouncing tail that was visibly cut short.
            return reduceMotion ? .easeOut(duration: 0.18)
                : .timingCurve(0.33, 0, 0.20, 1, duration: 0.50)
        }
        return reduceMotion ? .easeInOut(duration: 0.24) : .spring(response: 0.52, dampingFraction: 0.72)
    }

    private var hoverMorph: Animation {
        // The hover swell — a quick ease-out with one tiny overshoot at the end (the Dynamic Island
        // "press me" bounce), snappier than the phase morph. The EXIT is slower and with the bounce
        // damped out: a shrink's overshoot lands INSIDE the black cutout where it's invisible, and a
        // fully-damped spring spends its tail creeping imperceptibly — so the exit needs extra time
        // on paper for its VISIBLE portion to match the entry (tuned on Jesai's bezel).
        // (`hovering` is already the new value when this is read, so it picks the right direction.)
        if reduceMotion { return .easeOut(duration: 0.18) }
        return hovering ? .spring(response: 0.34, dampingFraction: 0.88)
                        : .spring(response: 0.52, dampingFraction: 0.95)
    }

    // MARK: Content

    @ViewBuilder private func content(size: CGSize) -> some View {
        if metrics.isCompact(for: layoutPhase) { compactContent }
        else if metrics.isInlineIsland(for: layoutPhase) { islandActivityContent(size: size) }
        else {
            // Remove outgoing native field/button views immediately. Their AppKit backing
            // views otherwise linger outside the shrinking shell during a voice transition.
            expandedContent(size: size).transition(.identity)
        }
    }

    private func islandActivityContent(size: CGSize) -> some View {
        HStack(spacing: 10) {
            NotchIdentityMark(size: controlSize, working: phase == .running || isTaskRunning || isProofreading,
                              animated: !identityAnimationPaused)
                .frame(width: controlSize, height: controlSize)
            Group {
                if isVoice || retainsTranscript {
                    NotchVoiceCaption(presentation: dictation, submittedText: retainsTranscript ? readBack : nil)
                } else { caption }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: phase == .finishing(.failed) ? 32 : metrics.captionHeight)
            HStack(spacing: 8) {
                if showsHistoryControl { conversationButton }
                rightControl.frame(width: controlSize, height: controlSize)
            }
        }
        .padding(.horizontal, metrics.hPad)
        .frame(width: size.width, height: size.height)
    }

    private var compactStatus: SidekickActivityPresentation.NotchStatus {
        if let setupCaption { return .init(text: setupCaption.rawValue, activity: nil) }
        if phase == .finishing(.success) { return .init(text: "Done", activity: nil) }
        if phase == .finishing(.stopped) { return .init(text: "Stopped", activity: nil) }
        if personalizing { return .init(text: "Learning", activity: nil) }
        if remembering != nil { return .init(text: "Reading", activity: nil) }
        return SidekickActivityPresentation.compactNotchStatus(statusLine, activity: activity)
    }

    private var compactContent: some View {
        let status = compactStatus
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Group {
                    if let activity = status.activity {
                        SidekickActivityIcon(identifier: activity.appIdentifier, symbol: activity.symbol)
                    } else {
                        NotchIdentityMark(size: controlSize, working: phase == .running, animated: !identityAnimationPaused)
                    }
                }
                .frame(width: controlSize, height: controlSize)
                Group {
                    if isVoice || retainsTranscript { NotchVoiceCaption(presentation: dictation, submittedText: retainsTranscript ? readBack : nil).frame(maxWidth: .infinity, maxHeight: 16) }
                    else { Text(status.text) }
                }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("notch.compactStatus")
            }
            .padding(.leading, metrics.compactHPad).padding(.trailing, 2)
            .frame(width: metrics.compactLeadingWidth, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status.activity.map { "\($0.appName ?? "Sidekick"), \($0.title)" } ?? status.text)
            Color.clear.frame(width: metrics.compactCameraWidth)
            HStack(spacing: 12) {
                if showsHistoryControl { conversationButton }
                else { Color.clear.frame(width: controlSize, height: controlSize) }
                rightControl.frame(width: controlSize, height: controlSize)
            }
            .padding(.trailing, metrics.compactHPad)
            .frame(width: metrics.compactTrailingWidth, alignment: .trailing)
        }
        .frame(height: metrics.compactRowHeight)
        .padding(.bottom, metrics.hasPhysicalNotch ? metrics.notchBottomCover : 0)
        .help(isVoice ? dictation.text : (readBack ?? progressCaption))
        .animation(.easeInOut(duration: 0.15), value: status.text)
    }

    private var conversationButton: some View {
        Button(action: onOpenConversation) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 13, weight: .medium))
                .frame(width: controlSize, height: controlSize)
        }
        .buttonStyle(NotchIconButtonStyle(circular: !metrics.hasPhysicalNotch))
        .help("Open conversation in Sentient")
        .accessibilityLabel("Open Sidekick conversation in Sentient")
    }

    private func openResponseButton(availableWidth: CGFloat) -> some View {
        Button(action: onOpenConversation) {
            ViewThatFits(in: .horizontal) {
                responseOpenLabel("Open in Sentient", fontSize: 11)
                responseOpenLabel("Open in Sentient", fontSize: 10)
                responseOpenLabel("Open", fontSize: 11)
            }
            .frame(width: availableWidth, height: 24)
        }
        .accessibilityLabel("Open in Sentient")
        .buttonStyle(NotchMessageButtonStyle(prominent: true))
        .accessibilityIdentifier("sidekick.notch.openConversation")
        .accessibilityHint("Open this exact response in your full conversation")
    }

    private func responseOpenLabel(_ title: String, fontSize: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.forward.app")
            Text(title)
        }
        .font(.system(size: fontSize, weight: .medium))
        .padding(.horizontal, 8)
        .fixedSize()
    }

    private func expandedContent(size: CGSize) -> some View {
        let hardwareWing = max(0, (size.width - metrics.hPad * 2 - metrics.baseWidth) / 2)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
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
                        NotchIdentityMark(size: metrics.controlSlot, working: phase == .running || isTaskRunning || isProofreading,
                            animated: !identityAnimationPaused)
                    }
                }
                .frame(width: metrics.hasHardwareIsland ? hardwareWing : nil, alignment: .leading)
                Spacer(minLength: metrics.centerGap)
                HStack(spacing: isResponseSurface ? 8 : 12) {
                    if isResponseSurface {
                        openResponseButton(availableWidth: metrics.hasHardwareCutout
                            ? max(60, (size.width - metrics.baseWidth) / 2 - metrics.hPad - metrics.controlSlot - 8)
                            : 128)
                    }
                    else if showsHistoryControl {
                        conversationButton
                    }
                    Group {
                        if isReplyVoice {
                            Button(action: onCancelDictation) { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help("Cancel dictation")
                        } else { rightControl }
                    }
                        .frame(width: metrics.controlSlot, height: metrics.controlSlot)
                        .id(controlKey)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
                }
                .frame(width: metrics.hasHardwareIsland ? hardwareWing : nil, alignment: .trailing)
            }
            .frame(height: metrics.topRowHeight)

            if metrics.hasHardwareIsland && layoutPhase != .opening {
                Color.clear.frame(height: metrics.bodyTopPad)
            }

            if isResponseSurface, let message = displayedMessage {
                SidekickNotchMessageView(message: message, isTaskRunning: isTaskRunning,
                    isTaskFinishing: isTaskFinishing,
                    onReply: onReply, onStop: onStop, onMicPress: onMicPress, onMic: onMic,
                    onSelecting: { onMessageSelecting($0, message.event.id) },
                    voice: isReplyVoice ? dictation : nil, onVoiceSend: onFinishListening, onVoiceStop: onStopListening,
                    draft: draft, replyFocused: messageReplyFocused,
                    replyingToSelection: messageReplySelection != nil,
                    onReplyFocusChanged: { onMessageReplyFocusChanged($0, message.event.id) },
                    onSend: { onMessageReplySubmit($0, message.event.id) },
                    composerCornerRadius: metrics.composerCornerRadius)
                    // Layout at the final readable width before the shell reveals it. The
                    // contents never rewrap through the intermediate notch-morph widths.
                    .frame(width: size.width - metrics.hPad * 2,
                           height: size.height - metrics.headerContentHeight - metrics.topPad - metrics.bottomPad)
                    .id(message.event.id)
                    .transition(contentReveal)
            } else if phase == .recovery, let recovery, let content = recovery.content {
                SidekickRecoveryView(recovery: recovery, content: content,
                                     layout: SidekickRecoveryLayout(content: content, metrics: metrics))
                    .id(content.id)
                    .transition(contentReveal)
            } else if layoutPhase == .typing {
                typingField
                    .disabled(!inputReady && !isVoice)
                    .transition(contentReveal)
                if metrics.quickActionsAvailable {
                    HStack(spacing: 6) {
                        notchAction("Summarize", shortcut: .summarize, identifier: "notch.summarize", action: onSummarize)
                            .help(shortcutProblems[.summarize]?.explanation ?? "Summarize your visible screen with OpenAI through Sentient (\(QuickActionShortcut.summarize.label))")
                        notchAction("Proofread", shortcut: .proofread, identifier: "notch.proofread", action: onProofread)
                            .disabled(!inputReady)
                            .help(shortcutProblems[.proofread]?.explanation ?? "Correct your selected text with OpenAI through Sentient (\(QuickActionShortcut.proofread.label))")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: metrics.quickActionsHeight)
                    .padding(.top, metrics.quickActionGap)
                    .disabled(isVoice)

                }

            } else if isVoice || retainsTranscript {
                NotchVoiceCaption(presentation: dictation, submittedText: retainsTranscript ? readBack : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if showsCaption {
                caption
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(contentReveal)
            }
        }
        .padding(.horizontal, metrics.hPad)
        .padding(.top, metrics.topPad)
        .padding(.bottom, layoutPhase == .typing ? metrics.typingBottomPad : metrics.bottomPad)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private func notchAction(_ title: String, shortcut: QuickActionShortcut, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 11, weight: .medium))
                // Menu-style key equivalent: system glyphs on the label's baseline, not mono cells.
                Text(shortcut.label).font(.system(size: 11))
                    .foregroundStyle(.white.opacity(shortcutProblems[shortcut] == nil ? 0.38 : 0.25)).accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .frame(height: 20)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Capsule())
        }
        .buttonStyle(NotchActionButtonStyle()).accessibilityIdentifier(identifier)
        .accessibilityHint(shortcutProblems[shortcut]?.explanation ?? shortcut.spokenLabel)
    }

    @ViewBuilder private var rightControl: some View {
        switch phase {
        case .typing:
            NotchSendButton(enabled: !isTaskRunning && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            help: "Send", action: submitDraft, diameter: metrics.hasPhysicalNotch ? 18 : controlSize)
        case .listening, .transcribing:
            NotchSendButton(enabled: dictation.capturing && !dictation.finalizing,
                help: "Stop and send dictation", action: onFinishListening, diameter: metrics.hasPhysicalNotch ? 18 : controlSize)
        case .running:
            // The onboarding demo is theater — nothing real to stop, so no STOP.
            if showStop { NotchStopButton(action: onStop, diameter: metrics.hasPhysicalNotch ? 18 : controlSize) } else { Color.clear.frame(width: 1, height: 18) }
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
            .buttonStyle(NotchIconButtonStyle(circular: !metrics.hasPhysicalNotch))
            .help("Hide response")
            .accessibilityLabel("Hide response. It stays in your conversation history.")
        case .notice where isProofreading:
            NotchStopButton(action: onStop, diameter: metrics.hasPhysicalNotch ? 18 : controlSize)
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
            if let error = dictation.error {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.white.opacity(0.65)).help(error).accessibilityLabel(error)
            }
            ZStack(alignment: .leading) {
                if isVoice && dictation.composedText(dictation.text).isEmpty {
                    PromptDictationWaveform(levels: dictation.levels)
                } else if !isVoice && draftText.isEmpty {
                    // The field's own face: typing replaces the prompt in place, with no face or baseline jump.
                    Text(dictation.error ?? "What can I take over for you?")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(usesGlass ? 0.5 : 0.4))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: isVoice ? Binding(get: { dictation.composedText(dictation.text) }, set: { _ in }) : draftBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .focused($fieldFocused)
                    .onSubmit { if isVoice { onFinishListening() } else { submitDraft() } }
                    .disabled(isVoice)
                    .opacity(isVoice && dictation.composedText(dictation.text).isEmpty ? 0 : 1)
                    .accessibilityLabel("Message Sidekick")
            }
            ZStack {
                if isVoice || draftText.isEmpty {
                    NotchMicrophoneButton(onPress: { if isVoice { onStopListening() } else { onMicPress() } },
                        onActivate: { if isVoice { onStopListening() } else { onMic() } }, recording: isVoice)
                        .frame(width: 18, height: 18).disabled(dictation.finalizing)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .frame(width: metrics.controlSlot, height: metrics.controlSlot)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8), value: draftText.isEmpty)
        }
        // The mic slot's glyph sits inset, so the trailing edge is shorter to balance the text inset.
        .padding(.leading, 12).padding(.trailing, 7)
        .frame(height: metrics.fieldRowHeight)
        .notchComposerGlass(cornerRadius: metrics.composerCornerRadius, focused: fieldFocused)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: dictation.text.isEmpty)
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
        switch layoutPhase {
        case .typing, .running, .message, .recovery: true
        default: false
        }
    }


    /// Read-back dissolves into the same app icon and readable activity used in chat.
    @ViewBuilder private var caption: some View {
        switch phase {
        case .running:
            Group {
                if let setupCaption {
                    HStack(spacing: 6) {
                        Text(setupCaption.rawValue)
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("notch.permissionSetup")
                } else if personalizing {
                    Text("Personalizing Sidekick…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Self.rememberingGradient)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Personalizing Sidekick")
                } else if let remembering {
                    rememberingCaption(remembering)                 // gradient, blooming "Remembering" + the note
                } else if let readBack {
                    Text(readBack)
                        .font(.system(size: 13, weight: .medium))
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
                                .font(.system(size: metrics.hasPhysicalNotch ? 12 : 13, weight: metrics.hasPhysicalNotch && shownActivity == nil ? .regular : .medium))
                                .lineLimit(metrics.hasPhysicalNotch && shownActivity == nil ? 2 : 1).truncationMode(.tail)
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
        if let setupCaption { return .init(text: setupCaption.rawValue, activity: nil) }
        return SidekickActivityPresentation.notchStatus(statusLine, activity: activity)
    }
    private var shownActivity: SidekickActivityPresentation.Step? { notchStatus.activity }
    private var progressCaption: String { notchStatus.text }

    /// Distinct identities let personalization, remembering, read-back and progress blur-dissolve.
    /// (note / status changes WITHIN a state morph in place instead).
    private var runningCaptionKey: Int {
        if let setupCaption { return setupCaption == .computerUse ? 5 : 4 }
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
                Text(rememberingLabel)
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

    private func notchLineGlow(_ radii: (top: CGFloat, bottom: CGFloat),
                               lineWidth: CGFloat, blur: CGFloat, strength: Double) -> some View {
        glowLayer(radii, lineWidth: lineWidth, blur: blur, refined: true)
            .opacity((0.38 + 0.55 * underlightStrength) * strength)
            .allowsHitTesting(false)
    }

    /// The rotating spectrum, MASKED by the notch-skirt stroke. The mask shape lives in the regular body
    /// (NOT inside the TimelineView), so its geometry interpolates in LOCKSTEP with the black fill during
    /// a morph — the edges light up in place, never a separate rounded-rect snapping on. The layer is
    /// always present; its brightness rides `glowStrength` via opacity. Only the gradient ANGLE ticks
    /// per-frame; the skirt (sides + rounded bottom, no top) keeps the glow off the bezel line.
    private func glowLayer(_ radii: (top: CGFloat, bottom: CGFloat),
                           lineWidth: CGFloat, blur: CGFloat, refined: Bool = false) -> some View {
        // The gradient must extend PAST the stroke + blur on every edge — including the bottom, which sits
        // right at the notch's frame edge. So we grow the layer (negative padding) and inset the skirt mask
        // by the same margin: the gradient then bleeds beyond ALL sides equally (no thin bottom edge).
        let m = lineWidth / 2 + blur + 6
        let rotationPeriod = refined ? 12 : metrics.glowRotationPeriod(for: layoutPhase)
        let colors: [Color] = refined ? [
            Color(red: 0.45, green: 0.65, blue: 1),
            Color(red: 0.70, green: 0.48, blue: 0.95),
            Color(red: 0.95, green: 0.48, blue: 0.67),
            Color(red: 1, green: 0.72, blue: 0.40),
            Color(red: 0.92, green: 0.81, blue: 0.69),
            Color(red: 0.45, green: 0.65, blue: 1),
        ] : GlowHalo.stops
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: ambientAnimationPaused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = ambientAnimationPaused ? 0 : (t.truncatingRemainder(dividingBy: rotationPeriod) / rotationPeriod) * 360
            let breathe = ambientAnimationPaused ? 0.5 : (sin(t * 2 * .pi / 3.2) + 1) / 2
            AngularGradient(colors: colors, center: .center, angle: .degrees(angle))
                .opacity(0.88 + 0.12 * breathe)
        }
        .mask(
            NotchSkirtShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom, isIsland: !metrics.hasPhysicalNotch)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .padding(m)
        )
        .blur(radius: blur)
        .padding(-m)
    }

    /// Key the arrival to the presented content so drafting and preference changes
    /// cannot replay the glow. SwiftUI cancels the settling task when content changes.
    private var readingGlowID: String? {
        if let setupCaption { return "setup:\(setupCaption.rawValue)" }
        switch layoutPhase {
        case .message: return displayedMessage.map { "message:\($0.event.id)" }
        case .recovery: return recovery?.content.map { "recovery:\($0.id.uuidString)" }
        case .finishing(let outcome): return "finished:\(Self.outcomeSymbol(outcome))"
        case .notice(let text): return "notice:\(text)"
        default: return nil
        }
    }

    private var underlightStrength: Double {
        guard phase != .hidden else { return 0 }
        if let id = readingGlowID, id != settledGlowID, !reduceMotion, !lowPowerMode { return 1 }
        switch layoutPhase {
        case .running, .opening, .transcribing: return 0.20
        case .typing, .listening: return 0.40
        default: return 0.28
        }
    }

    private func settleReadingGlow() async {
        guard let id = readingGlowID else { settledGlowID = nil; return }
        guard settledGlowID != id else { return }
        guard !reduceMotion, !lowPowerMode else { settledGlowID = id; return }
        do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.65)) { settledGlowID = id }
    }

    private var glowStrength: Double {
        switch layoutPhase {
        case .hidden:    return 0
        case .message, .recovery:
            guard let id = readingGlowID, !reduceMotion, !lowPowerMode else { return 0.5 }
            return settledGlowID == id ? 0.5 : 1
        case .finishing: return 0.9
        default:         return 1.0
        }
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
        case .listening: return "Sentient is listening. Release the notch, click stop, or press Return to send."
        case .transcribing: return "Sentient is transcribing"
        case .running: return "Sentient is working. \(metrics.isCompact(for: phase) ? compactStatus.text : progressCaption)"
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
        SpinningLogo(size: size, fast: working, paused: reduceMotion || !animated)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct NotchIconButtonStyle: ButtonStyle {
    var circular = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 1 : (hovering ? 0.96 : 0.58)))
            .background {
                if circular {
                    Circle().fill(.white.opacity(hovering ? 0.09 : 0)).padding(-4)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(hovering ? 0.09 : 0)).padding(-4)
                }
            }
            .contentShape(Rectangle().inset(by: -5))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.13), value: hovering)
    }
}

/// The running STOP: a circle, because it interrupts the work.
private struct NotchStopButton: View {
    let action: () -> Void
    var diameter: CGFloat = 18
    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: diameter > 18 ? 10 : 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
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
    var diameter: CGFloat = 18
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: diameter > 18 ? 11 : 10, weight: .bold))
                .foregroundStyle(enabled ? Color.black : .white.opacity(0.3))
                .frame(width: diameter, height: diameter)
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

extension View {
    /// The notch's input field: a thin pane lit from above, a whisper of fill under a hairline
    /// that is brighter on its top edge. Focus lifts the hairline.
    func notchComposerGlass(cornerRadius: CGFloat, focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(LinearGradient(colors: [.white.opacity(0.085), .white.opacity(0.035)],
                                         startPoint: .top, endPoint: .bottom), in: shape)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(focused ? 0.34 : 0.22),
                                                           .white.opacity(focused ? 0.14 : 0.07)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
            }
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct NotchActionButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 1 : hovering ? 0.85 : 0.58))
            .background(.white.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0.025), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(hovering ? 0.16 : 0.07), lineWidth: 0.5) }
            .onHover { hovering = $0 }
    }
}
