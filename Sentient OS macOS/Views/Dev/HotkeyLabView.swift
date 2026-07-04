//
//  HotkeyLabView.swift
//  Sentient OS macOS
//
//  DEV-ONLY bench (DEV TOOLS → HOTKEY LAB) for the global push-to-talk trigger: hold RIGHT ⌘.
//
//  The discovery this encodes: watching a *modifier* key needs NO permission. Right ⌘ arrives as a
//  `flagsChanged` event, and macOS only gates `keyDown`/`keyUp` (the actual letters you type) behind
//  Input Monitoring. So a listen-only session tap masking ONLY flagsChanged sees right ⌘ globally —
//  no prompt, no Settings entry, no Accessibility — and the same holds in the notarized, Finder-launched
//  app. The one rule: NEVER add keyDown/keyUp to the global mask (that's the gated half; the future
//  tap-to-type captures typing in our own focused field, not via a global tap).
//
//  This bench just lets us FEEL the trigger (hold vs quick-tap) and confirm it stays permission-free.
//  Scaffolding — delete once the trigger is wired for real.
//
//  Key methods: HotkeyLab.startTap()/stopTap(), onTap(type:keycode:) (the handler the C trampoline hops into).
//

import SwiftUI
import AppKit
import CoreGraphics         // CGEvent tap APIs + CGPreflightListenEventAccess (diagnostic only)
import ApplicationServices  // AXIsProcessTrusted (diagnostic only)

// MARK: - C trampoline (captures nothing → bridges to a C function pointer; hops onto the main actor)
//
// `nonisolated` is load-bearing: the project builds with -default-isolation=MainActor, and an
// actor-isolated function can't be formed into a @convention(c) function pointer.

private nonisolated func hotkeyTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                           _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let lab = Unmanaged<HotkeyLab>.fromOpaque(refcon).takeUnretainedValue()
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let t = type
    Task { @MainActor in lab.onTap(type: t, keycode: keycode) }
    return Unmanaged.passUnretained(event)   // listen-only: return the event unchanged
}

// MARK: - The bench model

@MainActor
@Observable
final class HotkeyLab {
    /// How long a hold must last to count as push-to-talk vs a quick type-tap.
    static let holdThreshold: TimeInterval = 0.25

    /// Right-Command virtual keycode (kVK_RightCommand). Hard-coded so this file needs no Carbon import.
    private static let rightCommandKey: Int64 = 54

    // Diagnostics ONLY — both are unreliable and NOT required for a modifier-only tap. Surfaced just to
    // make the "the preflight says granted, and we don't care" point visible.
    var preflightListenEvent = false
    var trustedForAccessibility = false

    var tapActive = false
    var tapNote = "tap not started"
    var rightCmdHeld = false
    var liveHold: TimeInterval = 0
    var lastVerdict = "—"

    var log: [String] = []

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var heldMods: Set<Int64> = []
    private var rightCmdDownAt: Date?
    private var liveTimer: Timer?

    func refreshDiagnostics() {
        preflightListenEvent = CGPreflightListenEventAccess()
        trustedForAccessibility = AXIsProcessTrusted()
    }

    // MARK: The listen-only, flagsChanged-only tap (zero permission)

    func startTap() {
        stopTap()
        refreshDiagnostics()
        // ONLY flagsChanged — modifier transitions, which macOS does not gate. Never add keyDown/keyUp.
        let mask = CGEventMask(1) << UInt64(CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask,
                                           callback: hotkeyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            tapActive = false
            tapNote = "tapCreate failed (unexpected — a modifier-only tap shouldn't need anything)."
            append("✗ tap create failed")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        machPort = port
        runLoopSource = src
        tapActive = true
        tapNote = "listening — hold right ⌘, then release. No permission needed (it's a modifier)."
        append("✓ listen-only tap started (flagsChanged only — zero permission)")
    }

    func stopTap() {
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let port = machPort { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        runLoopSource = nil
        machPort = nil
        heldMods.removeAll()
        rightCmdDownAt = nil
        rightCmdHeld = false
        liveTimer?.invalidate(); liveTimer = nil
        tapActive = false
    }

    func onTap(type: CGEventType, keycode: Int64) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = machPort { CGEvent.tapEnable(tap: port, enable: true) }
            append("⚠︎ system disabled the tap — re-enabled")
        case .flagsChanged:
            guard let name = Self.modifierName(keycode) else { return }
            if heldMods.contains(keycode) {
                heldMods.remove(keycode)
                append("\(name) ↑")
                if keycode == Self.rightCommandKey { endRightCmd() }
            } else {
                heldMods.insert(keycode)
                append("\(name) ↓")
                if keycode == Self.rightCommandKey { beginRightCmd() }
            }
        default:
            break
        }
    }

