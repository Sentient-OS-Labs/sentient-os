//
//  NotchWindowController.swift
//  Sentient OS macOS
//
//  Hosts the notch overlay in a borderless, non-activating NSPanel that floats above the menu bar and
//  over fullscreen apps. The overlay lives on the display the interaction chose (coordinator.notchAnchor):
//  the hotkey and the home command bar anchor to the MAIN (menu-bar) display; hovering/clicking the
//  physical notch anchors to the built-in display's real cutout — so the notch stays a button even when
//  an external display is primary.
//
//  ‼️ Fixed-canvas overlay (DynamicNotch's approach): a stable window, larger than the biggest notch
//  state, pinned with its top flush at the screen's edge. It NEVER resizes during a morph — the notch
//  shape animates INSIDE it — so the notch can never detach from the bezel mid-animation. Click-through
//  is guaranteed by toggling window-level `ignoresMouseEvents` by CURSOR POSITION: the window only stops
//  ignoring the mouse while the cursor is over the actual notch SILHOUETTE (running/typing/hovering) — so
//  every other point, INCLUDING the glow bloom's drawn pixels, passes straight through. (A static hitTest
//  can't do this: macOS catches a click on ANY non-transparent pixel — the glow — before hitTest can pass
//  it on, and a nil hitTest then SWALLOWS it rather than passing through.) Main canvas ordered OUT when idle; notchless displays retain a tiny static launcher.
//
//  Also owns the HOVER affordance (the notch as a button): zero-permission `.mouseMoved` NSEvent
//  monitors detect the cursor entering the hardware cutout while idle → haptic tick + the shell swells
//  (rendered by NotchView off coordinator.notchHovering) → a click opens tap-to-type. Real-notch
//  displays use their hardware cutout; notchless displays use NotchEntryHandle. Exit and click-through
//  ride the same cursor poll as running/typing.
//

import SwiftUI
import AppKit

@MainActor
final class NotchWindowController {
    private let coordinator: CommandCoordinator
    private var panel: NotchPanel?
    private var host: NotchHostingView?
    private var entryHandles: [CGDirectDisplayID: NotchEntryHandle] = [:]
    private var hoverDisplayID: CGDirectDisplayID?

    private var baseMetrics = NotchMetrics(hardwareNotch: nil)
    private var metrics: NotchMetrics {
        baseMetrics.showingSetup(coordinator.setupCaption != nil).showingQuickActions(coordinator.quickActionsAvailable)
    }
    /// Which display the current `metrics` were derived from — the anchor can move the overlay between
    /// displays (a notch-click session vs the hotkey's main-display session), and landing on a new
    /// screen must re-derive the metrics for its bezel (real cutout vs the notch-less fallback pill).
    private var metricsDisplayID: CGDirectDisplayID = 0
    private var observers: [NSObjectProtocol] = []
    private var sizeToken = 0
    /// Polls the cursor while interactive to toggle `ignoresMouseEvents` (silhouette-only click-through).
    /// Two-tier rate — crisp near the notch, lazy when the cursor is far (see `retuneMouseTimer`).
    private var mouseTimer: Timer?
    /// The live poll rate, so re-tuning only rebuilds the timer on an actual tier change.
    private var mouseTimerInterval: TimeInterval = 0
    /// Local key monitor: Esc cancels the notch's pending input (type field / voice capture). See §4.
    private var keyMonitor: Any?
    /// Hover entry detection: `.mouseMoved` NSEvent monitors, global + local — the same zero-permission
    /// pattern as the hotkey (mouse monitors are not keyboard-class; zero TCC contact). They only ever
    /// BEGIN a hover; exit + click-through are the cursor poll's job while the swell is up.
    private var hoverMonitors: [Any] = []
    private var clickMonitors: [Any] = []
    /// Retries the hover-monitor install until the app has finished launching (lesson 14 — an NSEvent
    /// monitor registered mid-NSApplicationMain wedges event routing for the life of the process).
    private var hoverInstallTimer: Timer?
    /// The cursor is over the idle notch — the shell is swollen and clickable.
    private var hovering = false
    /// The hardware notch cutout in screen coords — the hover ENTRY zone, cached so the per-mouse-move
    /// idle check is a bare rect test (recomputed only on build + display changes). `.null` = no notch.
    private var hoverEntryRect: NSRect = .null
    private var notchClickEnabled = NotchPreferences.clickEnabled()

    /// Extra room around the largest notch state so the morph's bounce-overshoot + the glow bloom never
    /// clip at the fixed window's edge. The notch is centered + top-anchored inside this canvas.
    private static let canvasHSlack: CGFloat = 140
    private static let canvasVSlack: CGFloat = 90
    /// After going hidden, wait for the SwiftUI retract animation to fully play (the shell collapses into the
    /// cutout and merges) before ordering the window out — so the window never hard-cuts a still-visible notch.
    private static let settleDelay: Double = 0.56

    /// Re-asserted on EVERY reveal — macOS drops `.canJoinAllSpaces` when a window is re-ordered, which
    /// otherwise strands the overlay on a single Space. (.fullScreenAuxiliary → also over fullscreen apps.)
    private static let collectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

    init(coordinator: CommandCoordinator) { self.coordinator = coordinator }

