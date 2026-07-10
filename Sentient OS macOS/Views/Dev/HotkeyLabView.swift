//
//  HotkeyLabView.swift
//  Sentient OS macOS
//
//  DEV-ONLY bench (DEV TOOLS → HOTKEY LAB) for the global push-to-talk trigger: hold RIGHT ⌘.
//
//  The discovery this encodes (v2, corrected 2026-07-09): watch modifiers via NSEvent
//  `flagsChanged` monitors, NEVER via a CGEventTap. A tap — even listen-only, flagsChanged-only —
//  pings the Input Monitoring TCC service on creation: a fresh Mac gets the "would like to receive
//  keystrokes from any application" dialog and a system-set denial (the app then appears,
//  unchecked, in the Input Monitoring pane). The tap works anyway (modifier delivery is
//  unenforced), which is how the dialog hid during development. NSEvent monitors deliver the same
//  flagsChanged stream — keyCode and device bits included — with zero TCC contact. The one rule
//  still stands: NEVER monitor keyDown/keyUp globally (real keystrokes are the gated half).
//
//  This bench just lets us FEEL the trigger (hold vs quick-tap) and confirm it stays prompt-free.
//  Scaffolding — delete once the trigger is beyond question in the field.
//
//  Key methods: HotkeyLab.startListening()/stopListening(), onFlags(keycode:) (both monitors' handler).
//

import SwiftUI
import AppKit
import CoreGraphics         // CGPreflightListenEventAccess (diagnostic only — never prompts)
import ApplicationServices  // AXIsProcessTrusted (diagnostic only)

// MARK: - The bench model

@MainActor
@Observable
final class HotkeyLab {
    /// How long a hold must last to count as push-to-talk vs a quick type-tap.
    static let holdThreshold: TimeInterval = 0.25

    /// Right-Command virtual keycode (kVK_RightCommand). Hard-coded so this file needs no Carbon import.
    private static let rightCommandKey: Int64 = 54

    // Diagnostics ONLY — neither is required for modifier monitoring. Surfaced to make the
    // "the preflight can even say denied, and we don't care" point visible.
    var preflightListenEvent = false
    var trustedForAccessibility = false

    var listening = false
    var note = "not listening"
    var rightCmdHeld = false
    var liveHold: TimeInterval = 0
    var lastVerdict = "—"

    var log: [String] = []

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var heldMods: Set<Int64> = []
    private var rightCmdDownAt: Date?
    private var liveTimer: Timer?

    func refreshDiagnostics() {
        preflightListenEvent = CGPreflightListenEventAccess()
        trustedForAccessibility = AXIsProcessTrusted()
    }

    // MARK: The NSEvent flagsChanged monitors (zero permission, zero TCC contact)

    func startListening() {
        stopListening()
        refreshDiagnostics()
        // ONLY flagsChanged — modifier transitions, the ungated half. Never keyDown/keyUp, and
        // never a CGEventTap (its creation trips the Input Monitoring dialog — see the top comment).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.onFlags(keycode: Int64(event.keyCode))
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.onFlags(keycode: Int64(event.keyCode))
            return event
        }
        guard globalMonitor != nil, localMonitor != nil else {
            listening = false
            note = "monitor install failed (unexpected — NSEvent monitors need nothing)."
            append("✗ monitor install failed")
            return
        }
        listening = true
        note = "listening — hold right ⌘, then release. No permission needed (it's a modifier)."
        append("✓ flagsChanged NSEvent monitors started (global + local — zero permission)")
    }

    func stopListening() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        heldMods.removeAll()
        rightCmdDownAt = nil
        rightCmdHeld = false
        liveTimer?.invalidate(); liveTimer = nil
        listening = false
    }

    /// Both monitors land here: a `flagsChanged` toggles the keycode's held-state (down on first
    /// sight, up on the second) — enough for the bench's per-key ↓/↑ log.
    func onFlags(keycode: Int64) {
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
            lab.startListening()
        }
        .onDisappear { lab.stopListening() }
    }

    // MARK: Why this is free + the throwaway diagnostic

    private var infoPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.verdictColor(.survivor))
                Text("Zero permission").font(.caption.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Button("Restart monitors") { lab.startListening() }
                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
            }
            Text("Right ⌘ arrives as a modifier (flagsChanged) event, which NSEvent monitors deliver to anyone — only real keystrokes (keyDown/keyUp) are permission-gated. A CGEventTap would hear the same thing but trips the Input Monitoring dialog the moment it's created — that's why this lab (and Sidekick) use monitors, never taps.")
                .font(.caption2).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("diagnostic (ignore — NOT required):  ListenEvent preflight = \(lab.preflightListenEvent ? "true" : "false")  ·  Accessibility = \(lab.trustedForAccessibility ? "true" : "false")")
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
                Text(lab.listening ? "LISTENING" : "OFF").font(.caption2.weight(.bold))
                    .foregroundStyle(lab.listening ? Theme.verdictColor(.survivor) : Theme.faint)
            }
            Text(lab.note).font(.caption2).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
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
