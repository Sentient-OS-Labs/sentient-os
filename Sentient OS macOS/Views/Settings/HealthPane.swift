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
//  Red = a core capability is broken · yellow = optional, fixable-later, or working on it. The
//  codex fix buttons drive the shared engine INLINE (install / browser login with auto-notice /
//  computer-use bootstrap — no sheet; CodexSetupView is dev-tools-only now). When the whole codex
//  stack is green it collapses to one glowing summary line (tap for details) — a browsing user
//  shouldn't wade through five rows of "fine". Statuses re-probe on app foreground.
//  (Reset lives in Settings → System.)
//

import SwiftUI
import AppKit
import AVFoundation
import Speech
import UserNotifications

struct HealthPane: View {
    /// Optional on purpose: the pane's #Preview renders without an AppState in the environment.
    @Environment(AppState.self) private var appState: AppState?
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

    @State private var codexExpanded = false
    @State private var checked = false        // first full probe done (codex login check is seconds)
    @State private var revealed = false       // drives the rise-in cascade after the first probe

    private enum DaemonState { case ready, installing, notSetUp, disabled }
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
                    SettingsHairline(opacity: 0.12)
                        .padding(.vertical, -7)   // the brighter, tighter group splitter (matches ProactivePane's)
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
        .task(id: codex.loggingIn) {
            // The browser-login auto-notice, same as onboarding: while a login is out, poll
            // `codex login status` every 2s so the row flips green the moment they finish —
            // no "I'm done" button. The task re-keys (and cancels) with the loggingIn flag.
            while !Task.isCancelled, codex.loggingIn, !codex.loggedIn {
                try? await Task.sleep(for: .seconds(2))
                await codex.refreshLoginStatus()
            }
            if codex.loggedIn { plan = CodexAuth.currentPlan() }   // the plan row rides the login
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
                               tip: "Lets Sentient's on-device LLM read your files & folders, and the databases WhatsApp, iMessage, and Notes keep on this Mac.\n\nEverything is read right here on your Mac; your data never leaves it.",
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
                           tip: "A tiny system helper that wakes your Mac at 3 AM so Sentient's on-device intelligence can work while you sleep.\n\nIt only runs while your Mac is plugged in and Sentient is open in your menu bar. Installed once with your password.",
                           fixTitle: daemon == .disabled ? "Turn On…" : "Set Up…") {
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
                           health: micSpeech == .granted ? .ok : .warn,   // optional — Sidekick's voice; tap-to-type works without it
                           note: micSpeechNote,
                           tip: "Optional but recommended.\nLets Sidekick hear you and turn your words into text when you hold the shortcut key.\n\nWithout it, hold-to-talk stays off — you can still tap the key (or click the notch) and type.\n\nYour voice is heard and transcribed on this Mac, never in the cloud.",
                           fixTitle: micSpeech == .notAsked ? "Allow…" : "Fix…") {
                    fixMicSpeech()
                }
                .rise(3, revealed: revealed)
                StatusLine(title: "Screen Recording",
                           health: screenRec ? .ok : .warn,   // optional — Sidekick runs text-only without it
                           note: screenRec ? "granted" : "optional",
                           tip: "Optional but recommended.\nLets Sidekick see a screenshot of your screen the moment you summon it, so it can see the thing you're asking about (\u{201C}finish this\u{201D}, \u{201C}reply to this\u{201D}).\n\nWithout it, you'll have to explicitly tell Sidekick which app you want it to start controlling.",
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
        case .disabled:   return "turned off in login items"
        }
    }

    /// [DECIDED 2026-07-04] The password install IS the production path (no Login Items
    /// migration — one native admin prompt, no trip to System Settings). Fix = run the installer —
    /// EXCEPT when the daemon is installed but toggled off in System Settings: launchd honors that
    /// switch over any bootstrap, so the only fix is the user flipping it back on.
    private func fixDaemon() {
        switch daemon {
        case .ready, .installing:
            return
        case .disabled:
            WakeHelperClient.shared.openLoginItemsSettings()
        case .notSetUp:
            daemon = .installing
            Task {
                _ = await WakeHelperInstaller.installAsync()
                try? await Task.sleep(for: .seconds(1))   // let launchd settle before the XPC probe
                await refreshDaemon()
                // A fresh install may be the last missing prerequisite — re-run the 14h check now
                // instead of waiting for the next launch (this app rarely relaunches).
                if daemon == .ready { appState?.scheduler.maybeAutoEnable() }
            }
        }
    }

    /// Green = the daemon ANSWERS over XPC (the only check the System Settings background toggle
    /// can't fool) — WakeHelperClient.healthProbe is the shared verdict.
    private func refreshDaemon() async {
        switch await WakeHelperClient.shared.healthProbe() {
        case .ready:    daemon = .ready
        case .disabled: daemon = .disabled
        case .notSetUp: daemon = .notSetUp
        }
    }

    // MARK: Microphone & Speech (one row — one call asks for both; optional, so yellow, never red)

    private var micSpeechNote: String {
        switch micSpeech {
        case .granted:  return "granted"
        case .notAsked: return "not asked yet"
        case .denied:   return "off"
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
    //
    // The fix buttons drive the shared CodexSetup engine DIRECTLY — no intermediate sheet (the
    // old wiring bounced every button through CodexSetupView, which is the dev cockpit; decided
    // gone 2026-07-11). While a step runs, its LED goes amber, the note narrates, and the pill
    // hides; failures surface as a quiet prose line under the row. The browser login is
    // noticed automatically (the same 2s poll onboarding uses) — no "I'm done" button.

    private var codexSetupGroup: some View {
        SettingsGroup(label: "Set Up Codex") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Codex CLI",
                           health: codex.installed ? .ok : (codex.installing ? .warn : .bad),
                           note: codex.installing ? "installing…" : (codex.installed ? "installed" : "not installed"),
                           tip: "OpenAI's official Codex command line tool. Sentient runs its cloud thinking through it, using your own ChatGPT subscription.\n\nInstall runs OpenAI's own installer; if codex is already there it simply updates in place, and your login and settings are untouched.",
                           fixTitle: "Install…",
                           fix: codex.installing ? nil : { Task { await codex.installCodex() } })
                failureLine(codex.installStatus)
                StatusLine(title: "ChatGPT account",
                           health: codex.loggedIn ? .ok : (codex.loggingIn ? .warn : .bad),
                           note: codex.loggedIn ? "logged in"
                               : codex.loggingIn ? "finish in your browser" : "not logged in",
                           tip: "Your own OpenAI login for Codex CLI.\n\n\u{201C}Log in\u{201D} asks Codex to open your browser to sign in. Sentient never sees your credentials.",
                           fixTitle: codex.loggingIn ? "Re-open…" : "Log in…",
                           fix: codex.loggedIn ? nil : { codex.startLogin() })
                failureLine(codex.loginStatusLine)
                if codex.loggedIn, let plan {
                    StatusLine(title: "ChatGPT plan",
                               health: plan.tier == .limited ? .warn : .ok,
                               note: planChecking ? "checking…"
                                   : plan.tier == .limited ? "\(plan.displayName.lowercased()) · knowledge base only"
                                                           : plan.displayName.lowercased(),
                               tip: "Free and Go plans carry a tiny monthly Codex quota and no Gmail or Calendar connectors, so Sentient runs in a one-time knowledge-base-only mode.\n\nChatGPT Plus unlocks Proactive Intelligence, Sidekick, and nightly knowledge-base updates.\n\nUpgraded? Reset Sentient (in the System tab) to activate the full Sentient OS experience.",
                               fixTitle: "Re-check") { recheckPlan() }
                }
                StatusLine(title: "Computer use",
                           health: codex.computerUseReady ? .ok : (codex.settingUpComputerUse ? .warn : .bad),
                           note: codex.settingUpComputerUse ? "setting up…"
                               : (codex.computerUseReady ? "ready" : "not set up"),
                           tip: "The Codex add-on that can click, type, and act on your Mac when you fire an action.\n\nSet up downloads OpenAI's official Codex Desktop app package straight from OpenAI (about 535 MB), lifts out its computer-use plugin, and wires it into Codex CLI on this Mac. No desktop app installs; nothing is hosted by us.",
                           fixTitle: "Set up…",
                           fix: codex.settingUpComputerUse ? nil : { Task { await codex.setupComputerUse() } })
                // The ~535 MB download deserves live narration, not just an amber dot.
                if codex.settingUpComputerUse, let line = codex.computerUseStatus {
                    SettingsProse(line).padding(.top, 2).padding(.bottom, 6)
                } else {
                    failureLine(codex.computerUseStatus)
                }
            }
        }
    }

    /// A quiet prose line under a row, shown only when the engine's last word was a failure —
    /// success is already the row's green dot, and progress has its own treatment.
    @ViewBuilder
    private func failureLine(_ status: String?) -> some View {
        if let status, status.hasPrefix("✗") {
            SettingsProse(status).padding(.top, 2).padding(.bottom, 6)
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
        await refreshDaemon()
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
