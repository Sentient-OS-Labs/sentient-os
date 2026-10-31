//
//  SystemPane.swift
//  Sentient OS macOS
//
//  Settings → System: updates, privacy controls, and the
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

    @State private var showPrivacyPolicy = false
    @State private var confirmReset = false
    @State private var resetting = false
    @State private var resetError: String?
    @State private var showUninstall = false

    var body: some View {
        SettingsPane(title: "System", whisper: "How Sentient lives on this Mac.") {
            VStack(alignment: .leading, spacing: 34) {
                SettingsGroup(label: "Updates", inset: 0) { updatesGroup }
                privacyGroup
                SettingsGroup(label: "Danger zone", description: "Remove your knowledge or uninstall Sentient.", inset: 0, destructive: true) {
                    VStack(spacing: 0) {
                        dangerGroup
                        SettingsHairline(opacity: 0.10)
                        uninstallGroup
                    }
                }

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
                SettingsProse(PrivacyCopy.coreAnalytics)
                    .padding(.horizontal, 20).padding(.bottom, 20)
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

    // MARK: - Danger zone

    private static let dangerRed = Color(red: 1.0, green: 0.36, blue: 0.36)

    // Running analysis is cancellable. Only another teardown blocks these actions.
    private var maintenanceInProgress: Bool {
        resetting || appState.processing.isSuspended || appState.isUninstalling
    }

    private var resetTitle: String {
        guard resetting else { return "Reset Sentient…" }
        return appState.processing.isBusy || appState.commandCoordinator.run.isRunning
            ? "Stopping…" : "Erasing…"
    }

    private var dangerGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Reset Sentient", subtitle: "Erase learned knowledge and return to setup.") {
                SettingsPillButton(title: resetTitle, tint: Self.dangerRed) {
                    confirmReset = true
                }
                .disabled(maintenanceInProgress)
            }
            SettingsDetails(title: "What gets removed?") { SettingsProse(PrivacyCopy.reset) }
                .padding(.horizontal, 20).padding(.bottom, 20)
            if appState.processing.isBusy {
                SettingsProse(resetting ? "Stopping analysis safely before erasing your knowledge."
                              : "Reset will stop analysis before erasing your knowledge.")
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
                    .disabled(maintenanceInProgress)
            }
            SettingsDetails(title: "What gets removed?") { SettingsProse(PrivacyCopy.uninstall) }
                .padding(.horizontal, 20).padding(.bottom, 20)
            if appState.processing.isBusy {
                SettingsProse("Uninstall will stop analysis before removing Sentient’s data.")
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
