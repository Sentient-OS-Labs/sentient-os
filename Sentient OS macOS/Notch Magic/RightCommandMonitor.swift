//
//  RightCommandMonitor.swift
//  Sentient OS macOS
//
//  Global "hold the right ⌘ key" trigger for push-to-talk — ZERO permissions. A listen-only
//  CGEventTap masking ONLY `flagsChanged` (modifier transitions, which macOS does not gate; only
//  keyDown/keyUp need Input Monitoring). Right ⌘'s live state is read from the device-dependent flag
//  bit (0x10) on EVERY event, so press/release self-heals even if an individual event is dropped.
//
//  Emits: onPress (right ⌘ down) · onHoldConfirmed (still down at the hold threshold — the moment the
//  notch should reveal) · onRelease(held:) (right ⌘ up, with the hold duration). Reliability: re-enables
//  a system-disabled tap, re-arms on wake, and a periodic health check reconciles a missed release +
//  rebuilds a dead tap. Doc: Documentation/Notch Magic/Hotkey Detection.md.
//
//  Lift-and-replace of the proven DEV bench (Views/HotkeyLabView.swift).
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
    let flags = event.flags.rawValue
    let t = type
    Task { @MainActor in monitor.handle(type: t, flags: flags) }
    return Unmanaged.passUnretained(event)   // listen-only: return the event unchanged
}

@MainActor
final class RightCommandMonitor {
    /// Held ≥ this long = a HOLD (push-to-talk). Below = a TAP (future: type mode; today a no-op).
    static let holdThreshold: TimeInterval = 0.25

    /// Device-dependent right-⌘ bit (NX_DEVICERCMDKEYMASK) — the true right-⌘ state on every event.
    private static let rightCommandBit: UInt64 = 0x10
    /// The generic ⌘ bit — used only for the conservative "missed release" reconcile.
    private static let commandBit: UInt64 = CGEventFlags.maskCommand.rawValue

    /// Force-release a hold after this long — set from the active speech engine's transcription limit
    /// (SpeechAnalyzer 3 min · SFSpeechRecognizer 59s), which doubles as the stuck-key safety net.
    var maxHold: TimeInterval = 180

    var onPress: (() -> Void)?
    var onHoldConfirmed: (() -> Void)?
    var onRelease: ((TimeInterval) -> Void)?

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
        let mask = CGEventMask(1) << UInt64(CGEventType.flagsChanged.rawValue)   // ONLY flagsChanged
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
