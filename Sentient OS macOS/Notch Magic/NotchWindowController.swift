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
//  it on, and a nil hitTest then SWALLOWS it rather than passing through.) Ordered OUT when idle.
//
//  Also owns the HOVER affordance (the notch as a button): zero-permission `.mouseMoved` NSEvent
//  monitors detect the cursor entering the hardware cutout while idle → haptic tick + the shell swells
//  (rendered by NotchView off coordinator.notchHovering) → a click opens tap-to-type. Real-notch
//  displays only. Exit + the swollen shape's click-through ride the same cursor poll as running/typing.
//

import SwiftUI
import AppKit

@MainActor
final class NotchWindowController {
    private let coordinator: CommandCoordinator
    private var panel: NotchPanel?
    private var host: NotchHostingView?
    private var metrics = NotchMetrics(hardwareNotch: nil)
    /// Which display the current `metrics` were derived from — the anchor can move the overlay between
    /// displays (a notch-click session vs the hotkey's main-display session), and landing on a new
    /// screen must re-derive the metrics for its bezel (real cutout vs the notch-less fallback pill).
    private var metricsDisplayID: CGDirectDisplayID = 0
    private var observers: [NSObjectProtocol] = []
    private var sizeToken = 0
    /// When the panel last became KEY for the type field — used to ignore the transient resign during focus setup.
    private var typingKeyAt = Date.distantPast
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
    /// Retries the hover-monitor install until the app has finished launching (lesson 14 — an NSEvent
    /// monitor registered mid-NSApplicationMain wedges event routing for the life of the process).
    private var hoverInstallTimer: Timer?
    /// The cursor is over the idle notch — the shell is swollen and clickable.
    private var hovering = false
    /// The hardware notch cutout in screen coords — the hover ENTRY zone, cached so the per-mouse-move
    /// idle check is a bare rect test (recomputed only on build + display changes). `.null` = no notch.
    private var hoverEntryRect: NSRect = .null

    /// Extra room around the largest notch state so the morph's bounce-overshoot + the glow bloom never
    /// clip at the fixed window's edge. The notch is centered + top-anchored inside this canvas.
    private static let canvasHSlack: CGFloat = 140
    private static let canvasVSlack: CGFloat = 90
    /// After going hidden, wait for the SwiftUI retract animation to fully play (the shell collapses into the
    /// cutout and merges) before ordering the window out — so the window never hard-cuts a still-visible notch.
    private static let settleDelay: Double = 0.6

    /// Re-asserted on EVERY reveal — macOS drops `.canJoinAllSpaces` when a window is re-ordered, which
    /// otherwise strands the overlay on a single Space. (.fullScreenAuxiliary → also over fullscreen apps.)
    private static let collectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

    init(coordinator: CommandCoordinator) { self.coordinator = coordinator }

    func start() {
        Task { @MainActor [weak self] in
            self?.build()
            self?.installObservers()
            self?.installKeyMonitor()
            self?.installHoverMonitorsWhenReady()
            self?.observePhase()
            self?.applyPhase()          // sync the initial state (hidden → stays ordered out)
        }
    }

