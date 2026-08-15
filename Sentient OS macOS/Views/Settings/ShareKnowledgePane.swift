//
//  ShareKnowledgePane.swift
//  Sentient OS macOS
//
//  Settings → Give AIs Knowledge: the value + privacy story up top, then the HERO: the glowing
//  "Set up in 2 minutes" button → the real guided setup (ConnectAIsView), always visible — the
//  window owns sharing on AND off (its consent veil / MCP pill), so this pane carries no toggle.
//  Live activity from /stats below when sharing is on. Regenerate lives in MirrorClient only
//  (a support/dev remediation; a UI button was a footgun that bricks every connector).
//

import SwiftUI
import AppKit

struct ShareKnowledgePane: View {
    @Environment(\.openWindow) private var openWindow

    @State private var enabled = false
    @State private var stats: MirrorClient.Stats?
    @State private var loaded = false

    var body: some View {
        SettingsPane(title: "ChatGPT & Claude",
                     whisper: "Your knowledge base, offered to every AI you already use.") {
            VStack(alignment: .leading, spacing: 30) {
                intro
                cloudSyncGroup
                    .padding(.top, 10)    // same breath as before Activity — the blurb block stands alone
                if enabled && loaded {
                    activityGroup
                        .padding(.top, 10)    // extra breath after the hero
                } else if loaded {
                    localOnlyProse
                }
            }
        }
        .task { await refresh() }
        // Sharing flips inside the ConnectAIsView window now — re-probe when the user clicks
        // back into Settings so Activity vs. local-only never shows a stale answer.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refresh() }
        }
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
                pillar("lock.fill", "Zero-access encryption: the key is held only by your Mac and your private link, never on our servers. Hack them and all you'd find is ciphertext with no key to unlock it.")
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

    // MARK: - Cloud Sync (no toggle — ConnectAIsView owns sharing on/off; the hero is the door)

    private var cloudSyncGroup: some View {
        SettingsGroup(label: "Cloud Sync") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Offer your knowledge base to your AIs")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    Text("ChatGPT and Claude read it over MCP. No account, just a private link that only you hold.")
                        .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ConnectCTA(title: enabled ? "Configure" : "Set up in 2 minutes") {
                    openWindow(id: ConnectAIsView.windowID)
                }
            }
        }
    }

    // MARK: - Activity

    private var activityGroup: some View {
        SettingsGroup(label: "Activity") {
            VStack(alignment: .leading, spacing: 7) {
                Text(activityLine)
                    .font(.system(size: 13))
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
    let title: String
    let action: () -> Void

    private var gradient: AngularGradient {
        AngularGradient(colors: GlowHalo.stops, center: .center)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
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

#Preview("Give AIs Knowledge pane") {
    ShareKnowledgePane()
        .background(Theme.bg)
        .frame(width: 720, height: 640)
}