    #if DEBUG
    private var stoppedForTesting = false
    /// Observation only: lets the isolated UI lab capture the exact production panel.
    var panelForTesting: NSPanel? { panel }
    func mouseDownForTesting(at point: NSPoint) { notchMouseDown(at: point) }
    func hoverEntryForTesting(displayID: CGDirectDisplayID) {
        guard coordinator.phase == .hidden, !hovering else { return }
        beginHover(on: displayID)
    }
    var islandPanelsForTesting: [CGDirectDisplayID: NSPanel] {
        entryHandles.filter { $0.value.isIsland }.mapValues(\.panel)
    }
    var entryPanelsForTesting: [CGDirectDisplayID: NSPanel] { entryHandles.mapValues(\.panel) }
    /// Only the isolated UI fixture calls this; ordinary app lifecycle is unchanged.
    func shutdownForTesting() {
        stoppedForTesting = true
        sizeToken &+= 1
        coordinator.notchPress.cancel()
        stopMouseTracking()
        hoverInstallTimer?.invalidate(); hoverInstallTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        hoverMonitors.forEach { NSEvent.removeMonitor($0) }; hoverMonitors.removeAll()
        clickMonitors.forEach { NSEvent.removeMonitor($0) }; clickMonitors.removeAll()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        if hovering { hovering = false; coordinator.setNotchHovering(false) }
        panel?.orderOut(nil); panel?.contentView = nil; panel?.close()
        panel = nil; host = nil
        entryHandles.values.forEach { $0.close() }; entryHandles.removeAll()
    }
    var resourcesReleasedForTesting: Bool {
        panel == nil && host == nil && mouseTimer == nil && hoverInstallTimer == nil
            && entryHandles.isEmpty && keyMonitor == nil && hoverMonitors.isEmpty && clickMonitors.isEmpty && observers.isEmpty
    }
    #endif

    func start() {
        Task { @MainActor [weak self] in
            #if DEBUG
            guard self?.stoppedForTesting != true else { return }
            #endif
            self?.build()
            self?.installObservers()
            self?.installKeyMonitor()
            self?.installHoverMonitorsWhenReady()
            self?.observePhase()
            self?.applyPhase()          // sync the initial state (hidden → stays ordered out)
        }
    }

