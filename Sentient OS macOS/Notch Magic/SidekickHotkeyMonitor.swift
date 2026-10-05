//
//  SidekickHotkeyMonitor.swift
//  Sentient OS macOS
//
//  The global notch trigger via NSEvent `flagsChanged` monitors (one global + one local) — ZERO
//  permissions, ZERO prompts: every PRESS of the user's chosen Sidekick key (right ⌘ or right ⌥),
//  read from the device-dependent flag bit on every `flagsChanged`, so press/release self-heals
//  even if an event is dropped. The key is configurable at runtime (`setKey`) — both choices are
//  MODIFIERS, the half macOS hands out freely. What a press MEANS (one tap opens the type field,
//  two taps inside the double-tap window draft a reply) is CommandCoordinator's call; this file
//  only reports presses.
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
//  monitor); over other apps, a fresh hotkey press is the cancel (CommandCoordinator.hotkeyPressed).
//
//  Emits: onPress (key down). The two monitors cover both worlds — global (events routed to other
//  apps) + local (Sentient itself frontmost) — and a periodic health check reconciles a missed
//  release so a lost key-up can never swallow the next press. Doc: Notch Magic/Documentation - Sidekick - General.md.
//

import AppKit

/// The Sidekick trigger key — the single source of truth mapping the persisted `sidekick.hotkey`
/// choice to the flag bits we read and a label for logs / UI. Both are RIGHT-side modifiers, so
/// tapping either one alone types nothing — a safe global trigger.
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
    /// The key we currently watch. Swap it at runtime with `setKey` — the monitors hear every
    /// modifier transition regardless; we just read a different device bit.
    private(set) var key: SidekickHotkey = .rightCommand

    var onPress: (() -> Void)?
    /// The native onboarding keycap follows the physical key back up as well as down.
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyIsDown = false
    private var healthTimer: Timer?
    private var running = false

    // MARK: Lifecycle

    /// Point the monitor at a different key. If a press is somehow in flight (the user can't really
    /// change Settings mid-press, but be safe), forget it so we never strand a "down" belief on the
    /// old bit. Idempotent — a no-op when the key is unchanged.
    func setKey(_ newKey: SidekickHotkey) {
        guard newKey != key else { return }
        keyIsDown = false
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
        healthTimer?.invalidate(); healthTimer = nil
        keyIsDown = false
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
            Diagnostics.report(.inputFailed, phase: .monitor, reason: "monitor_install", source: "hotkey", cooldown: 3600)
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
    /// duplicate or dropped event can never wedge the press state. Only the DOWN edge is reported;
    /// the up edge just re-arms the next press.
    private func handle(flags: UInt64) {
        let nowDown = (flags & key.deviceBit) != 0
        guard nowDown != keyIsDown else { return }
        keyIsDown = nowDown
        if nowDown { onPress?() } else { onRelease?() }
    }

    // MARK: Self-healing

    private func healthCheck() {
        guard running else { return }
        if globalMonitor == nil || localMonitor == nil { installMonitors() }
        // Reconcile a missed release: if we think the key is down but NO matching modifier is
        // physically down now, we missed the up event → re-arm, or the next press would be read as
        // a non-transition and silently dropped. (Conservative: if the modifier is down we can't
        // tell left vs right here, so we leave it — better a late re-arm than a false one.)
        if keyIsDown, (UInt64(NSEvent.modifierFlags.rawValue) & key.genericBit) == 0 {
            Log("hotkey: reconciled a missed release")
            keyIsDown = false
            onRelease?()
        }
    }
}
