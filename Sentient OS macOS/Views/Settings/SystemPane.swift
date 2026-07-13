//
//  SystemPane.swift
//  Sentient OS macOS
//
//  Settings → System: how Sentient lives on this Mac. The overnight-intelligence story (prose,
//  not a control — 3 AM is our taste, not a dial), the launch-at-login toggle (LoginItem.swift)
//  with its keep-Sentient-alive confirm, the privacy pledge with the two anonymous-reporting
//  switches (crash reports → CrashReporting/Sentry · analytics → Analytics/TelemetryDeck), and
//  the danger-zone Reset (the shared FactoryReset wipe — a system-level act, so it lives here),
//  and the Uninstall group (the farewell sheet → the full System/Uninstall teardown).
//  The updates group lands here once Sparkle ships.
//

import SwiftUI

struct SystemPane: View {
    @Environment(AppState.self) private var appState   // for the updater (Check Now / version)

    /// Crash reports (Sentry) — the original `diagnosticsEnabled` key, kept so existing installs
    /// carry their choice over. Analytics has its own key since the two toggles split.
    @AppStorage("diagnosticsEnabled") private var crashReportsEnabled = true
    @AppStorage("analyticsEnabled") private var analyticsEnabled = true

    @Environment(\.dismiss) private var dismiss   // Reset closes Settings to reveal onboarding

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var confirmLoginOff = false
    @State private var confirmReset = false
    @State private var resetting = false
    @State private var showUninstall = false
    @State private var activity = PipelineActivity.shared   // Reset + Uninstall lock while a run is active

    var body: some View {
        SettingsPane(title: "System", whisper: "How Sentient lives on this Mac.") {
            VStack(alignment: .leading, spacing: 34) {
                overnightGroup
                startupGroup
                updatesGroup
                privacyGroup
                dangerGroup
                uninstallGroup
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
                    .font(.system(size: 11.5))
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

    // MARK: - Updates (Sparkle — the story is "we keep you current", not a dial)

    private var updatesGroup: some View {
        SettingsGroup(label: "Updates") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsProse("Sentient keeps itself up to date automatically. When a new version is ready, Sentient asks you to update before continuing, so you're always on the latest, safest version.")
                HStack(spacing: 6) {
                    Text("Version \(UpdateController.currentVersionString)")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                    if let last = appState.update.lastCheckDate {
                        Text("· checked \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                    }
                }
                SettingsPillButton(title: "Check for Updates Now") {
                    appState.update.checkForUpdatesNow(from: .settings)
                }
            }
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
                                  sub: "Share the fuller picture: anonymous usage signals through a privacy-first, open-source analytics framework; structure only, never any of your personal information.",
                                  isOn: $analyticsEnabled)
                if !analyticsEnabled {
                    // The core-tier disclosure — keeps the switch honest (Analytics.swift, Tier.core):
                    // a bare minimum of anonymous feature-use counts always sends.
                    Text("Even with this off, Sentient keeps a bare minimum of anonymous telemetry: simple counts of app opens and feature use that are core to building Sentient. Never your content, never anything personal.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.Ink.deepMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: analyticsEnabled)
        }
        .onChange(of: crashReportsEnabled) { _, _ in CrashReporting.applyEnabledChange() }
        .onChange(of: analyticsEnabled) { _, _ in Analytics.applyEnabledChange() }
    }

    // MARK: - Danger zone (the shared FactoryReset wipe)

    private static let dangerRed = Color(red: 1.0, green: 0.36, blue: 0.36)

    private var dangerGroup: some View {
        SettingsGroup(label: "Danger Zone") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsProse("Reset erases everything Sentient has learned: the knowledge base, every summary, all suggestions, and the cloud copy your AIs read. Sentient takes you back through setup and starts over from scratch. Your private link stays valid; the next processing run fills it again.")
                SettingsPillButton(title: resetting ? "Erasing…" : "Reset Sentient…",
                                   tint: Self.dangerRed) { confirmReset = true }
                    .disabled(resetting || activity.isRunning)
                if activity.isRunning {
                    Text("A run is in progress. Reset unlocks when it finishes.")
                        .font(.system(size: 11)).foregroundStyle(Theme.Ink.amber)
                }
            }
        }
        .alert("Erase everything Sentient has learned?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Erase Everything", role: .destructive) {
                resetting = true
                Task {
                    await FactoryReset.run(appState: appState)
                    resetting = false
                    dismiss()   // close Settings — the main window is now the start of onboarding
                }
            }
        } message: {
            Text("Your knowledge base and everything Sentient understood is deleted from this Mac, and the cloud copy is removed. This can't be undone; Sentient takes you back through setup, beginning with the initial processing.")
        }
    }

    // MARK: - Uninstall (the full teardown — UninstallView + System/Uninstall.swift)

    private var uninstallGroup: some View {
        SettingsGroup(label: "Uninstall") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsProse("Uninstall removes everything Sentient created on this Mac: the on-device model, your knowledge base, the private cloud copy your AIs read, the overnight wake helper, and every setting. Your own files stay exactly where they are.")
                SettingsPillButton(title: "Uninstall Sentient…", tint: Self.dangerRed) {
                    showUninstall = true
                }
                .disabled(activity.isRunning)
                if activity.isRunning {
                    Text("A run is in progress. Uninstall unlocks when it finishes.")
                        .font(.system(size: 11)).foregroundStyle(Theme.Ink.amber)
                }
            }
        }
        .sheet(isPresented: $showUninstall) { UninstallView() }
    }
}

#Preview("System pane") {
    SystemPane()
        .background(Theme.bg)
        .frame(width: 720, height: 700)
}
