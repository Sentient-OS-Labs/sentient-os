//
//  HealthPane.swift
//  Sentient OS macOS
//
//  Settings → Permissions & Health: the health board. Live LED rows for every grant Sentient
//  actually asks for, in severity order — SENTIENT (Full Disk Access · the overnight wake daemon ·
//  launch-at-login · mic & speech · notifications), SET UP CODEX (CLI · account · computer use,
//  via the shared CodexSetup engine), and CODEX PERMISSIONS (the helper's Accessibility + Screen
//  Recording — system-TCC, status-only, shown once computer use exists). The Automation grant has
//  NO row: it self-heals silently shortly after the pane opens (the user has no job there).
//  Red = a core capability is broken · yellow = optional or fixable-later. When the whole codex
//  stack is green it collapses to one glowing summary line (tap for details) — a browsing user
//  shouldn't wade through five rows of "fine". Statuses re-probe on app foreground and after the
//  codex sheet closes. (Reset lives in Settings → System.)
//

import SwiftUI
import AppKit
import AVFoundation
import Speech
import UserNotifications
import ServiceManagement   // SMAppService.Status — the wake daemon's registration state

struct HealthPane: View {
    @State private var codex = CodexSetup.shared

    // Sentient's own grants
    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    @State private var daemon: DaemonState = .notSetUp
    @State private var loginOn = LoginItem.isEnabled
    @State private var micSpeech: MicSpeechState = .notAsked
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    // The Codex helper's system-TCC grants (read via FDA; shown once computer use exists)
    @State private var helperAccessibility = false
    @State private var helperScreenRecording = false

    @State private var showCodexSetup = false
    @State private var codexExpanded = false

    private enum DaemonState { case ready, awaitingApproval, notSetUp }
    private enum MicSpeechState { case granted, notAsked, denied }

    private var showCodexPermissions: Bool { fdaGranted && codex.computerUseReady }

    /// The whole codex stack, healthy — the CLI, the account, computer use, AND its two helper
    /// grants (verifiable only with FDA; unverifiable never claims "all good").
    private var codexAllGreen: Bool {
        codex.installed && codex.loggedIn && codex.computerUseReady
            && fdaGranted && helperAccessibility && helperScreenRecording
    }

    private var allGreen: Bool {
        fdaGranted && daemon == .ready && loginOn && micSpeech == .granted
            && (notifStatus == .authorized || notifStatus == .provisional)
            && codex.installed && codex.loggedIn && codex.computerUseReady
            && (!showCodexPermissions || (helperAccessibility && helperScreenRecording))
    }