    /// Esc and ⏎ handling is LOCAL-ONLY (a global keyDown tap is exactly what Input Monitoring gates —
    /// never add one): this monitor sees them whenever events route to Sentient — the focused type field
    /// (where it consumes Esc *before* the text field so dismissing never beeps) and any notch state
    /// while a Sentient window is frontmost. Esc cancels; ⏎ while the mic is open ends the recording and
    /// fires (the keyboard twin of the field row's stop button; in the type field ⏎ is left to the
    /// field's own submit). Over OTHER apps, a fresh hotkey press is the cancel instead
    /// (CommandCoordinator.hotkeyPressed). A LOCAL monitor needs no permission (it only sees events
    /// already routed to us); a `true` return means the coordinator handled the key → we swallow it
    /// (nil) so nothing else also acts on it.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode   // keep the non-Sendable event off-isolation
            let windowNumber = event.windowNumber
            let consumed: Bool
            switch code {
            case 53:
                consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    // Home owns Escape for search, menus and text editing. Dismissing those
                    // must never stop a task that happens to be preparing in the notch.
                    if self.coordinator.run.conversation.isVisible, windowNumber != self.panel?.windowNumber { return false }
                    return self.coordinator.cancelCurrent()
                }
            case 36, 76:  consumed = MainActor.assumeIsolated { self?.coordinator.finishListening() ?? false } // Return · keypad Enter
            default:      return event
            }
            return consumed ? nil : event
        }
    }

    // MARK: Build (created hidden — applyPhase reveals it only when active)

    private func build() {
        guard panel == nil, let screen = Self.menuBarScreen() else { return }
        baseMetrics = Self.metrics(for: screen)
        metricsDisplayID = screen.displayID
        refreshHoverEntryRect()
        let frame = windowFrame(for: canvasSize, on: screen)
        let panel = NotchPanel(contentRect: frame,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("sentient.notch")
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.level = .mainMenu + 3
        panel.collectionBehavior = Self.collectionBehavior
        // (sharingType left at default → the notch IS visible to screen capture, so it shows up in
        //  screen recordings / demos. Trade-off: the computer-use agent may see it in its screenshots.)
        let host = NotchHostingView(coordinator: coordinator, metrics: metrics, displayID: screen.displayID)
        host.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = host
        self.panel = panel
        self.host = host
        rebuildEntryHandles()
    }

    // MARK: Phase → window presence + size

    private func observePhase() {
        #if DEBUG
        guard !stoppedForTesting else { return }
        #endif
        withObservationTracking {
            _ = coordinator.proofread.isCapturingSelection
            _ = coordinator.proofread.isRunning
            _ = coordinator.notchButtonAvailable
            _ = coordinator.phase
            _ = coordinator.notchAnchor
            _ = coordinator.notchFocusRequest
            _ = coordinator.setupCaption
            _ = coordinator.messageReplyFocused
            _ = coordinator.run.recovery.isPending // refresh return zones when a hidden question expires
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.applyPhase()
                self.observePhase()     // re-arm
            }
        }
    }

    private func applyPhase() {
        #if DEBUG
        guard !stoppedForTesting else { return }
        #endif
        guard let panel else { return }
        if coordinator.phase == .typing, coordinator.proofread.captureWasInterrupted {
            coordinator.dismissTyping(); return
        }
        host?.update(metrics: metrics, islandBackdrop: entryHandles[metricsDisplayID]?.backdrop, displayID: metricsDisplayID)
        refreshHoverEntryRect()
        syncEntryHandles()
        sizeToken &+= 1
        let token = sizeToken

        // The hover affordance is idle-only: the instant the notch opens for real (a hotkey press,
        // a click landing in .typing, a notice), hover yields — the phase owns the shape now, and
        // the window is already up so there's nothing to choreograph. The panel is KEY only for
        // .typing and .listening (see reveal); .opening never takes it — a double tap must leave
        // keyboard focus in the user's own app for Double Tap's paste.
        if coordinator.phase != .hidden, hovering { clearHover() }

        // Click-through: while interactive, a cursor poll lets the window receive clicks ONLY over the
        // notch silhouette (the glow + canvas always pass through); otherwise the whole window ignores
        // the mouse so every click sails past. Hovering counts as interactive — the same poll also
        // detects the cursor LEAVING the hover zone (updateMousePassthrough → endHover).
        if Self.isInteractive(coordinator.phase) || coordinator.proofread.isRunning || hovering {
            startMouseTracking()
        } else {
            stopMouseTracking()
            panel.ignoresMouseEvents = true
        }

        if coordinator.phase != .hidden {
            placeCanvas()                                   // the fixed canvas — NEVER resized per morph
            reveal(makeKey: wantsKey)
            if coordinator.phase == .recovery { coordinator.run.recovery.setFocused(panel.isKeyWindow) }
            syncEntryHandles()
        } else if !hovering {
            panel.resignKey()
            // Order the window out only AFTER the SwiftUI retract animation has played.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.settleDelay))
                guard let self, self.sizeToken == token, self.coordinator.phase == .hidden,
                      !self.hovering else { return }
                self.panel?.orderOut(nil)
                self.syncEntryHandles()
            }
        }
    }

    /// Show the panel and pin it everywhere: re-assert `collectionBehavior` (so it joins ALL Spaces),
    /// order front, then move it into SkyLight's top-level notch space (so it stays FIXED over the notch
    /// and never slides during the Spaces swipe). SkyLight is best-effort; the public behavior is the
    /// fallback if it's unavailable.
    ///
    /// `makeKey` makes the panel KEY so its text field can take keystrokes (and, while the mic is
    /// open, so Esc and ⏎ still reach the local key monitor) — it's a non-activating panel, so this
    /// never brings the app forward over whatever you're using. Any OTHER reveal from a panel that
    /// is still key (⏎ just submitted a typed task; a double tap landed inside the dismiss settle
    /// of a field) first drops it: ordered out and straight back in, inside one run-loop pass, so no
    /// frame is drawn without the notch. The user's own app has its keyboard back while the agent
    /// works, and Double Tap's ⌘V lands in their reply box, never in us.
    private func reveal(makeKey: Bool = false) {
        guard let panel else { return }
        panel.collectionBehavior = Self.collectionBehavior
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            if panel.isKeyWindow, coordinator.phase != .recovery && coordinator.phase != .message { panel.orderOut(nil) }
            panel.orderFrontRegardless()
        }
        NotchSpace.shared?.pin(panel)
    }

    /// The phases that own the keyboard: the type field, and the open mic (Esc cancels, ⏎ finishes).
    private var wantsKey: Bool {
        guard NSApp.modalWindow == nil, !coordinator.proofread.isCapturingSelection, !coordinator.proofread.isRunning else { return false }
        return coordinator.phase == .typing || coordinator.phase == .listening
            || (coordinator.phase == .transcribing && coordinator.dictation.keepsDraft)
            || (coordinator.phase == .message && coordinator.messageReplyFocused)
    }

    // MARK: Geometry

    /// The fixed window size: big enough for the widest/tallest notch state plus slack. It only changes
    /// on a display/notch change — never during a morph — so the notch stays pinned to the bezel.
    private var canvasSize: CGSize {
        let phases: [NotchPhase] = [.opening, .listening, .transcribing, .typing, .running, .recovery, .message, .notice("")]
        let maxW = phases.map { metrics.size(for: $0).width }.max() ?? 360
        let baseMaxH = phases.map { metrics.size(for: $0).height }.max() ?? 100
        let maxH = max(baseMaxH, metrics.runningHeight(caption: metrics.maxReadBackCaptionHeight))   // tallest read-back
        return CGSize(width: maxW + Self.canvasHSlack, height: maxH + Self.canvasVSlack)
    }

    private func windowFrame(for size: CGSize, on screen: NSScreen) -> NSRect {
        let x = floor(screen.frame.midX - size.width / 2)
        let y = screen.frame.maxY - size.height   // window top flush with the screen's top edge
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Size + center the fixed canvas at the ACTIVE display's notch position (no-op if already there).
    /// Landing on a different display than the metrics were derived for re-derives them first — so a
    /// notch-click session gets the built-in bezel's real cutout (retract-merge, true radii) while a
    /// hotkey session on a notch-less primary keeps the fallback pill.
    private func placeCanvas() {
        guard let panel, let screen = activeScreen() else { return }
        let movedDisplay = screen.displayID != metricsDisplayID
        if movedDisplay { panel.orderOut(nil) }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = movedDisplay
        withTransaction(transaction) {
            if movedDisplay {
                baseMetrics = Self.metrics(for: screen)
                metricsDisplayID = screen.displayID
            }
            let frame = windowFrame(for: canvasSize, on: screen)
            if panel.frame != frame {
                panel.setFrame(frame, display: false, animate: false)
                host?.frame = NSRect(origin: .zero, size: frame.size)
            }
            if movedDisplay {
                host?.update(metrics: metrics, islandBackdrop: entryHandles[screen.displayID]?.backdrop,
                             displayID: screen.displayID)
            }
        }
    }

    /// Re-derive the metrics for a screen and re-render the host with them.
    private func applyMetrics(for screen: NSScreen) {
        baseMetrics = Self.metrics(for: screen)
        metricsDisplayID = screen.displayID
        host?.update(metrics: metrics, islandBackdrop: entryHandles[screen.displayID]?.backdrop, displayID: screen.displayID)
    }

    // MARK: Click-through (silhouette-only, by cursor position)

    /// The phases with something to click: the running STOP, the type field and its mic, the
    /// listening stop button and recovery controls. Transcribing rides along so a click mid-finalize is
    /// absorbed rather than passed to whatever sits under it.
    private static func isInteractive(_ phase: NotchPhase) -> Bool {
        switch phase {
        case .running, .typing, .listening, .transcribing, .recovery, .message: return true
        default: return false
        }
    }

    /// Poll tiers: crisp while the cursor is anywhere near the notch (inside the canvas), lazy when
    /// it's across the screen — the far tick is just "did they come back?" (one rect test), so timer
    /// wakeups drop 6× during long computer-use runs. The always-on hover monitors bump far → near
    /// the instant the cursor re-approaches, so the lazy tier never delays a real interaction.
    private static let pollNear: TimeInterval = 1.0 / 60.0
    private static let pollFar: TimeInterval = 1.0 / 10.0

    /// Start (or keep) the cursor poll at the rate the cursor's position deserves. Idempotent.
    private func startMouseTracking() {
        updateMousePassthrough()
        retuneMouseTimer()
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        mouseTimerInterval = 0
    }

    /// Each tick re-checks passthrough, then re-tunes its own rate by proximity.
    private func mouseTick() {
        updateMousePassthrough()
        if mouseTimer != nil { retuneMouseTimer() }   // a hover exit may have just stopped the poll
    }

    /// (Re)build the poll timer when the proximity tier changes. `.common` mode so it keeps ticking
    /// during tracking loops; tolerance lets the system coalesce wakeups for energy.
    private func retuneMouseTimer() {
        let interval = cursorNearNotch() ? Self.pollNear : Self.pollFar
        guard mouseTimerInterval != interval else { return }
        mouseTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseTick() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
        mouseTimerInterval = interval
    }

    /// The "near" zone — the fixed canvas plus a hair ABOVE the screen's top edge. ⚠️ `NSRect.contains`
    /// excludes the max edge, and a cursor slammed against the top of the screen reports EXACTLY that
    /// boundary y — without the overhang, the proximity gate goes click-dead along the notch's top edge
    /// (the same half-open trap the hover entry rect dodges with its own +2).
    private var nearZone: NSRect {
        guard let panel else { return .null }
        let size = metrics.size(for: coordinator.dictation.layoutPhase(for: coordinator.phase),
            readBack: coordinator.readBack, messageContent: coordinator.dictation.replyMessage ?? coordinator.notchMessage)
        let width = max(size.width, metrics.hoverSize.width) + Self.canvasHSlack
        return NSRect(x: panel.frame.midX - width / 2, y: panel.frame.maxY - size.height - 80,
                      width: width, height: size.height + 82)
    }

    /// Cheap proximity test — the canvas (biggest notch state + slack) IS the "near" zone.
    private func cursorNearNotch() -> Bool {
        nearZone.contains(NSEvent.mouseLocation)
    }

    /// The window receives the mouse ONLY while the cursor is over the live notch silhouette; everywhere
    /// else (glow, canvas) it ignores the mouse, so those clicks pass straight through. While hovering,
    /// the same tick doubles as the LEAVE detector (the mouseMoved monitors only ever begin a hover).
    private func updateMousePassthrough() {
        guard let panel else { return }
        if hovering, coordinator.phase == .hidden, !coordinator.notchPress.isTracking, !cursorStillHovering() { endHover(); return }
        if coordinator.notchPress.isTracking {
            panel.ignoresMouseEvents = false
            return
        }
        let interactive = Self.isInteractive(coordinator.phase) || coordinator.proofread.isRunning || (hovering && coordinator.phase == .hidden)
        // The canvas box gates the EXPENSIVE silhouette test (a Path build + the read-back text
        // measurement): a far cursor can't be over the silhouette, so it never pays for one.
        let receive = interactive && cursorNearNotch() && cursorOverSilhouette()
        if coordinator.phase == .recovery { coordinator.run.recovery.setHovering(receive) }
        if coordinator.phase == .message { coordinator.setMessagePreviewHovering(receive) }
        if panel.ignoresMouseEvents == receive { panel.ignoresMouseEvents = !receive }
    }

    /// Is the cursor over the actual notch shape right now? Works in screen coordinates (no view-flip
    /// guesswork): a bounding-box early-out, then the exact `NotchShape` path test. During a hover the
    /// live silhouette is the swollen hover shape, not the phase's.
    private func cursorOverSilhouette(at location: NSPoint? = nil) -> Bool {
        guard let screen = activeScreen() else { return false }
        let hoverIdle = hovering && coordinator.phase == .hidden
        let s = hoverIdle ? metrics.hoverSize
                          : metrics.size(for: coordinator.dictation.layoutPhase(for: coordinator.phase), readBack: coordinator.readBack,
                                         remembering: coordinator.run.remembering,
                                         personalizing: coordinator.run.isPersonalizing,
                                         recoveryContent: coordinator.run.recovery.content,
                                         messageContent: coordinator.dictation.replyMessage ?? coordinator.notchMessage)
        let p = location ?? NSEvent.mouseLocation            // screen coords, origin bottom-left
        let localX = p.x - (screen.frame.midX + metrics.horizontalOffset(for: coordinator.dictation.layoutPhase(for: coordinator.phase)) - s.width / 2)
        let visualInset = hoverIdle ? metrics.hoverTopInset : metrics.topInset
        let depthFromTop = screen.frame.maxY - visualInset - p.y
        if metrics.hasHardwareIsland, depthFromTop >= -visualInset, depthFromTop <= metrics.hardwareMenuHeight - visualInset,
           abs(p.x - screen.frame.midX - metrics.cameraCenterOffset) <= metrics.baseWidth / 2 {
            // Keep the hardware camera band usable from the screen edge, even though
            // the rounded visual sits a little below it. Neighboring menu items pass through.
            return true
        }
        if hoverIdle && !metrics.hasHardwareCutout {
            // Match the resting handle's generous target after the live canvas takes over.
            return localX >= 0 && localX <= s.width && depthFromTop >= -6 && depthFromTop <= s.height + 6
        }
        guard localX >= 0, localX <= s.width, depthFromTop >= 0, depthFromTop <= s.height else { return false }
        let radii = hoverIdle ? metrics.hoverRadii : metrics.radii(for: coordinator.dictation.layoutPhase(for: coordinator.phase))
        // ⚠️ Fitts's law at the bezel: a cursor slammed against the screen's top edge reports depth ≈ 0 —
        // a point ON the path's boundary, which `contains` excludes — so the top edge of the notch went
        // click-dead. Test a couple of points INTO the shape instead: the screen edge itself is part of
        // the notch (macOS's own menu bar works this way).
        return NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom, isIsland: !metrics.hasPhysicalNotch)
            .path(in: CGRect(x: 0, y: 0, width: s.width, height: s.height))
            .contains(CGPoint(x: localX, y: max(depthFromTop, 2)))
    }

    // MARK: Hover — the notch as a button (swell + haptic; click opens tap-to-type)

    /// Install now if the app is already running, else retry on a short tick. ⚠️ Lesson 14: an NSEvent
    /// monitor registered during app init (NSApp can still be nil, mid-NSApplicationMain) wedges the
    /// app's event routing for the LIFE of the process — and a Timer can only fire once the run loop
    /// is pumping, i.e. post-launch by construction, so the tick path is safe by shape.
    private func installHoverMonitorsWhenReady() {
        installHoverMonitors()
        guard hoverMonitors.isEmpty, hoverInstallTimer == nil else { return }
        hoverInstallTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.installHoverMonitors()
                if !self.hoverMonitors.isEmpty {
                    self.hoverInstallTimer?.invalidate()
                    self.hoverInstallTimer = nil
                }
            }
        }
    }

    /// The `.mouseMoved` monitors — ENTRY detection only, so the idle cost is one rect test per mouse
    /// move (no timers, no polling while idle). Global hears moves over other apps; local hears them
    /// whenever Sentient itself is frontmost. Mouse monitors are not keyboard-class: zero TCC contact.
    private func installHoverMonitors() {
        #if DEBUG
        guard !stoppedForTesting else { return }
        #endif
        guard hoverMonitors.isEmpty, NSApp?.isRunning == true else { return }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.hoverMouseMoved(at: Self.screenLocation(of: event))
        })
        if let global { hoverMonitors.append(global) }
        let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.hoverMouseMoved(at: Self.screenLocation(of: event))
            return event
        })
        if let local { hoverMonitors.append(local) }
        if clickMonitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.notchMouseDown(at: Self.screenLocation(of: event))
            }) { clickMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                guard let self else { return event }
                let location = Self.screenLocation(of: event)
                // Entry handles are explicit destinations, not clicks away from the old panel.
                if self.entryHandles.values.contains(where: { event.window === $0.panel }) { return event }
                if event.type == .leftMouseDown, event.window === self.panel,
                   self.coordinator.notchButtonAvailable, self.cursorOverSilhouette(at: location),
                   ((self.hovering && self.coordinator.phase == .hidden)
                    || self.isVoiceHeader(at: location)) {
                    self.coordinator.notchMouseDown(anchor: self.coordinator.phase == .hidden ? self.pointerAnchor : self.coordinator.notchAnchor)
                    return nil
                }
                self.notchMouseDown(at: location)
                return event
            }) { clickMonitors.append(local) }
        }
        if !hoverMonitors.isEmpty {
            Log("notch hover affordance armed (mouseMoved NSEvent monitors, zero-permission)")
        }
    }

    private func isVoiceHeader(at location: NSPoint) -> Bool {
        guard coordinator.phase == .message || coordinator.phase == .typing,
              let screen = activeScreen() else { return false }
        let depth = screen.frame.maxY - metrics.topInset - location.y
        // Center-only header target keeps the logo and right-side buttons clickable.
        let width = metrics.hardwareNotch?.width ?? 100
        return depth >= (metrics.hasHardwareIsland ? -metrics.topInset : 0)
            && depth <= (metrics.hasHardwareIsland ? metrics.hardwareMenuHeight - metrics.topInset : metrics.topRowHeight)
            && abs(location.x - screen.frame.midX - metrics.cameraCenterOffset) <= width / 2
    }

    private func notchMouseDown(at location: NSPoint) {
        guard let panel, panel.isVisible, NSApp.modalWindow == nil else { return }
        // Ignore off-display automation focus probes. A real outside click begins
        // dismissal synchronously, independent of key-window setup or focus notifications.
        guard NSScreen.screens.contains(where: {
            location.x >= $0.frame.minX && location.x <= $0.frame.maxX
                && location.y >= $0.frame.minY && location.y <= $0.frame.maxY
        }) else { return }
        if cursorOverSilhouette(at: location) {
            if coordinator.phase == .recovery {
                panel.makeKey()
                coordinator.run.recovery.setFocused(true)
            }
            return
        }
        switch coordinator.phase {
        case .typing: coordinator.dismissTyping()
        case .opening: _ = coordinator.cancelCurrent()
        case .message: coordinator.dismissMessagePreview()
        case .recovery: coordinator.run.recovery.dismiss()
        case .listening, .transcribing:
            if !coordinator.notchPress.isTracking { _ = coordinator.cancelCurrent() }
        default: break // Ordinary app clicks must never stop an active Sidekick task.
        }
    }

    /// The event's own screen-coord location — spares a per-move window-server query
    /// (`NSEvent.mouseLocation`). Global-monitor events carry no window (already screen coords);
    /// local ones convert from theirs.
    private static func screenLocation(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    /// Every mouse move funnels here — so the common case must stay a couple of guards and ONE cached
    /// rect test. Begin the hover the moment the cursor enters the hardware cutout while the notch is
    /// idle; and if the far-tier poll is watching an interactive notch, a re-approaching cursor bumps
    /// it back to the crisp tier instantly (no tier lag before a STOP click must land).
    private func hoverMouseMoved(at location: NSPoint) {
        if mouseTimerInterval == Self.pollFar, nearZone.contains(location) {
            retuneMouseTimer()
        }
        // notchButtonAvailable: during onboarding, before the film's notch beat, a click would do
        // NOTHING — so the swell stays off too (a button must never tease a dead click).
        guard notchClickEnabled, !hovering, coordinator.phase == .hidden, coordinator.notchButtonAvailable else { return }
        if let launcher = entryHandles.values.first(where: { $0.panel.isVisible && $0.panel.frame.contains(location) }) {
            // The external pill owns immediate native hover feedback. Preparing the
            // full canvas here delayed that feedback and recreated the SwiftUI tree.
            if !launcher.isIsland { beginHover(on: launcher.displayID) }
        } else if hoverEntryRect.contains(location) { beginHover() }
    }

    /// Cache the hover ENTRY zone — the hardware notch cutout in screen coords, on the BUILT-IN
    /// display (deliberately NOT the menu-bar screen: the affordance must stay armed on the physical
    /// bezel even when an external display is primary). No notched screen — clamshell mode, or a
    /// notch-less Mac — gets `.null` (matches nothing). The rect extends 2pt past the screen's top
    /// edge so a cursor pinned at the very top still counts.
    private func refreshHoverEntryRect() {
        guard notchClickEnabled else { hoverEntryRect = .null; return }
        if coordinator.run.recovery.isPending, let screen = activeScreen() {
            let size = Self.metrics(for: screen).size(for: .hidden)
            let inset = Self.metrics(for: screen).topInset
            hoverEntryRect = NSRect(x: screen.cameraCenterX - size.width / 2,
                y: screen.frame.maxY - inset - size.height, width: size.width, height: size.height + 2)
            return
        }
        guard let screen = Self.builtInNotchScreen(), let notch = screen.notchSize else {
            hoverEntryRect = .null
            return
        }
        let height = screen.hasHardwareIsland ? screen.sidekickMenuBarHeight : notch.height
        hoverEntryRect = NSRect(x: screen.cameraCenterX - notch.width / 2,
                                y: screen.frame.maxY - height,
                                width: notch.width, height: height + 2)
    }

    /// LEAVE detection while hovering (polled): the swollen silhouette's box plus a small margin.
    /// Entry is the tighter hardware cutout, exit is the grown box — that hysteresis keeps the swollen
    /// lip from flickering enter/exit under a cursor resting right on the hardware boundary.
    private func cursorStillHovering() -> Bool {
        guard let screen = activeScreen() else { return false }
        let s = metrics.hoverSize
        let m: CGFloat = 4
        var rect = NSRect(x: screen.cameraCenterX - s.width / 2 - m,
                          y: screen.frame.maxY - metrics.hoverTopInset - s.height - m - (metrics.hasPhysicalNotch ? 0 : 2),
                          width: s.width + m * 2, height: s.height + m + 2 + (metrics.hasPhysicalNotch ? 0 : 8))
        if metrics.hasHardwareIsland {
            rect = rect.union(NSRect(x: screen.cameraCenterX - metrics.baseWidth / 2,
                y: screen.frame.maxY - metrics.hardwareMenuHeight,
                width: metrics.baseWidth, height: metrics.hardwareMenuHeight + 2))
        }
        return rect.contains(NSEvent.mouseLocation)
    }

    /// The cursor crossed into the idle notch: a trackpad haptic tick + the shell swells (NotchView
    /// renders the grow + drop shadow off `coordinator.notchHovering`). The panel appears at the exact
    /// hardware silhouette — black over the black cutout, so its arrival is invisible — then springs
    /// to the grown shape: the dismiss retract-merge trick, played in reverse.
    private func beginHover(on displayID: CGDirectDisplayID? = nil) {
        guard notchClickEnabled, panel != nil else { return }
        if coordinator.run.recovery.isPending {
            if coordinator.run.recovery.reopen() { return }
        }
        hoverDisplayID = displayID ?? Self.builtInNotchScreen()?.displayID
        hovering = true
        sizeToken &+= 1                       // cancel any pending orderOut (a just-finished retract)
        // Place/reset the host before publishing the animated hover. Otherwise its
        // previous display's retract and offset interpolate on the destination screen.
        placeCanvas()
        coordinator.setNotchHovering(true, anchor: pointerAnchor)
        reveal()
        syncEntryHandles()
        startMouseTracking()                  // leave detection + click-through over the swollen shape
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        Log("notch hover began")
    }

    /// The cursor left the hover zone: shrink back into the cutout, then order out after the settle —
    /// token-guarded, so a re-hover mid-retract cleanly cancels the order-out. The wait is LONGER than
    /// the phase retract's `settleDelay`: the hover exit glide (NotchContent.hoverMorph) is a slower,
    /// fully-damped spring whose last few points are still outside the cutout at 0.6s — ordering out
    /// then would visibly snip the tail.
    private func endHover() {
        guard hovering else { return }
        hovering = false
        coordinator.setNotchHovering(false)
        Log("notch hover ended")
        guard coordinator.phase == .hidden else { return }   // an open notch owns the window now
        stopMouseTracking()
        panel?.ignoresMouseEvents = true
        sizeToken &+= 1
        let token = sizeToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            guard let self, self.sizeToken == token, self.coordinator.phase == .hidden,
                  !self.hovering else { return }
            self.panel?.orderOut(nil)
            self.hoverDisplayID = nil
            self.syncEntryHandles()
        }
    }

    /// Hover yields to a real phase (the notch opened under the cursor) — just drop the flags; the
    /// window is already up and applyPhase choreographs everything else.
    private func clearHover() {
        hovering = false
        hoverDisplayID = nil
        coordinator.setNotchHovering(false)
    }

    // MARK: Observers (display / Space / wake / app activation)

    private func installObservers() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        func add(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated(body)
            })
        }
        add(nc, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self else { return }
            self.coordinator.notchPress.cancel()
            self.coordinator.cancelQuickActionPreparation()
            self.coordinator.proofread.close()
            if self.coordinator.phase == .listening || self.coordinator.phase == .transcribing { self.coordinator.cancelCurrent() }
            self.rebuildEntryHandles()
            self.reposition()
        }
        add(nc, .notchAppearanceChanged) { [weak self] in
            self?.reposition()
            self?.updateMousePassthrough()
        }
        add(nc, .notchInteractionChanged) { [weak self] in
            guard let self else { return }
            self.notchClickEnabled = NotchPreferences.clickEnabled()
            if !self.notchClickEnabled { self.endHover() }
            self.refreshHoverEntryRect()
            self.applyPhase()
        }
        add(ws, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.reposition() }
        add(ws, NSWorkspace.willSleepNotification) { [weak self] in
            guard let self else { return }
            self.coordinator.notchPress.cancel()
            self.coordinator.cancelQuickActionPreparation()
            self.coordinator.proofread.close()
            if self.coordinator.phase == .listening || self.coordinator.phase == .transcribing { self.coordinator.cancelCurrent() }
        }
        add(ws, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            guard let self else { return }
            self.coordinator.notchPress.cancel()
            self.coordinator.cancelQuickActionPreparation()
            self.coordinator.proofread.close()
            if self.coordinator.phase == .listening || self.coordinator.phase == .transcribing { self.coordinator.cancelCurrent() }
        }
        add(ws, NSWorkspace.didWakeNotification) { [weak self] in self?.reposition() }
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            let activatedPID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, self.coordinator.phase != .hidden else { return }
                if let activatedPID, activatedPID != ProcessInfo.processInfo.processIdentifier,
                   NSApp.modalWindow == nil {
                    if self.coordinator.phase == .typing { self.coordinator.dismissTyping(); return }
                    if self.coordinator.phase == .opening { _ = self.coordinator.cancelCurrent(); return }
                }
                if self.panel?.isKeyWindow != true { self.reveal() }
            }
        })
        // Key resignation is not user intent: moving the panel or replacing its editor
        // can briefly resign it. Outside clicks and actual application switches dismiss.
        if let panel {
            observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                            object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.coordinator.phase == .recovery else { return }
                    self.coordinator.run.recovery.setFocused(true)
                }
            })
            observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification,
                                            object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.coordinator.phase == .recovery {
                        self.coordinator.run.recovery.setFocused(false)
                        return
                    }
                    if self.coordinator.phase == .message, let message = self.coordinator.notchMessage {
                        self.coordinator.setMessageReplyFocused(false, messageID: message.event.id)
                        return
                    }
                }
            })
        }
    }

    private func reposition() {
        guard panel != nil else { return }
        if hovering { endHover() }                      // the display changed under the cursor — re-detect fresh
        refreshHoverEntryRect()
        guard let screen = activeScreen() else { panel?.orderOut(nil); return }
        applyMetrics(for: screen)                       // same display can still mean a new notch geometry
        placeCanvas()                                   // re-size/re-center the canvas for the new display
        if coordinator.phase != .hidden { reveal(makeKey: wantsKey) }
        syncEntryHandles()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        hoverMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        let handles = entryHandles.values.map(\.panel)
        Task { @MainActor in handles.forEach { $0.orderOut(nil); $0.close() } }
    }

    // MARK: Screen helpers

    static func menuBarScreen() -> NSScreen? {
        let id = CGMainDisplayID()
        return NSScreen.screens.first { $0.displayID == id } ?? NSScreen.screens.first
    }

    /// The built-in display — the only screen a physical notch can exist on. nil in clamshell mode
    /// or on a notch-less Mac.
    static func builtInNotchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.notchSize != nil }
    }

    /// The screen the overlay lives on RIGHT NOW: an idle hover and a notch-click session anchor to
    /// the physical notch's own display; everything else — the hotkey, the home command bar — anchors
    /// to the main (menu-bar) display, which may be an external screen with no notch. Falls back to
    /// the menu-bar screen if the built-in display vanished mid-session (lid shut).
    private func activeScreen() -> NSScreen? {
        if let hoverDisplayID, coordinator.phase == .hidden,
           let screen = NSScreen.screens.first(where: { $0.displayID == hoverDisplayID }) { return screen }
        switch coordinator.notchAnchor {
        case .display(let id): return NSScreen.screens.first { $0.displayID == id } ?? Self.menuBarScreen()
        case .builtInNotch: return Self.builtInNotchScreen() ?? Self.menuBarScreen()
        case .mainDisplay:
            return hovering ? (Self.builtInNotchScreen() ?? Self.menuBarScreen()) : Self.menuBarScreen()
        }
    }

    private var pointerAnchor: NotchAnchor {
        hoverDisplayID.map { .display($0) } ?? .builtInNotch
    }

    private func rebuildEntryHandles() {
        entryHandles.values.forEach { $0.close() }
        entryHandles.removeAll()
        for screen in NSScreen.screens {
            let id = screen.displayID
            entryHandles[id] = NotchEntryHandle(screen: screen, onHover: { [weak self] in
                guard let self, self.coordinator.phase == .hidden, !self.hovering,
                      self.coordinator.notchButtonAvailable else { return }
                self.beginHover(on: id)
            }, onPress: { [weak self] in
                guard let self, self.entriesAvailable else { return }
                if self.coordinator.phase == .hidden, !self.hovering { self.beginHover(on: id) }
                self.coordinator.notchMouseDown(anchor: .display(id))
            }, onActivate: { [weak self] in
                self?.coordinator.notchClicked(anchor: .display(id))
            })
        }
        if let screen = activeScreen() { applyMetrics(for: screen) }
        syncEntryHandles()
    }

    private var entriesAvailable: Bool {
        guard notchClickEnabled, coordinator.notchButtonAvailable, !coordinator.run.isClearingChat else { return false }
        switch coordinator.phase {
        case .hidden: return !coordinator.run.isRunning
        case .typing, .message, .recovery: return true
        default: return false
        }
    }

    private func syncEntryHandles() {
        let available = entriesAvailable
        for (id, launcher) in entryHandles {
            // The live morph owns its handle until the retract has fully settled.
            let covered = panel?.isVisible == true && metricsDisplayID == id
                && (coordinator.phase != .hidden || hovering)
            if available && !covered { launcher.show() }
            else { launcher.panel.orderOut(nil) }
        }
    }

    static func metrics(for screen: NSScreen) -> NotchMetrics {
        NotchMetrics(availableSize: screen.frame.size, hardwareNotch: screen.notchSize,
                     hardwareIsland: screen.hasHardwareIsland,
                     cameraCenterOffset: screen.cameraCenterX - screen.frame.midX,
                     menuBarHeight: screen.hasHardwareIsland ? screen.sidekickMenuBarHeight : 0,
                     compactMode: NotchPreferences.compactModeEnabled())
    }
}

