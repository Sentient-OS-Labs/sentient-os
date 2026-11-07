// Tracks one physical mouse press across changing notch views. Release monitors and a live
// button-state check survive view replacement, pointer drift and a missing mouse-up event.
// Doc: Documentation - Sidekick - Notch Window & Visual.md
import AppKit
import SwiftUI

@MainActor
final class NotchPressGesture {
    private var timer: Timer?
    private var monitors: [Any] = []
    private var started: TimeInterval = 0
    private var origin = NSPoint.zero
    private var held = false
    private var invalid = false
    private var cancelOnEarlyDrag = true
    private var tap: (() -> Void)?
    private var hold: (() -> Bool)?
    private var release: (() -> Void)?
    private var releaseAway: (() -> Void)?
    private var location: () -> NSPoint = { NSEvent.mouseLocation }
    private var buttons: () -> Int = { NSEvent.pressedMouseButtons }
    private var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var observesNativeEvents = true
    init() {}
    #if DEBUG
    /// Deterministic platform inputs exercise the real gesture without synthesizing global input.
    init(location: @escaping () -> NSPoint, buttons: @escaping () -> Int, uptime: @escaping () -> TimeInterval) {
        self.location = location; self.buttons = buttons; self.uptime = uptime
        observesNativeEvents = false
    }
    func tickForTesting() { tick() }
    func releaseForTesting() { finish(allowTap: true) }
    #endif
    var isTracking: Bool { timer != nil }

    func begin(tap: @escaping () -> Void, hold: @escaping () -> Bool, release: @escaping () -> Void,
               releaseAway: (() -> Void)? = nil,
               cancelOnEarlyDrag: Bool = true) {
        guard !isTracking else { return }
        self.tap = tap; self.hold = hold; self.release = release
        self.releaseAway = releaseAway
        self.cancelOnEarlyDrag = cancelOnEarlyDrag
        started = uptime(); origin = location()
        held = false; invalid = false
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        guard observesNativeEvents else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.event(event.type)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.event(event.type)
            return event
        }) { monitors.append(monitor) }
        RunLoop.main.add(timer, forMode: .common)
    }
    private func event(_ type: NSEvent.EventType) {
        if type == .leftMouseUp { finish(allowTap: true) }
        else { checkDrift() }
    }
    private func checkDrift() {
        guard !held, cancelOnEarlyDrag else { return }
        let point = location()
        if hypot(point.x - origin.x, point.y - origin.y) > 8 { invalid = true }
    }
    private func tick() {
        guard isTracking else { return }
        guard buttons() & 1 != 0 else { finish(allowTap: true); return }
        checkDrift()
        guard !held, !invalid, uptime() - started >= 0.25 else { return }
        held = true
        if hold?() != true { invalid = true }
    }
    private func finish(allowTap: Bool) {
        guard isTracking else { return }
        // A deliberate drag away changes release-to-send into stop-and-edit. Small
        // hand movements remain forgiving, and returning before release still sends.
        let point = location()
        let movedAway = hypot(point.x - origin.x, point.y - origin.y) > 48
        let heldAction = movedAway ? (releaseAway ?? release) : release
        let action = invalid ? nil : held ? heldAction : allowTap ? tap : nil
        cancel()
        action?()
    }
    func cancel() {
        timer?.invalidate(); timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors.removeAll()
        tap = nil; hold = nil; release = nil; releaseAway = nil
    }
}

/// Native down events start tracking before the view disappears into the recording strip.
/// Accessibility activation remains an ordinary click-to-start action.
struct NotchMicrophoneButton: NSViewRepresentable {
    var onPress: () -> Void
    var onActivate: () -> Void
    var recording = false
    func makeNSView(context: Context) -> PressButton {
        let button = PressButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Speak to Sidekick")
        button.contentTintColor = .white.withAlphaComponent(0.7)
        button.toolTip = "Hold to dictate and release to send, or click to start"
        button.setAccessibilityLabel("Speak to Sidekick")
        button.target = button; button.action = #selector(PressButton.activate)
        return button
    }
    func updateNSView(_ view: PressButton, context: Context) {
        view.onPress = onPress; view.onActivate = onActivate
        view.image = NSImage(systemSymbolName: recording ? "stop.fill" : "mic.fill", accessibilityDescription: recording ? "Stop dictation" : "Speak to Sidekick")
        view.setAccessibilityLabel(recording ? "Stop dictation" : "Speak to Sidekick")
        view.toolTip = recording ? "Stop dictation and edit" : "Click to dictate, or hold and release to send. Drag away to keep a draft."
    }
    final class PressButton: NSButton {
        var onPress: (() -> Void)?
        var onActivate: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onPress?() }
        @objc func activate() { onActivate?() }
    }
}