    var body: some View {
        SettingsPane(title: "Permissions & Health.",
                     whisper: allGreen ? "All clear. Your Sentient is healthy."
                                       : "Everything green means everything works.") {
            VStack(alignment: .leading, spacing: 30) {
                sentientGroup
                if codexAllGreen {
                    SettingsGroup(label: "Codex") { codexSummaryLine }
                    if codexExpanded {
                        codexSetupGroup
                        codexPermissionsGroup
                    }
                } else {
                    codexSetupGroup
                    if showCodexPermissions { codexPermissionsGroup }
                }
            }
        }
        .task {
            await refresh()
            try? await Task.sleep(for: .seconds(0.5))
            selfHealAutomation()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }   // the user may just have fixed something in System Settings
        }
        .sheet(isPresented: $showCodexSetup, onDismiss: { Task { await refresh() } }) {
            CodexSetupView()
        }
    }

    // MARK: - SENTIENT (severity order)

    private var sentientGroup: some View {
        SettingsGroup(label: "Sentient") {
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
                StatusLine(title: "Overnight wake",
                           health: daemon == .ready ? .ok : .bad,
                           note: daemonNote,
                           fixTitle: daemon == .awaitingApproval ? "Approve…" : "Set Up…") {
                    fixDaemon()
                }
                StatusLine(title: "Launch at login",
                           health: loginOn ? .ok : .warn,
                           note: loginOn ? "on" : "off",
                           fixTitle: "Turn On") {
                    LoginItem.enable()
                    loginOn = LoginItem.isEnabled
                }
                StatusLine(title: "Microphone & Speech",
                           health: micSpeechHealth,
                           note: micSpeechNote,
                           fixTitle: micSpeech == .notAsked ? "Allow…" : "Fix…") {
                    fixMicSpeech()
                }
                StatusLine(title: "Notifications",
                           health: notifHealth,
                           note: notifNote,
                           fixTitle: notifStatus == .notDetermined ? "Allow…" : "Fix…") {
                    fixNotifications()
                }
            }
        }
    }

    // MARK: Overnight wake daemon

    private var daemonNote: String {
        switch daemon {
        case .ready:             return "ready"
        case .awaitingApproval:  return "awaiting approval"
        case .notSetUp:          return "not set up"
        }
    }

    /// Awaiting approval → straight to Login Items. Not set up → register (the SMAppService path);
    /// if that lands in requires-approval, open Login Items so the user can finish the click.
    private func fixDaemon() {
        switch daemon {
        case .ready:
            break
        case .awaitingApproval:
            WakeHelperClient.shared.openLoginItemsSettings()
        case .notSetUp:
            let status = WakeHelperClient.shared.register()
            if status == .requiresApproval { WakeHelperClient.shared.openLoginItemsSettings() }
            refreshDaemon()
        }
    }

    /// Green = the SMAppService daemon is approved OR the dev-installed plist exists and points at
    /// this exact binary (the manual path still counts as a working heartbeat).
    private func refreshDaemon() {
        if WakeHelperInstaller.isInstalledAndCurrent() || WakeHelperClient.shared.status == .enabled {
            daemon = .ready
        } else if WakeHelperClient.shared.status == .requiresApproval {
            daemon = .awaitingApproval
        } else {
            daemon = .notSetUp
        }
    }

    // MARK: Microphone & Speech (one row — one call asks for both)

    private var micSpeechHealth: StatusLine.Health {
        switch micSpeech {
        case .granted:  return .ok
        case .notAsked: return .warn
        case .denied:   return .bad
        }
    }

    private var micSpeechNote: String {
        switch micSpeech {
        case .granted:  return "granted"
        case .notAsked: return "not asked yet"
        case .denied:   return "denied"
        }
    }

    private func fixMicSpeech() {
        switch micSpeech {
        case .granted:
            break
        case .notAsked:
            Task { _ = await VoiceCapture.requestPermissions(); await refresh() }
        case .denied:
            // Deep-link to whichever grant is actually the blocker (mic first — it gates speech).
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                Permissions.openMicrophoneSettings()
            } else {
                Permissions.openSpeechRecognitionSettings()
            }
        }
    }

    private func refreshMicSpeech() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        if mic == .authorized && speech == .authorized {
            micSpeech = .granted
        } else if mic == .denied || mic == .restricted || speech == .denied || speech == .restricted {
            micSpeech = .denied
        } else {
            micSpeech = .notAsked
        }
    }

    // MARK: Notifications (yellow when off, never red — the morning briefing sleeps, the app works)

    private var notifHealth: StatusLine.Health {
        switch notifStatus {
        case .authorized, .provisional: return .ok
        default:                        return .warn
        }
    }

    private var notifNote: String {
        switch notifStatus {
        case .authorized, .provisional: return "on"
        case .notDetermined:            return "not asked yet"
        default:                        return "off"
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

    // MARK: - The collapsed codex summary (everything green = one quiet line, tap for details)

    private var codexSummaryLine: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { codexExpanded.toggle() }
        } label: {
            HStack(spacing: 11) {
                HealthDot(color: Theme.Ink.green)
                Text("Codex is all good.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.Ink.statusInk)
                Spacer(minLength: 12)
                MonoCaps(codexExpanded ? "Hide" : "Details", size: 8.5, tracking: 1.6,
                         color: Theme.Ink.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Ink.label)
                    .rotationEffect(.degrees(codexExpanded ? 180 : 0))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - SET UP CODEX (the cloud brain — all three are core, red when missing)

    private var codexSetupGroup: some View {
        SettingsGroup(label: "Set Up Codex") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Codex CLI",
                           health: codex.installed ? .ok : .bad,
                           note: codex.installed ? "installed" : "not installed",
                           fixTitle: "Install…") { showCodexSetup = true }
                StatusLine(title: "ChatGPT account",
                           health: codex.loggedIn ? .ok : .bad,
                           note: codex.loggedIn ? "logged in" : "not logged in",
                           fixTitle: "Log in…") { showCodexSetup = true }
                StatusLine(title: "Computer use",
                           health: codex.computerUseReady ? .ok : .bad,
                           note: codex.computerUseReady ? "ready" : "not set up",
                           fixTitle: "Set up…") { showCodexSetup = true }
            }
        }
    }

    // MARK: - CODEX PERMISSIONS (the helper's hands and eyes — system TCC, status + deep-link only)

    private var codexPermissionsGroup: some View {
        SettingsGroup(label: "Codex Permissions") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Accessibility (move the mouse, type)",
                           health: helperAccessibility ? .ok : .bad,
                           note: helperAccessibility ? "granted" : "not granted",
                           fixTitle: "Open Settings…") {
                    Permissions.openAccessibilitySettings()
                }
                StatusLine(title: "Screen Recording (see the screen)",
                           health: helperScreenRecording ? .ok : .bad,
                           note: helperScreenRecording ? "granted" : "not granted",
                           fixTitle: "Open Settings…") {
                    Permissions.openScreenRecordingSettings()
                }
                SettingsProse("These belong to Codex's Computer Use helper, not Sentient. Flip its switch in each list; macOS may also prompt on the first computer-use run.")
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - Automation: no row, just a quiet self-heal (the user has no job here)

    /// Sentient drives Codex's helper over Apple Events; that grant lives in the USER TCC db,
    /// which we can write with the FDA we already hold. Probe, and if it's missing while the
    /// prerequisites exist, silently re-grant (idempotent INSERT OR REPLACE) — no UI, just a log.
    private func selfHealAutomation() {
        guard fdaGranted, Permissions.computerUseHelperURL() != nil else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS"
        guard !Permissions.isTCCGranted(service: "kTCCServiceAppleEvents", clientBundleID: bundleID) else { return }
        Task.detached {
            do {
                let receipt = try Permissions.grantComputerUseAutomation()
                Log("HealthPane: automation self-heal — \(receipt)")
            } catch {
                Log("HealthPane: automation self-heal failed — \(error)")
            }
        }
    }

    // MARK: - Probes

    private func refresh() async {
        fdaGranted = Permissions.hasFullDiskAccess()
        loginOn = LoginItem.isEnabled
        refreshDaemon()
        refreshMicSpeech()
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        codex.refreshInstalled()
        codex.refreshComputerUse()
        if fdaGranted {
            helperAccessibility = Permissions.isTCCGranted(
                service: "kTCCServiceAccessibility",
                clientBundleID: Permissions.computerUseHelperBundleID)
            helperScreenRecording = Permissions.isTCCGranted(
                service: "kTCCServiceScreenCapture",
                clientBundleID: Permissions.computerUseHelperBundleID)
        }
        await codex.refreshLoginStatus()   // last — it shells out to `codex login status`
    }
}

#Preview("Permissions & Health pane") {
    HealthPane()
        .background(Theme.bg)
        .frame(width: 720, height: 760)
}
