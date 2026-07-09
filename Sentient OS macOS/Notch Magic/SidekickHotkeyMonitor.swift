//
//  SidekickHotkeyMonitor.swift
//  Sentient OS macOS
//
//  The global notch trigger via a SINGLE listen-only CGEventTap — ZERO permissions: hold / tap the
//  user's chosen Sidekick key (right ⌘ or right ⌥ — push-to-talk · tap-to-type), read from the
//  device-dependent flag bit on every `flagsChanged`, so press/release self-heals even if an event
//  is dropped. The key is configurable at runtime (`setKey`) — both choices are MODIFIERS, the half
//  macOS does not gate, so switching between them never changes the (permission-free) tap mask.
//
//  ⚠️ The mask is `flagsChanged` ONLY — modifiers are the half macOS does not gate. NEVER add
//  keyDown/keyUp: keyboard taps are exactly what Input Monitoring gates, and the one time we
//  carried keyDown (for a global Esc) the system kept disabling the tap and surfaced a stray
//  Input Monitoring request. Esc still cancels whenever Sentient is frontmost (the notch window's
//  LOCAL monitor — no permission); over other apps, a fresh hotkey press is the cancel
//  (CommandCoordinator.voicePressBegan).
//
//  Emits: onPress (key down) · onHoldConfirmed (still down at the hold threshold) ·
//  onRelease(held:) (key up, with duration). Reliability: re-enables a system-disabled tap,
//  re-arms on wake, and a periodic health check reconciles a missed release + rebuilds a dead tap.
//  Doc: Documentation/Notch Magic/Notch Magic.md.
//

import AppKit
import CoreGraphics

/// The Sidekick trigger key — the single source of truth mapping the persisted `sidekick.hotkey`
/// choice to the flag bits we read and a label for logs / UI. Both are RIGHT-side modifiers, so
/// holding/tapping either one alone types nothing — a safe push-to-talk trigger.
enum SidekickHotkey: String {
    case rightCommand
    case rightOption

    /// Device-dependent bit (NX_DEVICER*KEYMASK) — the TRUE right-key state on every `flagsChanged`
    /// (distinguishes the right key from its left twin, which the generic modifier bit can't).
    var deviceBit: UInt64 {
        switch self {
        case .rightCommand: return 0x10   // NX_DEVICERCMDKEYMASK
        case .rightOption:  return 0x40   // NX_DEVICERALTKEYMASK
        }
    }

    /// The generic modifier bit — used ONLY for the conservative "missed release" reconcile
    /// (there we can only tell "some ⌘/⌥ is down", not which side).
    var genericBit: UInt64 {
        switch self {
        case .rightCommand: return CGEventFlags.maskCommand.rawValue
        case .rightOption:  return CGEventFlags.maskAlternate.rawValue
        }
    }

    /// Short label for logs and copy.
    var label: String {
        switch self {
        case .rightCommand: return "right ⌘"
        case .rightOption:  return "right ⌥"
        }
    }

    /// The user's current choice, read from the persisted setting (falls back to right ⌘).
    static var current: SidekickHotkey {
        SidekickHotkey(rawValue: UserDefaults.standard.string(forKey: "sidekick.hotkey") ?? "") ?? .rightCommand
    }
}

/// Posted when the user changes the Sidekick hotkey in Settings, so the live monitor can re-key
/// without a restart. (ProactivePane posts it on toggle; CommandCoordinator observes it.)
extension Notification.Name {
    static let sidekickHotkeyChanged = Notification.Name("sidekick.hotkey.changed")
}

// MARK: - C trampoline (captures nothing → bridges to a C function pointer; hops onto the main actor)
//
// `nonisolated` is load-bearing: the project builds with default MainActor isolation, and an
// actor-isolated function can't be formed into a @convention(c) function pointer.

private nonisolated func sidekickHotkeyTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                                   _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<SidekickHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let flags = event.flags.rawValue
    let t = type
    Task { @MainActor in monitor.handle(type: t, flags: flags) }
    return Unmanaged.passUnretained(event)   // listen-only: return the event unchanged
}

@MainActor
final class SidekickHotkeyMonitor {
    /// Held ≥ this long = a HOLD (push-to-talk). Below = a TAP (type mode).
    static let holdThreshold: TimeInterval = 0.25

