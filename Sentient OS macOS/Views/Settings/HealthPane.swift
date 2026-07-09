//
//  HealthPane.swift
//  Sentient OS macOS
//
//  Settings → Permissions & Health: the health board. Live LED rows for every grant Sentient
//  actually asks for, in severity order — SENTIENT (Full Disk Access · the overnight wake daemon ·
//  launch-at-login · mic & speech · notifications), SET UP CODEX (CLI · account · ChatGPT plan
//  via CodexAuth · computer use, via the shared CodexSetup engine), and CODEX PERMISSIONS (the
//  helper's Accessibility + Screen
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

struct HealthPane: View {
    @State private var codex = CodexSetup.shared

    // Sentient's own grants
    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    @State private var daemon: DaemonState = .notSetUp
    @State private var loginOn = LoginItem.isEnabled
    @State private var micSpeech: MicSpeechState = .notAsked
    @State private var screenRec = Permissions.hasScreenRecording()   // Sentient's own grant — Sidekick's screen context
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    // The Codex helper's system-TCC grants (read via FDA; shown once computer use exists)
    @State private var helperAccessibility = false
    @State private var helperScreenRecording = false

    // ChatGPT plan (decoded from the user's own codex login — CodexAuth)
    @State private var plan: CodexAuth.Plan?
    @State private var planChecking = false

    @State private var showCodexSetup = false
    @State private var codexExpanded = false
    @State private var checked = false        // first full probe done (codex login check is seconds)
    @State private var revealed = false       // drives the rise-in cascade after the first probe

    private enum DaemonState { case ready, installing, notSetUp }
    private enum MicSpeechState { case granted, notAsked, denied }

    private var showCodexPermissions: Bool { fdaGranted && codex.computerUseReady }

    /// The whole codex stack, healthy — the CLI, the account, computer use, AND its two helper
    /// grants (verifiable only with FDA; unverifiable never claims "all good"). A free/go plan
    /// keeps the group expanded so its amber row stays visible.
    private var codexAllGreen: Bool {
        codex.installed && codex.loggedIn && codex.computerUseReady
            && fdaGranted && helperAccessibility && helperScreenRecording
            && plan?.tier != .limited
    }

    private var allGreen: Bool {
        fdaGranted && daemon == .ready && loginOn && micSpeech == .granted && screenRec
            && (notifStatus == .authorized || notifStatus == .provisional)
            && codex.installed && codex.loggedIn && codex.computerUseReady
            && (!showCodexPermissions || (helperAccessibility && helperScreenRecording))
    }

