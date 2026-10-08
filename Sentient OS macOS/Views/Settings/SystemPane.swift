//
//  SystemPane.swift
//  Sentient OS macOS
//
//  Settings → System: how Sentient lives on this Mac. The overnight-intelligence story (prose,
//  not a control — 3 AM is our taste, not a dial), the launch-at-login toggle (LoginItem.swift)
//  with its keep-Sentient-alive confirm, the privacy pledge with the two anonymous-reporting
//  switches (crash reports → CrashReporting/Sentry · analytics → Analytics/TelemetryDeck), the
//  how-we-protect-your-data line with its Read More door to the PrivacyPolicyView sheet, the
//  danger-zone Reset (the shared FactoryReset wipe — a system-level act, so it lives here),
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


    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var confirmLoginOff = false
    @State private var confirmReset = false
    @State private var resetting = false
    @State private var resetError: String?
    @State private var showUninstall = false
    @State private var showPrivacyPolicy = false
    @State private var activity = PipelineActivity.shared   // Reset + Uninstall lock while a run is active

    var body: some View {
        SettingsPane(title: "System", whisper: "How Sentient lives on this Mac.") {
            VStack(alignment: .leading, spacing: 34) {
                startupGroup
                privacyGroup
                InviteSettingsSection()
                SettingsGroup(label: "Danger zone", description: "Remove your knowledge or uninstall Sentient.", inset: 0, destructive: true) {
                    VStack(spacing: 0) {
                        dangerGroup
                        SettingsHairline(opacity: 0.10)
                        uninstallGroup
                    }
                }

            }
        }
        .task { launchAtLogin = LoginItem.isEnabled }   // live status — revocable in System Settings
    }

    // MARK: - General

    private var startupGroup: some View {
        SettingsGroup(label: "General", inset: 0) {
            VStack(spacing: 0) {
                SettingToggleLine(title: "Launch at login",
                                  sub: "Keep Sentient ready in your menu bar.", isOn: $launchAtLogin)
                SettingsHairline(opacity: 0.10)
                SettingsRow(title: "Overnight intelligence", subtitle: "New knowledge and morning suggestions, prepared at 3 AM.") {
                    Text("3:00 AM").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SettingsStyle.secondary)
                }
                SettingsDetails(title: "When does overnight intelligence run?") {
                    SettingsProse(PrivacyCopy.overnight)
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
                SettingsHairline(opacity: 0.10)
                updatesGroup
            }
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
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Updates", subtitle: "Version \(UpdateController.currentVersionString)") {
                SettingsPillButton(title: "Check for updates") {
                    appState.update.checkForUpdatesNow(from: .settings)
                }
                .disabled(!UpdateController.appUpdatesEnabled)
            }
            if let last = appState.update.lastCheckDate {
                Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
            if !UpdateController.appUpdatesEnabled {
                SettingsProse("Updates are disabled in this development build.")
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
    }

    // MARK: - Privacy

    private var privacyGroup: some View {
        SettingsGroup(label: "Privacy", inset: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SettingToggleLine(title: "Share crash reports", sub: PrivacyCopy.crashReports,
                                  isOn: $crashReportsEnabled)
                SettingsHairline(opacity: 0.10)
                SettingToggleLine(title: "Share extended usage analytics", sub: PrivacyCopy.extendedAnalytics,
                                  isOn: $analyticsEnabled)
                if !analyticsEnabled {
                    SettingsProse(PrivacyCopy.coreAnalytics)
                        .padding(.horizontal, 20).padding(.bottom, 20)
                        .transition(.opacity)
                }
                SettingsHairline(opacity: 0.10)
                SettingsRow(title: "Your data", subtitle: PrivacyCopy.headline) {
                    SettingsPillButton(title: "Privacy policy") { showPrivacyPolicy = true }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: analyticsEnabled)
        }
        .onChange(of: crashReportsEnabled) { _, _ in CrashReporting.applyEnabledChange() }
        .onChange(of: analyticsEnabled) { _, _ in Analytics.applyEnabledChange() }
        .sheet(isPresented: $showPrivacyPolicy) { PrivacyPolicyView() }
    }

    // MARK: - Danger zone (the shared FactoryReset wipe)

    private static let dangerRed = Color(red: 1.0, green: 0.36, blue: 0.36)

    private var dangerGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Reset Sentient", subtitle: "Erase learned knowledge and return to setup.") {
                SettingsPillButton(title: resetting ? "Erasing…" : "Reset Sentient…", tint: Self.dangerRed) {
                    confirmReset = true
                }
                .disabled(resetting || activity.isRunning)
            }
            SettingsDetails(title: "What gets removed?") { SettingsProse(PrivacyCopy.reset) }
                .padding(.horizontal, 20).padding(.bottom, 20)
            if activity.isRunning {
                SettingsProse("Reset is available after the current run finishes.")
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
            if let resetError {
                Text(resetError).font(.system(size: 13)).foregroundStyle(Theme.Ink.amber)
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .alert("Erase everything Sentient has learned?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Knowledge", role: .destructive) {
                resetting = true
                Task {
                    resetError = nil
                    let completed = await FactoryReset.run(appState: appState)
                    resetting = false
                    if completed { HomeWindowOpening.open() }
                    else { resetError = "Reset couldn’t clear saved app connections. Unlock your Mac and try again." }
                }
            }
        } message: {
            Text(PrivacyCopy.resetConfirmation)
        }
    }

    // MARK: - Uninstall (the full teardown — UninstallView + System/Uninstall.swift)

    private var uninstallGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Uninstall Sentient", subtitle: "Remove Sentient and its local data from this Mac.") {
                SettingsPillButton(title: "Uninstall…", tint: Self.dangerRed) { showUninstall = true }
                    .disabled(activity.isRunning)
            }
            SettingsDetails(title: "What gets removed?") { SettingsProse(PrivacyCopy.uninstall) }
                .padding(.horizontal, 20).padding(.bottom, 20)
            if activity.isRunning {
                SettingsProse("Uninstall is available after the current run finishes.")
                    .padding(.horizontal, 20).padding(.bottom, 16)
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
