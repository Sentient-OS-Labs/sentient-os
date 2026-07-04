//
//  SystemPane.swift
//  Sentient OS macOS
//
//  Settings → System: how Sentient lives on this Mac. The overnight-intelligence story (prose,
//  not a control — 3 AM is our taste, not a dial), the launch-at-login toggle (LoginItem.swift)
//  with its keep-Sentient-alive confirm, and the privacy pledge with the two anonymous-reporting
//  switches (crash reports → CrashReporting/Sentry · analytics → Analytics/TelemetryDeck).
//  The updates group lands here once Sparkle ships.
//

import SwiftUI

struct SystemPane: View {
    /// Crash reports (Sentry) — the original `diagnosticsEnabled` key, kept so existing installs
    /// carry their choice over. Analytics has its own key since the two toggles split.
    @AppStorage("diagnosticsEnabled") private var crashReportsEnabled = true
    @AppStorage("analyticsEnabled") private var analyticsEnabled = true

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var confirmLoginOff = false

    var body: some View {
        SettingsPane(title: "System.", whisper: "How Sentient lives on this Mac.") {
            VStack(alignment: .leading, spacing: 34) {
                overnightGroup
                startupGroup
                privacyGroup
            }
        }
        .task { launchAtLogin = LoginItem.isEnabled }   // live status — revocable in System Settings
    }

    // MARK: - Overnight intelligence (the story, not a setting)

    private var overnightGroup: some View {
        SettingsGroup(label: "Overnight Intelligence") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your Sentient works the night shift.")
                    .font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
                SettingsProse("Every night at 3 AM, Sentient wakes your Mac to read what's new in your life, update your knowledge base, and prepare your morning suggestions. It only happens while your Mac is plugged in, and only if Sentient is still running in your menu bar. This quiet, on-device work is what keeps your Sentient alive and helpful.")
                Text("Runs while your Mac rests.")
                    .font(.serif(11.5, weight: .regular)).italic()
                    .foregroundStyle(Theme.Ink.deepMuted)
                    .padding(.top, 3)
            }
        }
    }

    // MARK: - Launch at login

    private var startupGroup: some View {
        SettingsGroup(label: "Startup") {
            SettingToggleLine(title: "Launch Sentient at login",
                              sub: "Keeps Sentient quietly alive in your menu bar, so the 3 AM run can happen.",
                              isOn: $launchAtLogin)
        }
        .onChange(of: launchAtLogin) { _, on in
            if on {
                if !LoginItem.enable() { launchAtLogin = false }
            } else if LoginItem.isEnabled {
                launchAtLogin = true          // hold the switch until the user confirms
                confirmLoginOff = true
            }
        }
        .alert("Turn off launch at login?", isPresented: $confirmLoginOff) {
            Button("Keep It On", role: .cancel) {}
            Button("Turn Off Anyway", role: .destructive) {
                Task {
                    await LoginItem.disable()
                    launchAtLogin = LoginItem.isEnabled
                }
            }
        } message: {
            Text("To stay helpful, your Sentient runs its on-device intelligence every night at 3 AM, and that can only happen if Sentient is already running. It's heavily optimized and stays out of your RAM and CPU the rest of the time.\n\nWe recommend leaving this on to keep your Sentient alive.")
        }
    }

    // MARK: - Privacy

    private var privacyGroup: some View {
        SettingsGroup(label: "Privacy") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsProse("Sentient never collects any of your personal data, nor any AI analysis of it. Privacy is a core principle that extends to every part of Sentient, and the whole stack will always remain open source.")
                    .padding(.bottom, 6)
                SettingToggleLine(title: "Share anonymous crash reports",
                                  sub: "Privacy-friendly, structure-only reports that help us fix your bugs; never your content.",
                                  isOn: $crashReportsEnabled)
                SettingsHairline()
                SettingToggleLine(title: "Share anonymous analytics",
                                  sub: "A privacy-friendly ping that tells us how many people use Sentient; nothing more.",
                                  isOn: $analyticsEnabled)
            }
        }
        .onChange(of: crashReportsEnabled) { _, _ in CrashReporting.applyEnabledChange() }
        .onChange(of: analyticsEnabled) { _, _ in Analytics.applyEnabledChange() }
    }
}

#Preview("System pane") {
    SystemPane()
        .background(Theme.bg)
        .frame(width: 720, height: 700)
}