    var body: some View {
        SettingsPane(title: "Permissions & Health",
                     whisper: allGreen ? "All clear. Your Sentient is healthy."
                                       : "Everything green means everything works.") {
            if !checked {
                checkingLine
            } else {
                VStack(alignment: .leading, spacing: 30) {
                    onDeviceGroup
                    sidekickGroup
                    SettingsHairline()
                        .rise(6, revealed: revealed)
                    Group {
                        if codexAllGreen && !codexExpanded {
                            SettingsGroup(label: "Codex") { codexSummaryLine }
                        } else {
                            VStack(alignment: .leading, spacing: 30) {
                                codexSetupGroup
                                if showCodexPermissions { codexPermissionsGroup }
                            }
                        }
                    }
                    .rise(7, revealed: revealed)
                }
                .task { revealed = true }
            }
        }
        .task {
            await refresh()
            try? await Task.sleep(for: .seconds(0.5))
            Permissions.selfHealComputerUseAutomation(context: "HealthPane")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }   // the user may just have fixed something in System Settings
        }
        .sheet(isPresented: $showCodexSetup, onDismiss: { Task { await refresh() } }) {
            CodexSetupView()
        }
    }

    // MARK: - SENTIENT (severity order)

    /// The first probe's stand-in — the codex login check shells out and takes seconds; without
    /// this the full board flashes and re-collapses.
    private var checkingLine: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Checking your Sentient…")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Ink.body)
        }
        .padding(.top, 10)
    }

    private var onDeviceGroup: some View {
        SettingsGroup(label: "On-device Intelligence") {
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    StatusLine(title: "Full Disk Access",
                               health: fdaGranted ? .ok : .bad,
                               note: fdaGranted ? "granted" : "not granted",
                               tip: "Lets Sentient's on-device LLM read your files & folders, and the databases WhatsApp, iMessage, and Notes keep on this Mac. Everything is read right here on your Mac; your data never leaves it.",
                               fixTitle: "Grant…") {
                        PermissionGuide.shared.guide(.fullDiskAccess, dragging: Bundle.main.bundleURL)
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
                }
                .rise(0, revealed: revealed)
                StatusLine(title: "Overnight wake",
                           health: daemon == .ready ? .ok : .bad,
                           note: daemonNote,
                           tip: "A tiny system helper that wakes your Mac at 3 AM so Sentient's on-device intelligence can work while you sleep. It only runs while your Mac is plugged in and Sentient is open in your menu bar. Installed once with your password.",
                           fixTitle: "Set Up…") {
                    fixDaemon()
                }
                .rise(1, revealed: revealed)
                StatusLine(title: "Launch at login",
                           health: loginOn ? .ok : .warn,
                           note: loginOn ? "on" : (LoginItem.needsApproval ? "approve in system settings" : "off"),
                           tip: "Starts Sentient quietly in your menu bar when you log in, so the overnight run can happen and your Sentient can stay alive.",
                           fixTitle: LoginItem.needsApproval ? "Approve…" : "Turn On") {
                    LoginItem.enableOrRequestApproval()
                    loginOn = LoginItem.isEnabled
                    if LoginItem.needsApproval {
                        PermissionGuide.shared.guide(.loginItems, dragging: nil)
                    }
                }
                .rise(2, revealed: revealed)
            }
        }
    }

    private var sidekickGroup: some View {
        SettingsGroup(label: "Sidekick & Proactive") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Microphone & Speech",
                           health: micSpeechHealth,
                           note: micSpeechNote,
                           tip: "Lets Sidekick hear you and turn your words into text when you hold the shortcut key. Your voice is heard and transcribed on this Mac, never in the cloud.",
                           fixTitle: micSpeech == .notAsked ? "Allow…" : "Fix…") {
                    fixMicSpeech()
                }
                .rise(3, revealed: revealed)
                StatusLine(title: "Screen Recording",
                           health: screenRec ? .ok : .warn,   // optional — Sidekick runs text-only without it
                           note: screenRec ? "granted" : "optional",
                           tip: "Optional. Lets Sidekick snap a still of your screen the moment you summon it, so it can see the thing you're asking about (\u{201C}finish this\u{201D}, \u{201C}reply to this\u{201D}). Without it, Sidekick may not know which open app to start controlling to help you. Takes effect after you restart Sentient.",
                           fixTitle: "Allow…") {
                    fixScreenRecording()
                }
                .rise(4, revealed: revealed)
                StatusLine(title: "Notifications",
                           health: notifHealth,
                           note: notifNote,
                           tip: "Lets Sentient send a morning note when new suggestions are ready. Optional; everything works without it.",
                           fixTitle: notifStatus == .notDetermined ? "Allow…" : "Fix…") {
                    fixNotifications()
                }
                .rise(5, revealed: revealed)
            }
        }
    }

    // MARK: Overnight wake daemon

    private var daemonNote: String {
        switch daemon {
        case .ready:      return "ready"
        case .installing: return "installing…"
        case .notSetUp:   return "not set up"
        }
    }

    /// [DECIDED 2026-07-04] The password install IS the production path (no Login Items
    /// migration — one native admin prompt, no trip to System Settings). Fix = run the installer.
    private func fixDaemon() {
        guard daemon == .notSetUp else { return }
        daemon = .installing
        Task {
            _ = await WakeHelperInstaller.installAsync()
            refreshDaemon()
        }
    }

    /// Green = the installed daemon plist exists AND points at this exact binary.
    private func refreshDaemon() {
        daemon = WakeHelperInstaller.isInstalledAndCurrent() ? .ready : .notSetUp
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

    // MARK: Screen Recording (Sentient's own grant — Sidekick's screen context)

    /// The Screen Recording list is drag-authorizable, and Sentient may not be IN the list at all
    /// (on Tahoe, CGRequestScreenCaptureAccess doesn't reliably add it — field-verified), so the
    /// guide always carries Sentient itself as the drag card. Harmless when the row already
    /// exists; the user just flips the existing switch.
    private func fixScreenRecording() {
        guard !screenRec else { return }
        PermissionGuide.shared.guide(.screenRecording, dragging: Bundle.main.bundleURL)
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
        case .authorized:    return "on"
        case .provisional:   return "quiet"   // the launch-banked provisional grant (no banners/sounds)
        case .notDetermined: return "not asked yet"
        default:             return "off"
        }
    }

    private func fixNotifications() {
        if notifStatus == .notDetermined {
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                await refresh()
            }
        } else {
            // Modern Settings pane first (Ventura+), legacy anchor as fallback — same pattern as
            // Permissions.openFullDiskAccessSettings.
            let modern = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            let legacy = "x-apple.systempreferences:com.apple.preference.notifications"
            if let url = URL(string: modern), NSWorkspace.shared.open(url) { return }
            if let url = URL(string: legacy) { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: - The collapsed codex summary (everything green = one quiet line; expanding REPLACES
    // it — a one-way door per visit, so the detail view never carries an extra clutter line)

    private var codexSummaryLine: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { codexExpanded = true }
        } label: {
            HStack(spacing: 11) {
                HealthDot(color: Theme.Ink.green)
                Text("Codex is all good.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.Ink.statusInk)
                Spacer(minLength: 12)
                MonoCaps("Details", size: 8.5, tracking: 1.6, color: Theme.Ink.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Ink.label)
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
                           tip: "OpenAI's official Codex command line tool. Sentient runs its cloud steps through it, using your own ChatGPT subscription.",
                           fixTitle: "Install…") { showCodexSetup = true }
                StatusLine(title: "ChatGPT account",
                           health: codex.loggedIn ? .ok : .bad,
                           note: codex.loggedIn ? "logged in" : "not logged in",
                           tip: "Your own OpenAI login for Codex. The sign in happens in your browser; Sentient never sees your password.",
                           fixTitle: "Log in…") { showCodexSetup = true }
                if codex.loggedIn, let plan {
                    StatusLine(title: "ChatGPT plan",
                               health: plan.tier == .limited ? .warn : .ok,
                               note: planChecking ? "checking…"
                                   : plan.tier == .limited ? "\(plan.displayName.lowercased()) · knowledge base only"
                                                           : plan.displayName.lowercased(),
                               tip: "Read from your own codex login. Free and Go plans carry a tiny monthly Codex quota and no Gmail or Calendar connectors, so Sentient runs in knowledge-base-only mode; Plus unlocks proactive mornings, Sidekick, and nightly updates. Upgraded? Re-check picks it up right away.",
                               fixTitle: "Re-check") { recheckPlan() }
                }
                StatusLine(title: "Computer use",
                           health: codex.computerUseReady ? .ok : .bad,
                           note: codex.computerUseReady ? "ready" : "not set up",
                           tip: "The Codex add-on that can click, type, and act on your Mac when you fire an action. Downloaded once from OpenAI.",
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
                           tip: "Lets Codex's helper app move the mouse and type for you. Granted to OpenAI's helper, not to Sentient.",
                           fixTitle: "Grant…") {
                    guideHelper(.accessibility)
                }
                StatusLine(title: "Screen Recording (see the screen)",
                           health: helperScreenRecording ? .ok : .bad,
                           note: helperScreenRecording ? "granted" : "not granted",
                           tip: "Lets Codex's helper app see the screen so it acts on the right thing. Granted to OpenAI's helper, not to Sentient.",
                           fixTitle: "Grant…") {
                    guideHelper(.screenRecording)
                }
                SettingsProse("These belong to Codex's Computer Use helper, not Sentient. Flip its switch in each list; macOS may also prompt on the first computer-use run.")
                    .padding(.top, 6)
            }
        }
    }

    /// The helper's system-TCC grants: the floating drag panel with the helper app as the card
    /// (drag it into the list). Helper somehow missing → the plain deep-link is the fallback.
    private func guideHelper(_ pane: PermissionGuide.Pane) {
        if let helper = Permissions.computerUseHelperURL() {
            PermissionGuide.shared.guide(pane, dragging: helper)
        } else if pane == .accessibility {
            Permissions.openAccessibilitySettings()
        } else {
            Permissions.openScreenRecordingSettings()
        }
    }

    /// The "Re-check" pill on a free/go row — re-mints the token (CodexAuth.refreshPlan) so an
    /// upgrade shows up immediately instead of on codex's 8-day timer. Failure just keeps the
    /// current claim; the row never blocks anything.
    private func recheckPlan() {
        guard !planChecking else { return }
        planChecking = true
        Task {
            if let fresh = try? await CodexAuth.refreshPlan() { plan = fresh }
            planChecking = false
        }
    }

    // MARK: - Probes

    private func refresh() async {
        fdaGranted = Permissions.hasFullDiskAccess()
        loginOn = LoginItem.isEnabled
        refreshDaemon()
        refreshMicSpeech()
        screenRec = Permissions.hasScreenRecording()
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        codex.refreshInstalled()
        codex.refreshComputerUse()
        plan = CodexAuth.currentPlan()   // pure file read (the JWT claim on disk)
        if fdaGranted {
            helperAccessibility = Permissions.isTCCGranted(
                service: "kTCCServiceAccessibility",
                clientBundleID: Permissions.computerUseHelperBundleID)
            helperScreenRecording = Permissions.isTCCGranted(
                service: "kTCCServiceScreenCapture",
                clientBundleID: Permissions.computerUseHelperBundleID)
        }
        await codex.refreshLoginStatus()   // last — it shells out to `codex login status`
        withAnimation(.easeOut(duration: 0.2)) { checked = true }   // first probe done → reveal
    }
}

/// The gentle rise-in: each element starts a touch lower and transparent, then swoops up into
/// place with a small stagger — subtle, physics-flavored, over in under half a second.
private extension View {
    func rise(_ index: Int, revealed: Bool) -> some View {
        self.opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 14)
            .animation(.spring(response: 0.45, dampingFraction: 0.85)
                .delay(Double(index) * 0.055), value: revealed)
    }
}

#Preview("Permissions & Health pane") {
    HealthPane()
        .background(Theme.bg)
        .frame(width: 720, height: 760)
}