    private func beginRightCmd() {
        rightCmdHeld = true
        rightCmdDownAt = Date()
        liveHold = 0
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let t = self.rightCmdDownAt else { return }
                self.liveHold = Date().timeIntervalSince(t)
            }
        }
    }

    private func endRightCmd() {
        liveTimer?.invalidate(); liveTimer = nil
        rightCmdHeld = false
        guard let t = rightCmdDownAt else { return }
        let dur = Date().timeIntervalSince(t)
        rightCmdDownAt = nil
        liveHold = dur
        lastVerdict = Self.verdict(dur)
        append("→ " + lastVerdict)
    }

    // MARK: Helpers

    private func append(_ s: String) {
        log.append("\(Self.ts.string(from: Date()))  \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private static func verdict(_ dur: TimeInterval) -> String {
        dur < holdThreshold
            ? String(format: "TAP (%.0f ms) → would TYPE ⌨️", dur * 1000)
            : String(format: "HOLD (%.2f s) → would TALK 🎙️", dur)
    }

    private static func modifierName(_ keycode: Int64) -> String? {
        switch keycode {
        case 54: return "right ⌘"
        case 55: return "left ⌘"
        case 61: return "right ⌥"
        case 58: return "left ⌥"
        case 62: return "right ⌃"
        case 59: return "left ⌃"
        case 60: return "right ⇧"
        case 56: return "left ⇧"
        case 63: return "fn 🌐"
        default: return nil
        }
    }

    private static let ts: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
}

// MARK: - The view

struct HotkeyLabView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lab = HotkeyLab()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("HOTKEY LAB").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)
                Spacer()
                Button("Done") { dismiss() }.controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 16) {
                    infoPane
                    triggerPane
                    logPane
                }
                .padding(24)
            }
        }
        .frame(width: 620, height: 680)
        .background(Theme.bg)
        .onAppear {
            lab.refreshDiagnostics()
            lab.startTap()
        }
        .onDisappear { lab.stopTap() }
    }

    // MARK: Why this is free + the throwaway diagnostic

    private var infoPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.verdictColor(.survivor))
                Text("Zero permission").font(.caption.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Button("Restart tap") { lab.startTap() }
                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
            }
            Text("Right ⌘ arrives as a modifier (flagsChanged) event, which macOS does NOT gate — only letter-keys (keyDown/keyUp) need Input Monitoring. So this works with no prompt, no Settings, no restart — in the shipped app too.")
                .font(.caption2).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("diagnostic (ignore — unreliable, NOT required):  ListenEvent preflight = \(lab.preflightListenEvent ? "true" : "false")  ·  Accessibility = \(lab.trustedForAccessibility ? "true" : "false")")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.faint)
                Spacer()
                Button("Re-check") { lab.refreshDiagnostics() }
                    .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }

    // MARK: Feel the trigger

    private var triggerPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(lab.rightCmdHeld ? Theme.accent : Theme.stroke).frame(width: 10, height: 10)
                Text("Hold right ⌘").font(.caption.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Text(lab.tapActive ? "LISTENING" : "OFF").font(.caption2.weight(.bold))
                    .foregroundStyle(lab.tapActive ? Theme.verdictColor(.survivor) : Theme.faint)
            }
            Text(lab.tapNote).font(.caption2).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            Text(lab.rightCmdHeld ? String(format: "holding… %.2fs", lab.liveHold) : "idle")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(lab.rightCmdHeld ? Theme.accent : Theme.secondary)
            Text("last: \(lab.lastVerdict)").font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }

    // MARK: Live log

    private var logPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("EVENT LOG").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)
                Spacer()
                Button("Clear") { lab.log.removeAll() }.buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lab.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.secondary).id(i)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 220)
                .onChange(of: lab.log.count) { _, c in
                    if c > 0 { withAnimation { proxy.scrollTo(c - 1, anchor: .bottom) } }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }
}

#Preview("Hotkey Lab") {
    HotkeyLabView().preferredColorScheme(.dark)
}
