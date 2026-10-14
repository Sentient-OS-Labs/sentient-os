// SidekickHotkeyMonitor.swift
// Observes the shared shortcut key and emits completed, standalone taps.
// Observes modifiers using flagsChanged only.
// Never install a CGEventTap or a global keyDown/keyUp monitor here.
// Doc: Documentation - Sidekick - General.md

import AppKit

@MainActor
final class SidekickHotkeyMonitor {
    var onTap: ((ShortcutKey, TimeInterval, ShortcutActivity) -> Void)?
    var onKeyChange: ((ShortcutKey, Bool) -> Void)?
    var onInterruption: (() -> Void)?

    private var keys: Set<ShortcutKey> = []
    private var taps: [ShortcutKey: ShortcutTap] = [:]
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var healthTimer: Timer?
    private var running = false

    func setKeys(_ keys: Set<ShortcutKey>) {
        self.keys = keys
        taps.removeAll()
    }

    func start() {
        guard !running else { return }
        running = true
        installMonitors()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.healthCheck() }
        }
    }

    func stop() {
        running = false
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        healthTimer?.invalidate()
        healthTimer = nil
        taps.removeAll()
    }

    private func installMonitors() {
        // Registering during NSApplication initialization wedges event routing on fresh launches.
        guard NSApp?.isRunning == true else { return }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.flagsChanged(event)
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.flagsChanged(event)
                return event
            }
        }
    }

    private func flagsChanged(_ event: NSEvent) {
        guard !ShortcutPreferences.isRecording else { return }
        let flags = event.modifierFlags
        let activity = ShortcutActivity.current
        let time = event.timestamp
        let lastInputTime = ShortcutActivity.lastInputTime
        // An unrelated modifier breaks both a pending tap and a double-tap pair.
        if !keys.contains(where: { $0.keyCode == event.keyCode }) {
            for key in Array(taps.keys) { taps[key]?.cancel() }
            onInterruption?()
        }
        for key in keys {
            let down = UInt64(flags.rawValue) & key.deviceBit != 0
            let wasDown = taps[key]?.isDown ?? false
            let alone = (down ? key.isAlone(in: flags)
                : flags.intersection([.command, .option, .control, .shift, .function]).isEmpty)
                && NSEvent.pressedMouseButtons == 0
            let tapped = taps[key, default: ShortcutTap()].update(down: down, alone: alone,
                                                                   at: time, activity: activity,
                                                                   lastInputTime: lastInputTime)
            if down != wasDown { onKeyChange?(key, down) }
            if tapped { onTap?(key, time, activity) }
            else if wasDown && !down { onInterruption?() }
        }
    }

    private func healthCheck() {
        guard running else { return }
        if globalMonitor == nil || localMonitor == nil { installMonitors() }
        // A missed release cancels a gesture. Reconciliation must never synthesize a tap.
        for key in keys where taps[key]?.isDown == true {
            if !CGEventSource.keyState(.combinedSessionState, key: key.keyCode) {
                taps[key] = ShortcutTap()
                onKeyChange?(key, false)
                onInterruption?()
            }
        }
    }
}
