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
        SettingsPane(title: "Give AIs Knowledge",
                     whisper: "Let ChatGPT, Claude, and other AIs get to know you.") {
            VStack(alignment: .leading, spacing: 32) {
                cloudSyncGroup
                SettingsGroup(label: "Your knowledge, your control") {
                    VStack(alignment: .leading, spacing: 18) {
                        SettingsProse("Sharing is optional. Your original knowledge stays in a folder on this Mac.")
                        SettingsDetails(title: "How sharing and privacy work") {
                            SettingsProse(PrivacyCopy.sharingContents)
                            SettingsProse(PrivacyCopy.sharingEncryption)
                            SettingsProse(PrivacyCopy.sharingControl)
                            SettingsProse(PrivacyCopy.sharingOpenSource)
                        }
                    }
                }
                if enabled && loaded { activityGroup }
                else if loaded { localOnlyProse }
            }
        }
        .task { await refresh() }
        // Sharing flips inside the ConnectAIsView window now — re-probe when the user clicks
        // back into Settings so Activity vs. local-only never shows a stale answer.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refresh() }
        }
    }

    // MARK: - Sharing setup owns both enabling and disabling the mirror

    private var cloudSyncGroup: some View {
        SettingsGroup(label: "AI connections", inset: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(title: "Share your knowledge",
                            subtitle: "Connect your AIs with a private link. Works on your phone, too.") {
                    SettingsPillButton(title: enabled ? "Configure" : "Set up sharing") {
                        openWindow(id: ConnectAIsView.windowID)
                    }
                }
                if loaded {
                    SettingsHairline(opacity: 0.10)
                    HStack(spacing: 9) {
                        Circle().fill(enabled ? Theme.Ink.green : SettingsStyle.secondary)
                            .frame(width: 6, height: 6)
                        Text(enabled ? "Sharing is on" : "Sharing is off")
                            .font(.system(size: 14)).foregroundStyle(SettingsStyle.secondary)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                }
            }
        }
    }

    // MARK: - Activity

    private var activityGroup: some View {
        SettingsGroup(label: "Activity") {
            VStack(alignment: .leading, spacing: 7) {
                Text(activityLine)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Ink.body)
                if let last = stats?.lastAccess {
                    Text("Last read \(last.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 13)).foregroundStyle(SettingsStyle.secondary)
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
        SettingsGroup(label: "Use your knowledge locally") {
            SettingsProse(PrivacyCopy.localKnowledge)
        }
    }

    // MARK: - Probes

    private func refresh() async {
        enabled = await MirrorClient.shared.isEnabled
        loaded = true
        if enabled { stats = try? await MirrorClient.shared.stats() }
    }
}

#Preview("Give AIs Knowledge pane") {
    ShareKnowledgePane()
        .background(Theme.bg)
        .frame(width: 720, height: 640)
}
