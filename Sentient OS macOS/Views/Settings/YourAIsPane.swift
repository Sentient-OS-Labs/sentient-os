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
                if enabled && loaded {
                    heroButton
                    activityGroup
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

    // MARK: - The story (value first, then the privacy explainer)

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your ChatGPT and Claude, phone apps included, can read your Sentient knowledge base and decide what's relevant, making them dramatically more helpful about your actual life.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.Ink.statusInk)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            SettingsProse("Private by design: your real files never leave this Mac. Your AIs only ever see short summaries with personal details stripped out, organized into your knowledge base. It's end-to-end encrypted; no one, not even Sentient's developers, can read it. There is no account, one secret link only you hold is the key, and if you stop using Sentient, your cloud copy deletes itself within 30 days. Even the cloud backend is open source, so anyone can verify all of this.")
        }
    }

    // MARK: - The share toggle

    private var cloudSyncGroup: some View {
        SettingsGroup(label: "Cloud Sync") {
            SettingToggleLine(title: "Offer your knowledge base to your AIs",
                              sub: "ChatGPT and Claude read it over MCP. No account, just a private link that only you hold.",
                              isOn: $enabled)
                .disabled(busy || !loaded)
        }
        .onChange(of: enabled) { was, now in
            guard loaded, !busy else { return }
            if now { turnOn() } else if was {
                enabled = true                     // hold until the user confirms the delete
                confirmOff = true
            }
        }
        .alert("Stop sharing your knowledge base?", isPresented: $confirmOff) {
            Button("Keep Sharing", role: .cancel) {}
            Button("Stop & Delete Cloud Copy", role: .destructive) { turnOff() }
        } message: {
            Text("The cloud copy is deleted immediately and your AIs lose access. Your knowledge base stays safe on this Mac, and turning sharing back on restores the same link.")
        }
    }

    private func turnOn() {
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

    // MARK: - The hero: the guided setup

    private var heroButton: some View {
        GlowButton(title: "Connect your AIs", systemImage: "sparkles") {
            openWindow(id: ConnectAIsView.windowID)
        }
        .frame(maxWidth: 340)
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

#Preview("Your AIs pane") {
    YourAIsPane()
        .background(Theme.bg)
        .frame(width: 720, height: 640)
}
