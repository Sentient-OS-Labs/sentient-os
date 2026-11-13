// SidekickHotkeyMonitor.swift
// Observes the shared shortcut key for standalone taps and hold-to-talk.
// Observes modifiers using flagsChanged only.
// Never install a CGEventTap or a global keyDown/keyUp monitor here.
// Doc: Documentation - Sidekick - General.md

import AppKit

@MainActor
final class SidekickHotkeyMonitor {
    var onTap: ((ShortcutKey, TimeInterval, ShortcutActivity) -> Void)?
    var onInterruption: (() -> Void)?
    var onHold: ((ShortcutKey) -> Bool)?
    var onHoldEnd: ((ShortcutKey, Bool) -> Void)?

    private var keys: Set<ShortcutKey> = []
    private var taps: [ShortcutKey: ShortcutTap] = [:]
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var healthTimer: Timer?
    private var holdTimer: Timer?
    private var heldKey: ShortcutKey?
    private var holdActivity: ShortcutActivity?
    private var holdStarted: TimeInterval = 0
    private var eventModifierFlags: NSEvent.ModifierFlags = []
    private var running = false

    func setKeys(_ keys: Set<ShortcutKey>) {
        endHold(send: false)
        holdTimer?.invalidate(); holdTimer = nil
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
        endHold(send: false)
        holdTimer?.invalidate(); holdTimer = nil
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
        handleFlagsChanged(keyCode: event.keyCode, flags: event.modifierFlags, at: event.timestamp,
            activity: ShortcutActivity.current, lastInputTime: ShortcutActivity.lastInputTime,
            mouseButtons: NSEvent.pressedMouseButtons)
    }

    private func handleFlagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags, at time: TimeInterval,
                                    activity: ShortcutActivity, lastInputTime: TimeInterval, mouseButtons: Int) {
        eventModifierFlags = flags
        // An unrelated modifier breaks both a pending tap and a double-tap pair.
        if !keys.contains(where: { $0.keyCode == keyCode }) {
            for key in Array(taps.keys) { taps[key]?.cancel() }
            endHold(send: false)
            onInterruption?()
        }
        for key in keys {
            let down = UInt64(flags.rawValue) & key.deviceBit != 0
            let wasDown = taps[key]?.isDown ?? false
            let alone = (down ? key.isAlone(in: flags)
                : flags.intersection([.command, .option, .control, .shift, .function]).isEmpty)
                && mouseButtons == 0
            let tapped = taps[key, default: ShortcutTap()].update(down: down, alone: alone,
                                                                   at: time, activity: activity,
                                                                   lastInputTime: lastInputTime)
            if heldKey == key {
                if !alone { endHold(send: false) }
                else if wasDown && !down {
                    endHold(send: activity == holdActivity && lastInputTime <= holdStarted + 0.002)
                }
            }
            if tapped { onTap?(key, time, activity) }
            else if wasDown && !down { onInterruption?() }
        }
        updateHoldTimer()
    }

    private func updateHoldTimer() {
        guard taps.values.contains(where: \.isTracking) else {
            holdTimer?.invalidate(); holdTimer = nil
            return
        }
        guard holdTimer == nil else { return }
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHold() }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkHold() {
        let flags = NSEvent.modifierFlags
        updateHold(at: ProcessInfo.processInfo.systemUptime, flags: flags,
            activity: ShortcutActivity.current, lastInputTime: ShortcutActivity.lastInputTime,
            pressedKeys: polledKeys(in: flags),
            mouseButtons: NSEvent.pressedMouseButtons, recording: ShortcutPreferences.isRecording)
    }

    private func polledKeys(in flags: NSEvent.ModifierFlags) -> Set<ShortcutKey> {
        // Key-state queries can collapse right-side modifiers into their left-side key code.
        // Native flagsChanged events identify the side; polling only verifies its family.
        Set(ShortcutKey.allCases.filter {
            UInt64(eventModifierFlags.rawValue) & $0.deviceBit != 0 && flags.contains($0.modifierFlag)
        })
    }

    private func updateHold(at now: TimeInterval, flags: NSEvent.ModifierFlags, activity: ShortcutActivity,
                            lastInputTime: TimeInterval, pressedKeys: Set<ShortcutKey>, mouseButtons: Int,
                            recording: Bool) {
        // NSEvent.modifierFlags contains only device-independent flags. Reconstruct
        // the left/right bits from the tracked native event before applying the event check.
        var heldFlags = flags.intersection(.deviceIndependentFlagsMask)
        for key in pressedKeys {
            heldFlags.formUnion(NSEvent.ModifierFlags(rawValue: UInt(key.deviceBit)))
        }
        for key in keys where taps[key]?.isTracking == true {
            // The window server can observe key-up just before its flagsChanged callback.
            // Let that event finish normally; the health check cancels genuinely lost releases.
            guard pressedKeys.contains(key) else { continue }
            guard !recording, key.isAlone(in: heldFlags), mouseButtons == 0,
                  taps[key]?.isStandalone(activity: activity, lastInputTime: lastInputTime) == true else {
                taps[key]?.cancel()
                endHold(send: false)
                onInterruption?()
                continue
            }
            if taps[key]?.takeHold(at: now, activity: activity, lastInputTime: lastInputTime) == true,
               onHold?(key) == true {
                heldKey = key
                holdActivity = activity
                holdStarted = now
            }
        }
        updateHoldTimer()
    }

    private func endHold(send: Bool) {
        guard let key = heldKey else { return }
        heldKey = nil
        holdActivity = nil
        onHoldEnd?(key, send)
    }

    #if DEBUG
    func flagsForTesting(key: ShortcutKey, flags: NSEvent.ModifierFlags, at time: TimeInterval,
                         activity: ShortcutActivity, lastInputTime: TimeInterval = -.infinity, mouseButtons: Int = 0) {
        handleFlagsChanged(keyCode: key.keyCode, flags: flags, at: time, activity: activity,
            lastInputTime: lastInputTime, mouseButtons: mouseButtons)
    }

    func holdForTesting(at time: TimeInterval, flags: NSEvent.ModifierFlags, activity: ShortcutActivity,
                        pressedKeys: Set<ShortcutKey>? = nil, lastInputTime: TimeInterval = -.infinity,
                        mouseButtons: Int = 0, recording: Bool = false) {
        updateHold(at: time, flags: flags, activity: activity, lastInputTime: lastInputTime,
            pressedKeys: pressedKeys ?? polledKeys(in: flags), mouseButtons: mouseButtons, recording: recording)
    }

    func reconcileForTesting(pressedKeys: Set<ShortcutKey>) { reconcileKeys(pressedKeys) }
    #endif

    private func healthCheck() {
        guard running else { return }
        if globalMonitor == nil || localMonitor == nil { installMonitors() }
        reconcileKeys(polledKeys(in: NSEvent.modifierFlags))
    }

    private func reconcileKeys(_ pressedKeys: Set<ShortcutKey>) {
        // A missed release cancels a gesture. Reconciliation must never synthesize a tap.
        for key in keys where taps[key]?.isDown == true {
            if !pressedKeys.contains(key) {
                taps[key] = ShortcutTap()
                endHold(send: false)
                onInterruption?()
            }
        }
        updateHoldTimer()
    }
}