    /// The key we currently watch. Swap it at runtime with `setKey` — no tap rebuild needed (the
    /// mask stays `flagsChanged`); we just read a different device bit.
    private(set) var key: SidekickHotkey = .rightCommand

    /// Force-release a hold after this long — set from the active speech engine's transcription limit
    /// (SpeechAnalyzer 3 min · SFSpeechRecognizer 59s), which doubles as the stuck-key safety net.
    var maxHold: TimeInterval = 180

    var onPress: (() -> Void)?
    var onHoldConfirmed: (() -> Void)?
    var onRelease: ((TimeInterval) -> Void)?

    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyIsDown = false
    private var downAt: Date?
    private var holdConfirmTask: Task<Void, Never>?
    private var maxHoldTask: Task<Void, Never>?
    private var healthTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var running = false

    // MARK: Lifecycle

    /// Point the monitor at a different key. If a press is somehow in flight (the user can't really
    /// change Settings mid-hold, but be safe), abandon it cleanly so we never strand a "down" belief
    /// on the old bit. Idempotent — a no-op when the key is unchanged.
    func setKey(_ newKey: SidekickHotkey) {
        guard newKey != key else { return }
        if keyIsDown {
            keyIsDown = false
            holdConfirmTask?.cancel(); holdConfirmTask = nil
            maxHoldTask?.cancel(); maxHoldTask = nil
            downAt = nil
        }
        key = newKey
        Log("hotkey: now watching \(newKey.label)")
    }

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
        keyIsDown = false
        downAt = nil
    }

    // MARK: The tap

    private func installTap(quiet: Bool = false) {
        teardownTap()
        // flagsChanged ONLY (the hotkey is a modifier — the ungated half). NEVER add keyDown/keyUp:
        // that's what Input Monitoring gates (see the top-of-file warning).
        let mask = CGEventMask(1) << UInt64(CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask,
                                           callback: sidekickHotkeyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log("hotkey: tapCreate failed (a modifier-only tap shouldn't need anything) — will retry on the health tick")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.runLoopSource = src
        if !quiet { Log("hotkey: listening for \(key.label) (flagsChanged-only, zero-permission)") }
    }

    private func teardownTap() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        runLoopSource = nil
        port = nil
    }

    /// Health-tick reinstalls of a dead tap run QUIET, with a periodic count instead — the system
    /// can keep disabling a listen-only tap (seen after a full TCC reset), and per-reinstall logging
    /// floods a session log at 1.5s intervals until it drowns everything else.
    private var reinstalls = 0

    private func reinstallIfNeeded() {
        guard running else { return }
        let enabled = port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        if !enabled {
            reinstalls += 1
            if reinstalls == 1 || reinstalls % 200 == 0 {
                Log("hotkey: tap was disabled — re-armed (×\(reinstalls) this session)")
            }
            installTap(quiet: true)
        }
    }

    // MARK: Event handling (on the main actor, via the trampoline)

    func handle(type: CGEventType, flags: UInt64) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }   // the system throttled us — re-arm
        case .flagsChanged:
            let nowDown = (flags & key.deviceBit) != 0
            guard nowDown != keyIsDown else { return }   // not a transition on our key
            keyIsDown = nowDown
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
            guard let self, !Task.isCancelled, self.keyIsDown else { return }
            self.onHoldConfirmed?()
        }
        let cap = maxHold
        maxHoldTask?.cancel()
        maxHoldTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(cap))
            guard let self, !Task.isCancelled, self.keyIsDown else { return }
            Log("hotkey: max-hold cap (\(Int(cap))s) — forcing release")
            self.keyIsDown = false
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
        // Reconcile a missed release: if we think the key is down but NO matching modifier is
        // physically down now, we missed the up event → release. (Conservative: if the modifier is
        // down we can't tell left vs right here, so we leave it — better a late release than a false
        // one.)
        if keyIsDown {
            let live = CGEventSource.flagsState(.combinedSessionState).rawValue
            if (live & key.genericBit) == 0 {
                Log("hotkey: reconciled a missed release")
                keyIsDown = false
                endPress()
            }
        }
    }
}
