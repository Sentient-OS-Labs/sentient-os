//
//  YourAIsPane.swift
//  Sentient OS macOS
//
//  Settings → Your AIs: the value + privacy story up top, the share toggle (off = confirm, then
//  the cloud copy is deleted; the token is kept so the link survives re-enabling), and the HERO:
//  the glowing "Connect your AIs" button → the real guided setup (ConnectAIsView), which owns the
//  secret link + system prompt. Live activity from /stats below. Regenerate lives in MirrorClient
//  only (a support/dev remediation; a UI button was a footgun that bricks every connector).
//

import SwiftUI
import AppKit

struct YourAIsPane: View {
    @Environment(\.openWindow) private var openWindow

    @State private var enabled = false
    @State private var stats: MirrorClient.Stats?
    @State private var loaded = false
    @State private var busy = false                // a network call is in flight — freeze the toggle
    @State private var confirmOff = false
    @State private var errorLine: String?

    var body: some View {
        SettingsPane(title: "Your AIs.",
                     whisper: "Your knowledge base, offered to every AI you already use.") {
            VStack(alignment: .leading, spacing: 30) {
                intro
                cloudSyncGroup
                    .padding(.top, 10)    // same breath as before Activity — the blurb block stands alone
                if enabled && loaded {
                    heroButton
                        .padding(.top, -14)   // belongs to the Cloud Sync group, not floating between groups
                    activityGroup
                        .padding(.top, 10)    // extra breath after the hero
                } else if loaded {
                    localOnlyProse
                }
                if let errorLine {
                    Text(errorLine)
                        .font(.system(size: 11)).foregroundStyle(Theme.Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await refresh() }
    }

    // MARK: - The story (value first, then four scannable privacy pillars — never a wall of text)

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your ChatGPT and Claude, phone apps included, can read your Sentient knowledge base, making them dramatically more helpful.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.Ink.statusInk)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 9) {
                pillar("lock.shield", "Your real files never leave this Mac. Your AIs only see short summaries, personal details stripped.")
                pillar("lock.fill", "End-to-end encrypted: no one, not even Sentient's developers, can read your knowledge base.")
                pillar("key.fill", "No account. One secret link only you hold; leave Sentient and the cloud copy deletes itself in 30 days.")
                pillar("chevron.left.forwardslash.chevron.right", "Even the cloud backend is open source. Everything's verifiable.")
            }
        }
    }

    private func pillar(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Ink.green.opacity(0.8))
                .frame(width: 15)
            Text(text)
                .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.body)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The share toggle

    private var cloudSyncGroup: some View {
        SettingsGroup(label: "Cloud Sync") {
            // A custom binding, NOT $enabled + onChange: the setter fires only when the USER flips
            // the control, so programmatic `enabled =` writes can't re-trigger the confirm flow.
            // (The old onChange guard checked `busy`, but turnOff() cleared `busy` in the same
            // transaction as `enabled = false` — onChange then read busy == false, mistook the
            // write for a user flip, and re-showed the dialog forever.)
            SettingToggleLine(title: "Offer your knowledge base to your AIs",
                              sub: "ChatGPT and Claude read it over MCP. No account, just a private link that only you hold.",
                              isOn: Binding(
                                  get: { enabled },
                                  set: { requested in
                                      if requested { turnOn() } else { confirmOff = true }
                                  }))
                .disabled(busy || !loaded)
        }
        .alert("Stop sharing your knowledge base?", isPresented: $confirmOff) {
            Button("Keep Sharing", role: .cancel) {}       // switch never changed — stays on
            Button("Stop & Delete Cloud Copy", role: .destructive) { turnOff() }
        } message: {
            Text("The cloud copy is deleted immediately and your AIs lose access. Your knowledge base stays safe on this Mac, and turning sharing back on restores the same link.")
        }
    }

    private func turnOn() {
        enabled = true                                     // optimistic — the switch answers instantly
        busy = true; errorLine = nil
        Task {
            do {
                _ = try await MirrorClient.shared.enable()
                try? await MirrorClient.shared.push()      // best-effort first fill (no vault yet is fine)
            } catch {
                enabled = false
                errorLine = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            busy = false
        }
    }

    private func turnOff() {
        busy = true; errorLine = nil
        Task {
            await MirrorClient.shared.disable()
            enabled = false
            stats = nil
            busy = false
        }
    }

    // MARK: - The hero: the guided setup (settings-scale glow — a gradient ring, not the home's sun)

    private var heroButton: some View {
        ConnectCTA { openWindow(id: ConnectAIsView.windowID) }
    }

    // MARK: - Activity

    private var activityGroup: some View {
        SettingsGroup(label: "Activity") {
            VStack(alignment: .leading, spacing: 7) {
                Text(activityLine)
                    .font(.serif(13, weight: .regular)).italic()
                    .foregroundStyle(Theme.Ink.body)
                if let last = stats?.lastAccess {
                    MonoCaps("Last read · \(last.formatted(.relative(presentation: .named)))",
                             size: 8.5, tracking: 1.6, color: Theme.Ink.deepMuted)
                }
            }
        }
    }

    private var activityLine: String {
        guard let stats else { return "No activity yet. Connect an AI and ask it about you." }
        if stats.notesRead24h == 0 { return "Your AIs haven't read anything in the last day." }
        return "Your AIs read \(stats.notesRead24h) note\(stats.notesRead24h == 1 ? "" : "s") in the last 24 hours."
    }

    // MARK: - Local-only (shown when sharing is off)

    private var localOnlyProse: some View {
        SettingsGroup(label: "Prefer fully offline?") {
            SettingsProse("Your knowledge base is a plain markdown folder on this Mac; point Claude Code or any local AI at it directly. Sharing above is only for the AIs that live in the cloud.")
        }
    }

    // MARK: - Probes

    private func refresh() async {
        enabled = await MirrorClient.shared.isEnabled
        loaded = true
        if enabled { stats = try? await MirrorClient.shared.stats() }
    }
}

/// The pane's compact glow CTA: a dark capsule with the AI-gradient as a thin ring + a soft
/// halo behind it. Jewelry at settings scale — deliberately NOT the home's big white GlowButton.
private struct ConnectCTA: View {
    let action: () -> Void

    private var gradient: AngularGradient {
        AngularGradient(colors: GlowHalo.stops, center: .center)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                Text("Connect your AIs").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(Capsule().fill(Theme.Ink.cardBG))
            .overlay(Capsule().strokeBorder(gradient, lineWidth: 1.2))
            .background(Capsule().fill(gradient).blur(radius: 9).opacity(0.38))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

#Preview("Your AIs pane") {
    YourAIsPane()
        .background(Theme.bg)
        .frame(width: 720, height: 640)
}
