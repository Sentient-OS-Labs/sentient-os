//
//  RightCommandMonitor.swift
//  Sentient OS macOS
//
//  Global notch triggers via a SINGLE listen-only CGEventTap — ZERO permissions:
//   • hold / tap the RIGHT ⌘ (push-to-talk · tap-to-type) — read from the device-dependent flag bit
//     (0x10) on every `flagsChanged`, so press/release self-heals even if an event is dropped.
//   • press ESC anywhere — to cancel / dismiss the notch globally (onEscape).
//
//  Modifiers (⌘) ride `flagsChanged`, which macOS doesn't gate. Esc is a regular key (keyDown) — long
//  ASSUMED to need Input Monitoring, but MEASURED (macOS Tahoe, Input Monitoring OFF, app unfocused) to
//  flow through a LISTEN-ONLY tap with no permission, no prompt, no Settings entry. ⚠️ Re-verify on the
//  macOS-15 floor before launch. We filter to Esc inside the C callback, so only Esc hops to the main
//  actor (never every keystroke), and the tap stays listen-only so keys always pass through untouched.
//
//  Emits: onPress (right ⌘ down) · onHoldConfirmed (still down at the hold threshold) · onRelease(held:)
//  (right ⌘ up, with duration) · onEscape (Esc pressed). Reliability: re-enables a system-disabled tap,
//  re-arms on wake, and a periodic health check reconciles a missed release + rebuilds a dead tap.
//  Doc: Documentation/Notch Magic/Notch Magic.md.
//

import AppKit
import CoreGraphics

// MARK: - C trampoline (captures nothing → bridges to a C function pointer; hops onto the main actor)
//
// `nonisolated` is load-bearing: the project builds with default MainActor isolation, and an
// actor-isolated function can't be formed into a @convention(c) function pointer.

private nonisolated func rightCommandTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                                 _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<RightCommandMonitor>.fromOpaque(refcon).takeUnretainedValue()
    if type == .keyDown {
        // Filter to Esc HERE (synchronously, cheaply) so a global keyDown mask never floods the main
        // actor — we hop over only for the one key we care about.
        if event.getIntegerValueField(.keyboardEventKeycode) == RightCommandMonitor.escKeyCode {
            Task { @MainActor in monitor.handleEscape() }
        }
    } else {
        let flags = event.flags.rawValue
        let t = type
        Task { @MainActor in monitor.handle(type: t, flags: flags) }
    }
    return Unmanaged.passUnretained(event)   // listen-only: return the event unchanged
}

@MainActor
final class RightCommandMonitor {
    /// Held ≥ this long = a HOLD (push-to-talk). Below = a TAP (future: type mode; today a no-op).
    static let holdThreshold: TimeInterval = 0.25

    /// Device-dependent right-⌘ bit (NX_DEVICERCMDKEYMASK) — the true right-⌘ state on every event.
    private static let rightCommandBit: UInt64 = 0x10
    /// Esc's virtual keycode (kVK_Escape) — a regular key, caught as keyDown to cancel the notch. `nonisolated`
    /// so the C event-tap callback (which runs off the main actor) can read it to filter for Esc.
    nonisolated static let escKeyCode: Int64 = 53
    /// The generic ⌘ bit — used only for the conservative "missed release" reconcile.
    private static let commandBit: UInt64 = CGEventFlags.maskCommand.rawValue

    /// Force-release a hold after this long — set from the active speech engine's transcription limit
    /// (SpeechAnalyzer 3 min · SFSpeechRecognizer 59s), which doubles as the stuck-key safety net.
    var maxHold: TimeInterval = 180

    var onPress: (() -> Void)?
    var onHoldConfirmed: (() -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    var onEscape: (() -> Void)?              // Esc pressed anywhere — used to cancel / dismiss the notch

    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightCmdDown = false
    private var downAt: Date?
    private var holdConfirmTask: Task<Void, Never>?
    private var maxHoldTask: Task<Void, Never>?
    private var healthTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var running = false

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        installTap()
        // A tap can die across sleep/wake — rebuild it on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reinstallIfNeeded() }
        }
        // Periodic health check: rebuild a dead tap + reconcile a missed release.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.healthCheck() }
        }
    }

    func stop() {
        running = false
        teardownTap()
        holdConfirmTask?.cancel(); holdConfirmTask = nil
        maxHoldTask?.cancel(); maxHoldTask = nil
        healthTimer?.invalidate(); healthTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        rightCmdDown = false
        downAt = nil
    }

    // MARK: The tap

    private func installTap() {
        teardownTap()
        // flagsChanged (right-⌘, a modifier) + keyDown (for Esc). Both flow through a listen-only tap with
        // no permission — measured on Tahoe (the keyDown half was the surprise; re-verify on macOS 15).
        let mask = (CGEventMask(1) << UInt64(CGEventType.flagsChanged.rawValue))
                 | (CGEventMask(1) << UInt64(CGEventType.keyDown.rawValue))
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask,
                                           callback: rightCommandTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log("⌘mon: tapCreate failed (a modifier-only tap shouldn't need anything) — will retry on the health tick")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.runLoopSource = src
        Log("⌘mon: listening (flagsChanged-only, zero-permission)")
    }

    private func teardownTap() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        runLoopSource = nil
        port = nil
    }

    private func reinstallIfNeeded() {
        guard running else { return }
        let enabled = port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        if !enabled { installTap() }
    }

    // MARK: Event handling (on the main actor, via the trampoline)

    func handle(type: CGEventType, flags: UInt64) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }   // the system throttled us — re-arm
        case .flagsChanged:
            let nowDown = (flags & Self.rightCommandBit) != 0
            guard nowDown != rightCmdDown else { return }   // not a right-⌘ transition
            rightCmdDown = nowDown
            if nowDown { beginPress() } else { endPress() }
        default:
            break
        }
    }

    /// Esc pressed anywhere (already filtered to keycode 53 in the C callback) → fire the cancel hook.
    func handleEscape() { onEscape?() }

    private func beginPress() {
        downAt = Date()
        onPress?()
        holdConfirmTask?.cancel()
        holdConfirmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.holdThreshold))
            guard let self, !Task.isCancelled, self.rightCmdDown else { return }
            self.onHoldConfirmed?()
        }
        let cap = maxHold
        maxHoldTask?.cancel()
        maxHoldTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(cap))
            guard let self, !Task.isCancelled, self.rightCmdDown else { return }
            Log("⌘mon: max-hold cap (\(Int(cap))s) — forcing release")
            self.rightCmdDown = false
            self.endPress()
        }
    }

    private func endPress() {
        holdConfirmTask?.cancel(); holdConfirmTask = nil
        maxHoldTask?.cancel(); maxHoldTask = nil
        let held = downAt.map { Date().timeIntervalSince($0) } ?? 0
        downAt = nil
        onRelease?(held)
    }

    // MARK: Self-healing

    private func healthCheck() {
        guard running else { return }
        reinstallIfNeeded()
        // Reconcile a missed release: if we think right-⌘ is down but NO ⌘ is physically down now, we
        // missed the up event → release. (Conservative: if some ⌘ is down we can't tell left vs right
        // here, so we leave it — better a late release than a false one.)
        if rightCmdDown {
            let live = CGEventSource.flagsState(.combinedSessionState).rawValue
            if (live & Self.commandBit) == 0 {
                Log("⌘mon: reconciled a missed release")
                rightCmdDown = false
                endPress()
            }
        }
    }
}
