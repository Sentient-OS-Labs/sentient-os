//
//  PlaceholderPanes.swift
//  Sentient OS macOS
//
//  Styled skeletons for the settings panes that haven't been built yet — each previews its REAL
//  future form (chips for sources, fields for instructions, status dots for health) so the window
//  feels whole and the design is judgeable now. This file shrinks as each pane lands as its own
//  real file (SourcesPane, ProactivePane, YourAIsPane, HealthPane) and dies with the last one.
//

import SwiftUI

struct ProactivePanePlaceholder: View {
    var body: some View {
        SettingsPane(title: "Proactive & Sidekick.",
                     whisper: "Morning suggestions, and the hold-to-talk magic in your notch.") {
            VStack(alignment: .leading, spacing: 30) {
                SettingsGroup(label: "Proactive Intelligence", badge: "coming soon") {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsProse("Every morning, Sentient surfaces a few things worth doing — already done, waiting for your go. Tell it what you care about, and what to skip.")
                        SettingsFieldPreview(placeholder: "e.g. Don't give me suggestions about Chase Bank alerts.")
                    }
                }
                SettingsGroup(label: "Sidekick", badge: "coming soon") {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsProse("Hold the shortcut key and just talk — \u{201C}finish this for me\u{201D} — and Sidekick acts on whatever you're looking at.")
                        HStack(spacing: 8) {
                            SettingsChip(label: "Right ⌘", on: true)
                            SettingsChip(label: "Right ⌥", on: false)
                        }
                        SettingsFieldPreview(placeholder: "e.g. When I say text someone, use WhatsApp. My main browser is Microsoft Edge.")
                    }
                }
            }
        }
    }
}

struct HealthPanePlaceholder: View {
    var body: some View {
        SettingsPane(title: "Permissions & Health.",
                     whisper: "Everything green means everything works.") {
            VStack(alignment: .leading, spacing: 30) {
                SettingsGroup(label: "macOS Permissions", badge: "coming soon") {
                    VStack(alignment: .leading, spacing: 2) {
                        StatusLine(title: "Full Disk Access", health: .ok, note: "granted")
                        StatusLine(title: "Notifications", health: .warn, note: "not granted", fix: {})
                    }
                }
                SettingsGroup(label: "Codex", badge: "coming soon") {
                    VStack(alignment: .leading, spacing: 2) {
                        StatusLine(title: "Codex CLI", health: .ok, note: "installed")
                        StatusLine(title: "ChatGPT account", health: .ok, note: "logged in")
                        StatusLine(title: "Computer use", health: .bad, note: "not set up", fixTitle: "Set up…", fix: {})
                    }
                }
                SettingsGroup(label: "Danger Zone", badge: "coming soon") {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsProse("Reset erases everything Sentient has learned — you'll return to onboarding and run the initial overnight processing again.")
                        Text("Reset Sentient…")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45).opacity(0.85))
                    }
                }
            }
        }
    }
}
