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

    @Environment(\.dismiss) private var dismiss   // Reset closes Settings to reveal onboarding

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
                // Three chapters, two dividers: how Sentient runs · privacy · the exit door —
                // the second line is red on purpose (you cross it into destructive territory).
                overnightGroup
                startupGroup
                updatesGroup
                InviteSettingsSection()
                SettingsHairline(opacity: 0.12)
                    .padding(.vertical, -8)
                privacyGroup
                protectionGroup
                SettingsHairline(color: Theme.Ink.red, opacity: 0.25)
                    .padding(.vertical, -8)
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
                SettingsProse(PrivacyCopy.overnight)
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
                SettingsProse(UpdateController.appUpdatesEnabled
                    ? "Sentient keeps itself up to date automatically. When a new version is ready, Sentient asks you to update before continuing, so you're always on the latest, safest version."
                    : "App updates are disabled in this development build. Rebuild in Xcode to use your latest changes.")
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
                .disabled(!UpdateController.appUpdatesEnabled)
            }
        }
    }

    // MARK: - Privacy

    private var privacyGroup: some View {
        SettingsGroup(label: "Privacy") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsProse("Privacy-preserving diagnostics help us improve this open-source app for you.")
                    .padding(.bottom, 6)
                SettingToggleLine(title: "Share crash reports",
                                  sub: PrivacyCopy.crashReports,
                                  isOn: $crashReportsEnabled)
                SettingsHairline()
                SettingToggleLine(title: "Share extended usage analytics",
                                  sub: PrivacyCopy.extendedAnalytics,
                                  isOn: $analyticsEnabled)
                if !analyticsEnabled {
                    // The core-tier disclosure — keeps the switch honest (Analytics.swift, Tier.core):
                    // the five always-on, extremely anonymized usage-count pings.
                    Text(PrivacyCopy.coreAnalytics)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.Ink.body)
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

    // MARK: - How we protect your data (the door to the full policy)

    private var protectionGroup: some View {
        SettingsGroup(label: "How We Protect Your Data") {
            HStack(spacing: 14) {
                Text(PrivacyCopy.headline)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                SettingsPillButton(title: "Read More") { showPrivacyPolicy = true }
            }
        }
        .sheet(isPresented: $showPrivacyPolicy) { PrivacyPolicyView() }
    }

    // MARK: - Danger zone (the shared FactoryReset wipe)

    private static let dangerRed = Color(red: 1.0, green: 0.36, blue: 0.36)

    private var dangerGroup: some View {
        SettingsGroup(label: "Danger Zone") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsProse(PrivacyCopy.reset)
                SettingsPillButton(title: resetting ? "Erasing…" : "Reset Sentient…",
                                   tint: Self.dangerRed) { confirmReset = true }
                    .disabled(resetting || activity.isRunning)
                if activity.isRunning {
                    Text("A run is in progress. Reset unlocks when it finishes.")
                        .font(.system(size: 11)).foregroundStyle(Theme.Ink.amber)
                }
                if let resetError { Text(resetError).font(.system(size: 11)).foregroundStyle(Theme.Ink.amber) }
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
                    if completed { dismiss() }
                    else { resetError = "Reset couldn’t clear saved app connections. Unlock your Mac and try again." }
                }
            }
        } message: {
            Text(PrivacyCopy.resetConfirmation)
        }
    }

    // MARK: - Uninstall (the full teardown — UninstallView + System/Uninstall.swift)

    private var uninstallGroup: some View {
        SettingsGroup(label: "Uninstall") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsProse(PrivacyCopy.uninstall)
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