    /// Esc handling is LOCAL-ONLY (a global keyDown tap is exactly what Input Monitoring gates — never
    /// add one): this monitor sees Esc whenever events route to Sentient — the focused type field (where
    /// it consumes Esc *before* the text field so dismissing never beeps) and any notch state while a
    /// Sentient window is frontmost. Over OTHER apps, a fresh right-⌘ press is the cancel instead
    /// (CommandCoordinator.voicePressBegan). A LOCAL monitor needs no permission (it only sees events
    /// already routed to us); `cancelCurrent()` returns true when it handled the Esc → we swallow it
    /// (nil) so the field doesn't also act on it.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // 53 = Esc (keep the non-Sendable event off-isolation)
            let consumed = MainActor.assumeIsolated { self?.coordinator.cancelCurrent() ?? false }
            return consumed ? nil : event
        }
    }

    // MARK: Build (created hidden — applyPhase reveals it only when active)

    private func build() {
        guard panel == nil, let screen = Self.menuBarScreen() else { return }
        metrics = Self.metrics(for: screen)
        metricsDisplayID = screen.displayID
        refreshHoverEntryRect()
        let frame = windowFrame(for: canvasSize, on: screen)
        let panel = NotchPanel(contentRect: frame,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.level = .mainMenu + 3
        panel.collectionBehavior = Self.collectionBehavior
        // (sharingType left at default → the notch IS visible to screen capture, so it shows up in
        //  screen recordings / demos. Trade-off: the computer-use agent may see it in its screenshots.)
        let host = NotchHostingView(coordinator: coordinator, metrics: metrics)
        host.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = host
        self.panel = panel
        self.host = host
    }

    // MARK: Phase → window presence + size

    private func observePhase() {
        withObservationTracking {
            _ = coordinator.phase
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.applyPhase()
                self.observePhase()     // re-arm
            }
        }
    }

    private func applyPhase() {
        guard let panel else { return }
        sizeToken &+= 1
        let token = sizeToken

        // The hover affordance is idle-only: the instant the notch opens for real (a hotkey press,
        // a click landing in .typing, a notice), hover yields — the phase owns the shape now, and
        // the window is already up so there's nothing to choreograph.
        if coordinator.phase != .hidden, hovering { clearHover() }

        // Click-through: while interactive, a cursor poll lets the window receive clicks ONLY over the
        // notch silhouette (the glow + canvas always pass through); otherwise the whole window ignores
        // the mouse so every click sails past. Hovering counts as interactive — the same poll also
        // detects the cursor LEAVING the hover zone (updateMousePassthrough → endHover).
        if coordinator.phase == .running || coordinator.phase == .typing || hovering {
            startMouseTracking()
        } else {
            stopMouseTracking()
            panel.ignoresMouseEvents = true
        }

        if coordinator.phase != .hidden {
            placeCanvas()                                   // the fixed canvas — NEVER resized per morph
            reveal(makeKey: coordinator.phase == .typing)
        } else if !hovering {
            // Order the window out only AFTER the SwiftUI retract animation has played.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.settleDelay))
                guard let self, self.sizeToken == token, self.coordinator.phase == .hidden,
                      !self.hovering else { return }
                self.panel?.orderOut(nil)                   // idle → no window at all
            }
        }
    }

    /// Show the panel and pin it everywhere: re-assert `collectionBehavior` (so it joins ALL Spaces),
    /// order front, then move it into SkyLight's top-level notch space (so it stays FIXED over the notch
    /// and never slides during the Spaces swipe). SkyLight is best-effort; the public behavior is the
    /// fallback if it's unavailable.
    ///
    /// `makeKey` (typing only) makes the panel KEY so its text field can take keystrokes — it's a
    /// non-activating panel, so this never brings the app forward over whatever you're using. Once
    /// AppKit has accepted the key-window request, explicitly hand focus to the SwiftUI field; the
    /// view must not race the phase update against this call.
    private func reveal(makeKey: Bool = false) {
        guard let panel else { return }
        panel.collectionBehavior = Self.collectionBehavior
        if makeKey {
            // `makeKeyAndOrderFront` routes through the normal ordering policy, which can leave a
            // non-activating panel visible but non-key when this path starts in another app's global
            // hotkey monitor. Order independently of activation, then explicitly steal key focus —
            // exactly what `.nonactivatingPanel` is designed to permit without activating Sentient.
            panel.orderFrontRegardless()
            panel.makeKey()
            typingKeyAt = Date()
            if panel.isKeyWindow {
                coordinator.requestTypingFocus()
            } else {
                Log("notch typing panel could not become key")
            }
        } else {
            panel.orderFrontRegardless()
        }
        NotchSpace.shared?.pin(panel)
    }

    // MARK: Geometry

    /// The fixed window size: big enough for the widest/tallest notch state plus slack. It only changes
    /// on a display/notch change — never during a morph — so the notch stays pinned to the bezel.
    private var canvasSize: CGSize {
        let phases: [NotchPhase] = [.opening, .listening, .transcribing, .typing, .running, .notice("")]
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
        if screen.displayID != metricsDisplayID { applyMetrics(for: screen) }
        let frame = windowFrame(for: canvasSize, on: screen)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true, animate: false)
        host?.frame = NSRect(origin: .zero, size: frame.size)
    }

    /// Re-derive the metrics for a screen and re-render the host with them.
    private func applyMetrics(for screen: NSScreen) {
        metrics = Self.metrics(for: screen)
        metricsDisplayID = screen.displayID
        host?.update(metrics: metrics)
    }

    // MARK: Click-through (silhouette-only, by cursor position)

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
        var zone = panel.frame
        zone.size.height += 2
        return zone
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
        if hovering, coordinator.phase == .hidden, !cursorStillHovering() { endHover(); return }
        let interactive = coordinator.phase == .running || coordinator.phase == .typing
            || (hovering && coordinator.phase == .hidden)
        // The canvas box gates the EXPENSIVE silhouette test (a Path build + the read-back text
        // measurement): a far cursor can't be over the silhouette, so it never pays for one.
        let receive = interactive && cursorNearNotch() && cursorOverSilhouette()
        if panel.ignoresMouseEvents == receive { panel.ignoresMouseEvents = !receive }
    }

    /// Is the cursor over the actual notch shape right now? Works in screen coordinates (no view-flip
    /// guesswork): a bounding-box early-out, then the exact `NotchShape` path test. During a hover the
    /// live silhouette is the swollen hover shape, not the phase's.
    private func cursorOverSilhouette() -> Bool {
        guard let screen = activeScreen() else { return false }
        let hoverIdle = hovering && coordinator.phase == .hidden
        let s = hoverIdle ? metrics.hoverSize
                          : metrics.size(for: coordinator.phase, readBack: coordinator.readBack,
                                         remembering: coordinator.run.remembering)
        let p = NSEvent.mouseLocation                        // screen coords, origin bottom-left
        let localX = p.x - (screen.frame.midX - s.width / 2)
        let depthFromTop = screen.frame.maxY - p.y           // 0 at the bezel, increasing downward
        guard localX >= 0, localX <= s.width, depthFromTop >= 0, depthFromTop <= s.height else { return false }
        let radii = hoverIdle ? metrics.hoverRadii : metrics.radii(for: coordinator.phase)
        // ⚠️ Fitts's law at the bezel: a cursor slammed against the screen's top edge reports depth ≈ 0 —
        // a point ON the path's boundary, which `contains` excludes — so the top edge of the notch went
        // click-dead. Test a couple of points INTO the shape instead: the screen edge itself is part of
        // the notch (macOS's own menu bar works this way).
        return NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
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
        if !hoverMonitors.isEmpty {
            Log("notch hover affordance armed (mouseMoved NSEvent monitors, zero-permission)")
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
        guard !hovering, coordinator.phase == .hidden, coordinator.notchButtonAvailable,
              hoverEntryRect.contains(location) else { return }
        beginHover()
    }

    /// Cache the hover ENTRY zone — the hardware notch cutout in screen coords, on the BUILT-IN
    /// display (deliberately NOT the menu-bar screen: the affordance must stay armed on the physical
    /// bezel even when an external display is primary). No notched screen — clamshell mode, or a
    /// notch-less Mac — gets `.null` (matches nothing). The rect extends 2pt past the screen's top
    /// edge so a cursor pinned at the very top still counts.
    private func refreshHoverEntryRect() {
        guard let screen = Self.builtInNotchScreen(), let notch = screen.notchSize else {
            hoverEntryRect = .null
            return
        }
        hoverEntryRect = NSRect(x: screen.frame.midX - notch.width / 2,
                                y: screen.frame.maxY - notch.height,
                                width: notch.width, height: notch.height + 2)
    }

    /// LEAVE detection while hovering (polled): the swollen silhouette's box plus a small margin.
    /// Entry is the tighter hardware cutout, exit is the grown box — that hysteresis keeps the swollen
    /// lip from flickering enter/exit under a cursor resting right on the hardware boundary.
    private func cursorStillHovering() -> Bool {
        guard let screen = activeScreen() else { return false }
        let s = metrics.hoverSize
        let m: CGFloat = 4
        let rect = NSRect(x: screen.frame.midX - s.width / 2 - m,
                          y: screen.frame.maxY - s.height - m,
                          width: s.width + m * 2, height: s.height + m + 2)
        return rect.contains(NSEvent.mouseLocation)
    }

    /// The cursor crossed into the idle notch: a trackpad haptic tick + the shell swells (NotchView
    /// renders the grow + drop shadow off `coordinator.notchHovering`). The panel appears at the exact
    /// hardware silhouette — black over the black cutout, so its arrival is invisible — then springs
    /// to the grown shape: the dismiss retract-merge trick, played in reverse.
    private func beginHover() {
        guard panel != nil else { return }
        hovering = true
        sizeToken &+= 1                       // cancel any pending orderOut (a just-finished retract)
        coordinator.setNotchHovering(true)
        placeCanvas()
        reveal()
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
        }
    }

    /// Hover yields to a real phase (the notch opened under the cursor) — just drop the flags; the
    /// window is already up and applyPhase choreographs everything else.
    private func clearHover() {
        hovering = false
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
        add(nc, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.reposition() }
        add(ws, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.reposition() }
        add(ws, NSWorkspace.didWakeNotification) { [weak self] in self?.reposition() }
        add(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] in
            guard let self, self.coordinator.phase != .hidden else { return }
            self.reveal(makeKey: self.coordinator.phase == .typing)
        }
        // Clicked away while the type field was open → close it (ignore the transient resign during setup).
        // ⚠️ A REAL click-away can also land INSIDE the setup grace (clicking away mid-morph, before the
        // field ever shows its cursor). Swallowing it outright bricked the field (field-found 2026-07-14):
        // the non-activating panel never re-keys on its own, a non-key window can never fire another
        // resign, so no later click-away could ever dismiss. So a resign inside the grace schedules ONE
        // re-check just past it — still .typing and STILL not key means that resign was a real click-away
        // (the setup transient re-keys itself right after) → dismiss. The typingKeyAt re-read keeps a
        // freshly reopened field (its own grace running) out of reach.
        if let panel {
            observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification,
                                            object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.coordinator.phase == .typing else { return }
                    if Date().timeIntervalSince(self.typingKeyAt) > 0.4 {
                        self.coordinator.dismissTyping()
                    } else {
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(0.5))
                            guard let self, self.coordinator.phase == .typing,
                                  self.panel?.isKeyWindow == false,
                                  Date().timeIntervalSince(self.typingKeyAt) > 0.4 else { return }
                            self.coordinator.dismissTyping()
                        }
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
        if coordinator.phase != .hidden { reveal(makeKey: coordinator.phase == .typing) }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        hoverMonitors.forEach { NSEvent.removeMonitor($0) }
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
        let onNotch = (hovering && coordinator.phase == .hidden) || coordinator.notchAnchor == .builtInNotch
        return onNotch ? (Self.builtInNotchScreen() ?? Self.menuBarScreen()) : Self.menuBarScreen()
    }

    static func metrics(for screen: NSScreen) -> NotchMetrics {
        NotchMetrics(hardwareNotch: screen.notchSize)
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
/// clicks is the notch's own box — and only while there's something to click (the running STOP button);
/// every other phase returns nil so clicks pass through. acceptsFirstMouse → STOP fires on first click.
final class NotchHostingView: NSHostingView<NotchView> {
    private let coordinator: CommandCoordinator
    private var metrics: NotchMetrics

    init(coordinator: CommandCoordinator, metrics: NotchMetrics) {
        self.coordinator = coordinator
        self.metrics = metrics
        super.init(rootView: NotchView(coordinator: coordinator, metrics: metrics))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @MainActor required init(rootView: NotchView) { fatalError("use init(coordinator:metrics:)") }

    /// Re-render with new screen metrics (display reconfiguration).
    func update(metrics: NotchMetrics) {
        self.metrics = metrics
        rootView = NotchView(coordinator: coordinator, metrics: metrics)
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
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The physical notch size, or nil if this display has no notch (the "no notch" signal).
    var notchSize: CGSize? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        let width = frame.width - (left.width + right.width)
        guard width > 0 else { return nil }
        return CGSize(width: width, height: left.height)
    }
}
