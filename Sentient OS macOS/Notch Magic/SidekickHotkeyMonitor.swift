//
//  SidekickHotkeyMonitor.swift
//  Sentient OS macOS
//
//  The global notch trigger via NSEvent `flagsChanged` monitors (one global + one local) — ZERO
//  permissions, ZERO prompts: hold / tap the user's chosen Sidekick key (right ⌘ or right ⌥ —
//  push-to-talk · tap-to-type), read from the device-dependent flag bit on every `flagsChanged`,
//  so press/release self-heals even if an event is dropped. The key is configurable at runtime
//  (`setKey`) — both choices are MODIFIERS, the half macOS hands out freely.
//
//  ⚠️ NEVER use a CGEventTap here — not even listen-only masking flagsChanged ONLY. Creating ANY
//  keyboard-class tap pings the Input Monitoring TCC service: on a fresh Mac that raises the
//  "would like to receive keystrokes from any application" dialog at first launch and records a
//  system-set denial (which also lists the app, unchecked, in the Input Monitoring pane). The tap
//  then *works* anyway — modifier delivery is unenforced — which is exactly how the dialog hid
//  during development (field-proven with a minimal repro app, 2026-07-09). NSEvent monitors carry
//  the same modifier information and never touch TCC. And NEVER monitor keyDown/keyUp globally
//  either — real keystrokes are the gated half (a global keyDown monitor delivers nothing without
//  Accessibility). Esc still cancels whenever Sentient is frontmost (the notch window's LOCAL
//  monitor); over other apps, a fresh hotkey press is the cancel (CommandCoordinator.voicePressBegan).
//
//  Emits: onPress (key down) · onHoldConfirmed (still down at the hold threshold) ·
//  onRelease(held:) (key up, with duration). The two monitors cover both worlds — global (events
//  routed to other apps) + local (Sentient itself frontmost) — and a periodic health check
//  reconciles a missed release. Doc: Documentation/Notch Magic/Notch Magic.md.
//

import AppKit

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
        case .rightCommand: return UInt64(NSEvent.ModifierFlags.command.rawValue)
        case .rightOption:  return UInt64(NSEvent.ModifierFlags.option.rawValue)
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

@MainActor
final class SidekickHotkeyMonitor {
    /// Held ≥ this long = a HOLD (push-to-talk). Below = a TAP (type mode).
    static let holdThreshold: TimeInterval = 0.25

    /// The key we currently watch. Swap it at runtime with `setKey` — the monitors hear every
    /// modifier transition regardless; we just read a different device bit.
    private(set) var key: SidekickHotkey = .rightCommand

    /// Force-release a hold after this long — set from the active speech engine's transcription limit
    /// (SpeechAnalyzer 3 min · SFSpeechRecognizer 59s), which doubles as the stuck-key safety net.
    var maxHold: TimeInterval = 180

    var onPress: (() -> Void)?
    var onHoldConfirmed: (() -> Void)?
    var onRelease: ((TimeInterval) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyIsDown = false
    private var downAt: Date?
    private var holdConfirmTask: Task<Void, Never>?
    private var maxHoldTask: Task<Void, Never>?
    private var healthTimer: Timer?
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
        installMonitors()
        // Periodic health check: reconcile a missed release (+ re-install a failed monitor).
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.healthCheck() }
        }
    }

    func stop() {
        running = false
        teardownMonitors()
        holdConfirmTask?.cancel(); holdConfirmTask = nil
        maxHoldTask?.cancel(); maxHoldTask = nil
        healthTimer?.invalidate(); healthTimer = nil
        keyIsDown = false
        downAt = nil
    }

    // MARK: The monitors

    private func installMonitors() {
        // ⚠️ NEVER register NSEvent monitors before the app finishes launching. start() runs inside
        // AppState.init — during SwiftUI App construction, mid-NSApplicationMain — and a monitor
        // registered that early wedges the app's event routing for the life of the process: every
        // window draws but receives NO input, activation never completes ("AppleEvent activation
        // suspension timed out"), the main thread sits idle waiting for events that never come.
        // Field-proven 2026-07-09 (the launch-freeze hunt). At that moment NSApp itself can still
        // be nil (NSApplication not yet created — hence the optional chain, never a bare NSApp).
        // Too early → bail; the health tick can only fire once the run loop is pumping
        // (post-launch by construction), so it installs them within ~1.5s of launch.
        guard NSApp?.isRunning == true else {
            Log("hotkey: app still launching — monitor install deferred to the health tick")
            return
        }
        teardownMonitors()
        // flagsChanged ONLY — modifier transitions, the ungated half (see the top-of-file warning).
        // The global monitor hears events routed to other apps; the local one hears them whenever
        // Sentient itself is frontmost. Between them, every press is seen exactly once — and the
        // transition guard in handle() makes even a duplicate harmless.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(flags: UInt64(event.modifierFlags.rawValue))
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(flags: UInt64(event.modifierFlags.rawValue))
            return event
        }
        if globalMonitor == nil || localMonitor == nil {
            Log("hotkey: monitor install failed (global \(globalMonitor != nil) · local \(localMonitor != nil)) — will retry on the health tick")
        } else {
            Log("hotkey: listening for \(key.label) (flagsChanged NSEvent monitors, zero-permission)")
        }
    }

    private func teardownMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    // MARK: Event handling

    /// Both monitors funnel here: read OUR key's device bit and act only on a TRANSITION — so a
    /// duplicate or dropped event can never wedge the press state.
    private func handle(flags: UInt64) {
        let nowDown = (flags & key.deviceBit) != 0
        guard nowDown != keyIsDown else { return }
        keyIsDown = nowDown
        if nowDown { beginPress() } else { endPress() }
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
        if globalMonitor == nil || localMonitor == nil { installMonitors() }
        // Reconcile a missed release: if we think the key is down but NO matching modifier is
        // physically down now, we missed the up event → release. (Conservative: if the modifier is
        // down we can't tell left vs right here, so we leave it — better a late release than a false
        // one.)
        if keyIsDown {
            let live = UInt64(NSEvent.modifierFlags.rawValue)
            if (live & key.genericBit) == 0 {
                Log("hotkey: reconciled a missed release")
                keyIsDown = false
                endPress()
            }
        }
    }
}
