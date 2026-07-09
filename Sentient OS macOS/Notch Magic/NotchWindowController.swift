//
//  NotchWindowController.swift
//  Sentient OS macOS
//
//  Hosts the notch overlay in a borderless, non-activating NSPanel that floats above the menu bar and
//  over fullscreen apps on the menu-bar display.
//
//  ‼️ Fixed-canvas overlay (DynamicNotch's approach): a stable window, larger than the biggest notch
//  state, pinned with its top flush at the screen's edge. It NEVER resizes during a morph — the notch
//  shape animates INSIDE it — so the notch can never detach from the bezel mid-animation. Click-through
//  is guaranteed by toggling window-level `ignoresMouseEvents` by CURSOR POSITION: the window only stops
//  ignoring the mouse while the cursor is over the actual notch SILHOUETTE (running/typing) — so every
//  other point, INCLUDING the glow bloom's drawn pixels, passes straight through. (A static hitTest can't
//  do this: macOS catches a click on ANY non-transparent pixel — the glow — before hitTest can pass it on,
//  and a nil hitTest then SWALLOWS it rather than passing through.) Ordered OUT when idle.
//

import SwiftUI
import AppKit

@MainActor
final class NotchWindowController {
    private let coordinator: CommandCoordinator
    private var panel: NotchPanel?
    private var host: NotchHostingView?
    private var metrics = NotchMetrics(hardwareNotch: nil)
    private var observers: [NSObjectProtocol] = []
    private var sizeToken = 0
    /// When the panel last became KEY for the type field — used to ignore the transient resign during focus setup.
    private var typingKeyAt = Date.distantPast
    /// Polls the cursor while interactive to toggle `ignoresMouseEvents` (silhouette-only click-through).
    private var mouseTimer: Timer?
    /// Local key monitor: Esc cancels the notch's pending input (type field / voice capture). See §4.
    private var keyMonitor: Any?

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
        let frame = windowFrame(for: canvasSize, on: screen)
        let panel = NotchPanel(contentRect: frame,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
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

        // Click-through: while interactive, a cursor poll lets the window receive clicks ONLY over the
        // notch silhouette (the glow + canvas always pass through); otherwise the whole window ignores
        // the mouse so every click sails past.
        if coordinator.phase == .running || coordinator.phase == .typing {
            startMouseTracking()
        } else {
            stopMouseTracking()
            panel.ignoresMouseEvents = true
        }

        if coordinator.phase != .hidden {
            placeCanvas()                                   // the fixed canvas — NEVER resized per morph
            reveal(makeKey: coordinator.phase == .typing)
        } else {
            // Order the window out only AFTER the SwiftUI retract animation has played.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.settleDelay))
                guard let self, self.sizeToken == token, self.coordinator.phase == .hidden else { return }
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
    /// non-activating panel, so this never brings the app forward over whatever you're using.
    private func reveal(makeKey: Bool = false) {
        guard let panel else { return }
        panel.collectionBehavior = Self.collectionBehavior
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
            typingKeyAt = Date()
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

    /// Size + center the fixed canvas over the menu-bar display's notch (no-op if already there).
    private func placeCanvas() {
        guard let panel, let screen = Self.menuBarScreen() else { return }
        let frame = windowFrame(for: canvasSize, on: screen)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true, animate: false)
        host?.frame = NSRect(origin: .zero, size: frame.size)
    }

    // MARK: Click-through (silhouette-only, by cursor position)

    /// Poll the cursor (~60 Hz) while interactive so `ignoresMouseEvents` flips the instant the cursor
    /// crosses into / out of the notch silhouette. Added in `.common` modes so it keeps ticking during
    /// tracking loops. Idempotent.
    private func startMouseTracking() {
        updateMousePassthrough()
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassthrough() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
    }

    /// The window receives the mouse ONLY while the cursor is over the live notch silhouette; everywhere
    /// else (glow, canvas) it ignores the mouse, so those clicks pass straight through.
    private func updateMousePassthrough() {
        guard let panel else { return }
        let interactive = coordinator.phase == .running || coordinator.phase == .typing
        let receive = interactive && cursorOverSilhouette()
        if panel.ignoresMouseEvents == receive { panel.ignoresMouseEvents = !receive }
    }

    /// Is the cursor over the actual notch shape right now? Works in screen coordinates (no view-flip
    /// guesswork): a bounding-box early-out, then the exact `NotchShape` path test.
    private func cursorOverSilhouette() -> Bool {
        guard let screen = Self.menuBarScreen() else { return false }
        let s = metrics.size(for: coordinator.phase, readBack: coordinator.readBack,
                             remembering: coordinator.run.remembering)
        let p = NSEvent.mouseLocation                        // screen coords, origin bottom-left
        let localX = p.x - (screen.frame.midX - s.width / 2)
        let depthFromTop = screen.frame.maxY - p.y           // 0 at the bezel, increasing downward
        guard localX >= 0, localX <= s.width, depthFromTop >= 0, depthFromTop <= s.height else { return false }
        let radii = metrics.radii(for: coordinator.phase)
        return NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
            .path(in: CGRect(x: 0, y: 0, width: s.width, height: s.height))
            .contains(CGPoint(x: localX, y: depthFromTop))
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
        if let panel {
            observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification,
                                            object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.coordinator.phase == .typing,
                          Date().timeIntervalSince(self.typingKeyAt) > 0.4 else { return }
                    self.coordinator.dismissTyping()
                }
            })
        }
    }

    private func reposition() {
        guard let panel, let screen = Self.menuBarScreen() else { panel?.orderOut(nil); return }
        metrics = Self.metrics(for: screen)
        host?.update(metrics: metrics)
        placeCanvas()                                   // re-size/re-center the canvas for the new display
        if coordinator.phase != .hidden { reveal(makeKey: coordinator.phase == .typing) }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: Screen helpers

    static func menuBarScreen() -> NSScreen? {
        let id = CGMainDisplayID()
        return NSScreen.screens.first { $0.displayID == id } ?? NSScreen.screens.first
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