// MARK: - The panel + hosting view

/// canBecomeKey so the tap-to-type field can take keystrokes (the controller makes it key only in
/// .typing; non-activating, so the app never comes forward over what you're using).
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Don't let macOS push us below the menu bar — the notch sits flush at the screen's very top edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The hosting view. The window is already sized to just the notch, so the only thing that can capture
/// clicks is the notch's own box — and only while there's something to click (STOP, the field and its
/// mic, the listening stop). acceptsFirstMouse → a control fires on the first click.
final class NotchHostingView: NSHostingView<NotchView> {
    private let coordinator: CommandCoordinator
    private var metrics: NotchMetrics
    private var islandBackdrop: NSImage?
    private var displayID: CGDirectDisplayID

    init(coordinator: CommandCoordinator, metrics: NotchMetrics, displayID: CGDirectDisplayID) {
        self.coordinator = coordinator
        self.metrics = metrics
        self.displayID = displayID
        super.init(rootView: NotchView(coordinator: coordinator, metrics: metrics, displayID: displayID))
        // This is a fixed-canvas overlay. SwiftUI content must never change NSWindow
        // geometry or its constraints from an asynchronous rendering update.
        sizingOptions = []
        safeAreaRegions = []
        autoresizingMask = [.width, .height]
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @MainActor required init(rootView: NotchView) { fatalError("use init(coordinator:metrics:)") }

    /// Re-render with new screen metrics (display reconfiguration).
    func update(metrics: NotchMetrics, islandBackdrop: NSImage? = nil, displayID: CGDirectDisplayID) {
        guard self.metrics != metrics || self.islandBackdrop !== islandBackdrop || self.displayID != displayID else { return }
        self.metrics = metrics
        self.islandBackdrop = islandBackdrop
        self.displayID = displayID
        rootView = NotchView(coordinator: coordinator, metrics: metrics, islandBackdrop: islandBackdrop, displayID: displayID)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The window only RECEIVES a click while the cursor is over the notch silhouette (the controller
        // toggles ignoresMouseEvents by cursor position), so anything reaching here is a real notch click —
        // resolve the STOP button / text field, otherwise absorb on the notch body.
        super.hitTest(point) ?? self
    }
}

// MARK: - Screen helpers

extension NSScreen {
    /// visibleFrame removes the menu bar; the protected top inset remains a stable
    /// fallback when menu-bar auto-hide or fullscreen temporarily removes that gap.
    var sidekickMenuBarHeight: CGFloat {
        max(frame.maxY - visibleFrame.maxY, safeAreaInsets.top,
            notchSize?.height ?? 0, NSStatusBar.system.thickness)
    }
    var cameraCenterX: CGFloat {
        if hasHardwareIsland { return frame.midX }
        guard notchSize != nil, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return frame.midX }
        return (left.maxX + right.minX) / 2
    }
    /// Current PROLED MacBooks are built-in Multi-Touch displays with a protected
    /// camera area. Avoid model identifiers, panel pixel counts or photo measurements.
    var hasHardwareIsland: Bool {
        if #available(macOS 27.0, *) {
            return NotchMetrics.detectsHardwareIsland(isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                hasMultiTouch: touchCapabilities.contains(.multiTouch), hasProtectedCameraArea: notchSize != nil)
        }
        return false
    }
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The OS-reported protected camera band. This is not the black cutout's exact outline.
    var notchSize: CGSize? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        let width = right.minX - left.maxX
        let height = max(safeAreaInsets.top, left.height, right.height)
        guard width.isFinite, height.isFinite, width > 0, width < frame.width, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
