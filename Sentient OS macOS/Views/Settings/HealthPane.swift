//
//  HealthPane.swift
//  Sentient OS macOS
//
//  Settings → Permissions & Health: the health board. Live verdict dots for the macOS
//  permissions (Full Disk Access, Notifications, launch-at-login) and the Codex stack
//  (installed · logged in · computer use — via the shared CodexSetup engine; every fix button
//  opens the same guided CodexSetupView the dev tools and onboarding use). Statuses re-probe
//  whenever the app comes to the foreground, so a fix made in System Settings shows up on
//  return. The danger-zone Reset is the one part still to build.
//

import SwiftUI
import AppKit
import UserNotifications

struct HealthPane: View {
    @State private var codex = CodexSetup.shared
    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var loginOn = LoginItem.isEnabled
    @State private var showCodexSetup = false
    @State private var confirmReset = false
    @State private var resetting = false
    @State private var resetDone = false

    private var allGreen: Bool {
        fdaGranted && loginOn
            && (notifStatus == .authorized || notifStatus == .provisional)
            && codex.installed && codex.loggedIn && codex.computerUseReady
    }

    var body: some View {
        SettingsPane(title: "Permissions & Health.",
                     whisper: allGreen ? "All clear. Your Sentient is healthy."
                                       : "Everything green means everything works.") {
            VStack(alignment: .leading, spacing: 30) {
                permissionsGroup
                codexGroup
                dangerGroup
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }   // the user may just have fixed something in System Settings
        }
        .sheet(isPresented: $showCodexSetup) { CodexSetupView() }
    }

    // MARK: - macOS permissions

    private var permissionsGroup: some View {
        SettingsGroup(label: "macOS Permissions") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Full Disk Access",
                           health: fdaGranted ? .ok : .bad,
                           note: fdaGranted ? "granted" : "not granted",
                           fixTitle: "Grant…") {
                    Permissions.openFullDiskAccessSettings()
                }
                if !fdaGranted {
                    HStack(spacing: 6) {
                        SettingsProse("WhatsApp, iMessage & Notes stay unreadable without it. After granting:")
                        Button { Permissions.relaunch() } label: {
                            Text("Relaunch Sentient")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.Ink.bright)
                                .underline(true, color: Theme.Ink.deepMuted)
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                    .padding(.bottom, 6)
                }
                StatusLine(title: "Notifications",
                           health: notifHealth,
                           note: notifNote,
                           fixTitle: notifStatus == .notDetermined ? "Allow…" : "Fix…") {
                    fixNotifications()
                }
                StatusLine(title: "Launch at login",
                           health: loginOn ? .ok : .warn,
                           note: loginOn ? "on" : "off",
                           fixTitle: "Turn On") {
                    LoginItem.enable()
                    loginOn = LoginItem.isEnabled
                }
            }
        }
    }

    private var notifHealth: StatusLine.Health {
        switch notifStatus {
        case .authorized, .provisional: return .ok
        case .notDetermined:            return .warn
        default:                        return .bad
        }
    }

    private var notifNote: String {
        switch notifStatus {
        case .authorized, .provisional: return "granted"
        case .notDetermined:            return "not asked yet"
        default:                        return "denied"
        }
    }

    private func fixNotifications() {
        if notifStatus == .notDetermined {
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                await refresh()
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Codex (the cloud brain)

    private var codexGroup: some View {
        SettingsGroup(label: "Codex") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Codex CLI",
                           health: codex.installed ? .ok : .bad,
                           note: codex.installed ? "installed" : "not installed",
                           fixTitle: "Install…") { showCodexSetup = true }
                StatusLine(title: "ChatGPT account",
                           health: codex.loggedIn ? .ok : .warn,
                           note: codex.loggedIn ? "logged in" : "not logged in",
                           fixTitle: "Log in…") { showCodexSetup = true }
                StatusLine(title: "Computer use",
                           health: codex.computerUseReady ? .ok : .warn,
                           note: codex.computerUseReady ? "ready" : "not set up",
                           fixTitle: "Set up…") { showCodexSetup = true }
            }
        }
    }

    // MARK: - Danger zone (the shared FactoryReset wipe)

    private static let dangerRed = Color(red: 1.0, green: 0.45, blue: 0.45)

    private var dangerGroup: some View {
        SettingsGroup(label: "Danger Zone") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsProse("Reset erases everything Sentient has learned: the knowledge base, every summary, and all suggestions. You'll start over from scratch, including the initial processing. Your cloud copy isn't touched; the next processing run simply replaces it.")
                SettingsPillButton(title: resetting ? "Erasing…" : "Reset Sentient…",
                                   tint: Self.dangerRed) { confirmReset = true }
                    .disabled(resetting)
                if resetDone {
                    Text("Reset complete. Sentient is a blank slate.")
                        .font(.serif(11.5, weight: .regular)).italic()
                        .foregroundStyle(Theme.Ink.body)
                }
            }
        }
        .alert("Erase everything Sentient has learned?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Erase Everything", role: .destructive) {
                resetting = true
                Task {
                    await FactoryReset.run()
                    resetting = false
                    resetDone = true
                }
            }
        } message: {
            Text("Your knowledge base and everything Sentient understood is deleted from this Mac. This can't be undone; Sentient starts again from zero, beginning with the initial processing.")
        }
    }

    // MARK: - Probes

    private func refresh() async {
        fdaGranted = Permissions.hasFullDiskAccess()
        loginOn = LoginItem.isEnabled
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        codex.refreshInstalled()
        codex.refreshComputerUse()
        await codex.refreshLoginStatus()
    }
}

#Preview("Permissions & Health pane") {
    HealthPane()
        .background(Theme.bg)
        .frame(width: 720, height: 640)
}
