//
//  YourAIsPane.swift
//  Sentient OS macOS
//
//  Settings → Your AIs: the hosted MCP mirror, wired to MirrorClient. The share toggle (off =
//  deletes the cloud copy, token kept so the URL survives re-enabling), the secret URL (masked;
//  copy + regenerate), the connect guide + system prompt, and the live activity stats. When
//  sharing is off, the local-only story takes the stage.
//

import SwiftUI
import AppKit

struct YourAIsPane: View {
    @Environment(\.openWindow) private var openWindow

    @State private var enabled = false
    @State private var shareURL: String?
    @State private var stats: MirrorClient.Stats?
    @State private var loaded = false
    @State private var busy = false                // a network call is in flight — freeze the toggle
    @State private var confirmOff = false
    @State private var confirmRegenerate = false
    @State private var copied = false
    @State private var errorLine: String?

    var body: some View {
        SettingsPane(title: "Your AIs.",
                     whisper: "Your knowledge base, offered to every AI you already use.") {
            VStack(alignment: .leading, spacing: 30) {
                cloudSyncGroup
                if enabled && loaded {
                    urlGroup
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

    // MARK: - The share toggle

    private var cloudSyncGroup: some View {
        SettingsGroup(label: "Cloud Sync") {
            SettingToggleLine(title: "Offer your knowledge base to your AIs",
                              sub: "ChatGPT and Claude read it over MCP. No account, just a secret link with a 30-day lease that cleans up after itself.",
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
                let url = try await MirrorClient.shared.enable()
                try? await MirrorClient.shared.push()      // best-effort first fill (no vault yet is fine)
                shareURL = url
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

    // MARK: - The secret URL

    private var urlGroup: some View {
        SettingsGroup(label: "Your Secret Link") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(maskedURL)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.Ink.bright)
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                    Button { copyURL() } label: {
                        MonoCaps(copied ? "Copied ✓" : "Copy", size: 8.5, tracking: 1.6,
                                 color: copied ? Theme.Ink.mint : Theme.Ink.bright)
                    }
                    .buttonStyle(PressScaleStyle())
                    Button { confirmRegenerate = true } label: {
                        MonoCaps("Regenerate", size: 8.5, tracking: 1.6, color: Theme.Ink.label)
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(busy)
                }
                SettingsProse("This link is your whole identity; there's no account behind it. Paste it into ChatGPT or Claude as a connector, and treat it like a password.")
                HStack(spacing: 18) {
                    quietLink("How to connect your AIs") { openWindow(id: ConnectAIsView.windowID) }
                    quietLink("Copy the system prompt") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MirrorClient.systemPrompt, forType: .string)
                    }
                }
            }
        }
        .alert("Regenerate your secret link?", isPresented: $confirmRegenerate) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) { regenerate() }
        } message: {
            Text("The old link stops working immediately, and every AI you've connected will need the new one. Do this if the link ever leaks.")
        }
    }

    private var maskedURL: String {
        // ⚠️ "/mcp" must be searched BACKWARDS: the host "https://mcp.sentient-os.ai" itself
        // contains "/mcp" (second slash + host), and a forward hit put `end` before the token —
        // an inverted range that crashed the pane. Guard the order defensively regardless.
        guard let url = shareURL,
              let range = url.range(of: "/u/"),
              let end = url.range(of: "/mcp", options: .backwards),
              range.upperBound <= end.lowerBound else { return "mcp.sentient-os.ai/u/…/mcp" }
        let token = url[range.upperBound..<end.lowerBound]
        let host = url.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")     // dev SENTIENT_MIRROR_BASE override
            .prefix(while: { $0 != "/" })
        return "\(host)/u/\(token.prefix(4))••••••••/mcp"
    }

    private func copyURL() {
        guard let url = shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.8)); copied = false }
    }

    private func regenerate() {
        busy = true; errorLine = nil
        Task {
            do { shareURL = try await MirrorClient.shared.regenerateToken() }
            catch { errorLine = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            busy = false
        }
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

    // MARK: - Helpers

    private func quietLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Ink.label)
                .underline(true, color: Theme.Ink.deepMuted)
        }
        .buttonStyle(PressScaleStyle())
    }

    private func refresh() async {
        enabled = await MirrorClient.shared.isEnabled
        shareURL = await MirrorClient.shared.shareURL
        loaded = true
        if enabled { stats = try? await MirrorClient.shared.stats() }
    }
}

#Preview("Your AIs pane") {
    YourAIsPane()
        .background(Theme.bg)
        .frame(width: 720, height: 640)
}
