//
//  HealthPane.swift
//  Sentient OS macOS
//
//  Settings → Permissions & Health. Shared setup rows prepare native computer use for every
//  backend; Claude users see both CLIs and only their Claude login. Required grants remain
//  separate from optional voice and notifications. Fixes use the existing setup engines.
//  Doc: Documentation - Settings.md
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
    @State private var claude = ClaudeSetup.shared
    private var computerGate: ComputerUseGate { .shared }
    /// The live frontier-model choice — observed so switching engines re-renders the pane's
    /// engine group in place.
    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue

    private var backend: ModelBackend { ModelBackend(rawValue: backendRaw) ?? .chatgpt }

    // Sentient's own grants
    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    @State private var daemon: DaemonState = .notSetUp
    @State private var loginOn = LoginItem.isEnabled
    @State private var micSpeech: MicSpeechState = .notAsked
    @State private var screenRec = Permissions.hasScreenRecording()   // Sentient's own grant — the driver's eyes
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    // ChatGPT plan (decoded from the user's own codex login — CodexAuth)
    @State private var plan: CodexAuth.Plan?
    @State private var planChecking = false

    @State private var codexExpanded = false
    @State private var checked = false        // first full probe done (codex login check is seconds)
    @State private var revealed = false       // drives the rise-in cascade after the first probe

    #if DEBUG
    init(expandEngine: Bool = false) { _codexExpanded = State(initialValue: expandEngine) }
    #endif

    private enum DaemonState { case ready, installing, notSetUp, disabled }
    private enum MicSpeechState { case granted, notAsked, denied }

    /// The live engine's whole stack, healthy — what the group's collapse and the pane's
    /// all-clear whisper judge. Per engine: ChatGPT = CLI + login + a non-limited plan;
    /// Claude = Claude Code + its login + Codex for computer tasks; custom = CLI + a proven endpoint (codex is the
    /// harness there too). The computer-use driver rides every engine.
    private var engineAllGreen: Bool {
        guard ComputerUseSetup.current.ready, computerGate.allRequiredGranted else { return false }
        switch backend {
        case .chatgpt: return codex.installed && !codex.outdated
                           && codex.loggedIn && plan?.tier != .limited
        case .claude:  return claude.installed && claude.loggedIn && codex.installed && !codex.outdated
        case .custom:  return codex.installed && !codex.outdated
                           && CustomProvider.current.isUsable
        }
    }

    private var allGreen: Bool {
        fdaGranted && daemon == .ready && loginOn && micSpeech == .granted
            && screenRec
            && (notifStatus == .authorized || notifStatus == .provisional)
            && engineAllGreen
    }

    var body: some View {
        SettingsPane(title: "Permissions & Health",
                     whisper: allGreen ? "All clear. Your Sentient is healthy."
                                       : "Manage access and check that everything is ready.") {
            if !checked {
                checkingLine
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    onDeviceGroup
                    sidekickGroup
                    NativeComputerUsePermissionRows(gate: computerGate)
                    Group {
                        if engineAllGreen && !codexExpanded {
                            SettingsGroup(label: engineSummaryLabel) { engineSummaryLine }
                        } else {
                            switch backend {
                            case .chatgpt, .custom: codexSetupGroup
                            case .claude:           claudeSetupGroup
                            }
                        }
                    }
                    .rise(8, revealed: revealed)
                }
                .task { revealed = true }
            }
        }
        .environment(\.settingsCompactLayout, true)
        .task { await refresh() }
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
        .task(id: claude.loggingIn) {
            // The Claude twin of the auto-notice poll.
            while !Task.isCancelled, claude.loggingIn, !claude.loggedIn {
                try? await Task.sleep(for: .seconds(2))
                await claude.refreshLoginStatus()
            }
        }
        .onChange(of: backendRaw) {
            Task { await refresh() }   // a fresh engine choice re-probes its own rows
        }
    }

    // MARK: - SENTIENT (severity order)

    /// The first probe's stand-in — the codex login check shells out and takes seconds; without
    /// this the full board flashes and re-collapses.
    private var checkingLine: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Checking your Sentient…")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Ink.body)
        }
        .padding(.top, 10)
    }

    private var onDeviceGroup: some View {
        SettingsGroup(label: "On-device intelligence") {
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    StatusLine(title: "Full Disk Access",
                               health: fdaGranted ? .ok : .bad,
                               note: fdaGranted ? "granted" : "not granted",
                               tip: PrivacyCopy.fullDiskAccess,
                               fixTitle: "Grant…") {
                        PermissionGuide.shared.guide(.fullDiskAccess, dragging: Bundle.main.bundleURL)
                    }
                    if !fdaGranted {
                        HStack(spacing: 6) {
                            SettingsProse("WhatsApp, iMessage & Notes stay unreadable without it. After granting:")
                            Button { Permissions.relaunch() } label: {
                                Text("Relaunch Sentient")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.Ink.bright)
                                    .underline(true, color: Theme.Ink.deepMuted)
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                        .padding(.bottom, 6)
                    }
                }
                .rise(0, revealed: revealed)
                SettingsHairline(opacity: 0.10)
                StatusLine(title: "Overnight wake",
                           health: daemon == .ready ? .ok : .bad,
                           note: daemonNote,
                           tip: "A tiny system helper that wakes your Mac at 3 AM so Sentient's on-device intelligence can work while you sleep.\n\nIt only runs while your Mac is plugged in and Sentient is open in your menu bar. Installed once with your password.",
                           fixTitle: daemon == .disabled ? "Turn On…" : "Set Up…") {
                    fixDaemon()
                }
                .rise(1, revealed: revealed)
                SettingsHairline(opacity: 0.10)
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
        SettingsGroup(label: "Sidekick & Double Tap") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Microphone & Speech",
                           health: micSpeech == .granted ? .ok : .warn,   // optional — Sidekick's voice; tap-to-type works without it
                           note: micSpeechNote,
                           tip: ComputerUseGate.micSpeechTip,
                           fixTitle: micSpeech == .notAsked ? "Allow…" : "Fix…") {
                    fixMicSpeech()
                }
                .rise(3, revealed: revealed)
                SettingsHairline(opacity: 0.10)
                StatusLine(title: "Screen Recording",
                           health: screenRec ? .ok : .bad,   // the driver's eyes — computer use is off without it
                           note: screenRec ? "granted" : "not granted",
                           tip: PrivacyCopy.screenCapture,
                           fixTitle: "Allow…") {
                    fixScreenRecording()
                }
                .rise(5, revealed: revealed)
                SettingsHairline(opacity: 0.10)
                StatusLine(title: "Notifications",
                           health: notifHealth,
                           note: notifNote,
                           tip: "Lets Sentient send a morning note when new suggestions are ready. Optional; everything works without it.",
                           fixTitle: notifStatus == .notDetermined ? "Allow…" : "Fix…") {
                    fixNotifications()
                }
                .rise(6, revealed: revealed)
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

    // MARK: Accessibility + Screen Recording (Sentient's own grants — the driver's hands and eyes)

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

    // MARK: - The collapsed engine summary (everything green = one quiet line; expanding REPLACES
    // it — a one-way door per visit, so the detail view never carries an extra clutter line)

    private var engineSummaryLabel: String {
        backend == .claude ? "Claude" : "Codex"
    }

    private var engineSummaryText: String {
        backend == .claude ? "Claude is all good." : "Codex is all good."
    }

    private var engineSummaryLine: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { codexExpanded = true }
        } label: {
            HStack(spacing: 11) {
                HealthDot(color: Theme.Ink.green)
                Text(engineSummaryText)
                    .font(.system(size: 14)).foregroundStyle(Theme.Ink.statusInk)
                Spacer(minLength: 12)
                Text("Details").font(.system(size: 13)).foregroundStyle(SettingsStyle.secondary)
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
        SettingsGroup(label: "Model connection") {
            VStack(alignment: .leading, spacing: 2) {
                codexCLIRow
                if backend == .custom {
                    // Codex is the harness for custom endpoints too (the vision probe and every
                    // run go through `codex exec`) — the CLI row stays, and the endpoint stands
                    // in for the account rows: no ChatGPT login exists or is needed here.
                    StatusLine(title: "Frontier model",
                               health: CustomProvider.current.isUsable ? .ok : .bad,
                               note: CustomProvider.current.isUsable
                                   ? CustomProvider.current.modelName : "not set up",
                               tip: "Sentient's cloud thinking runs through your own model endpoint instead of a ChatGPT login.\n\nPick and test it in Frontier Model Choice.",
                               fixTitle: "Configure…") {
                        MainNavigation.shared.show(.settings, settingsPane: .frontierModel)
                    }
                } else {
                    StatusLine(title: "ChatGPT account",
                               health: codex.loggedIn ? .ok : (codex.loggingIn ? .warn : .bad),
                               note: codex.loggedIn ? "logged in"
                                   : codex.loggingIn ? "finish in your browser" : "not logged in",
                               tip: "Your own OpenAI login for Codex CLI.\n\n\u{201C}Log in\u{201D} asks Codex to open your browser to sign in. Your Codex login stays in Sentient’s private folder on this Mac.",
                               fixTitle: codex.loggingIn ? "Re-open…" : "Log in…",
                               fix: codex.loggedIn ? nil : { Task { await codex.startLogin() } })
                    failureLine(codex.loginStatusLine)
                    if codex.loggedIn, let plan {
                        StatusLine(title: "ChatGPT plan",
                                   health: plan.tier == .limited ? .warn : .ok,
                                   note: planChecking ? "checking…"
                                       : plan.tier == .limited ? "\(plan.displayName.lowercased()) · knowledge base only"
                                                               : plan.displayName.lowercased(),
                                   tip: "Free and Go plans carry a tiny monthly Codex quota and no Gmail or Calendar connectors, so Sentient runs in a one-time knowledge-base-only mode.\n\nChatGPT Plus unlocks Proactive Intelligence, Sidekick, and nightly knowledge-base updates.\n\nUpgraded? Reset Sentient (in the System tab) to activate the full Sentient OS experience.\n\nPrefer no ChatGPT at all? Frontier Model Choice can point Sentient at your own model instead.",
                                   fixTitle: "Re-check") { recheckPlan() }
                    }
                }
                computerUseRow
            }
        }
    }

    // MARK: - SET UP CLAUDE (the Claude backend's twin — Claude Code CLI · account · computer use)

    private var claudeSetupGroup: some View {
        SettingsGroup(label: "Model connection") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Claude Code CLI",
                           health: claude.installing ? .warn : (claude.installed ? .ok : .bad),
                           note: claude.installing ? (claude.installed ? "updating…" : "installing…")
                               : !claude.installed ? "not installed"
                               : (claude.version.map { "installed · \($0)" } ?? "installed"),
                           tip: "Anthropic's official Claude Code command line tool. Sentient runs its cloud thinking through it, using your own Claude subscription.\n\nSentient checks for updates quietly, at most once a day while you're away from the app. Existing installations use claude update and follow your release channel. Missing installations use Anthropic's official installer.",
                           fixTitle: claude.installed ? "Update…" : "Install…",
                           fix: claude.installing ? nil : { Task { await claude.installClaude() } })
                failureLine(claude.installStatus)
                StatusLine(title: "Claude account",
                           health: claude.loggedIn ? .ok : (claude.loggingIn ? .warn : .bad),
                           note: claude.loggedIn
                               ? (claude.plan.map { "signed in · \($0.lowercased()) plan" } ?? "signed in")
                               : claude.loggingIn ? "finish in your browser" : "not signed in",
                           tip: "Sign in directly through Claude Code in your browser. Its login is kept in your Mac’s Keychain and shared with your existing Claude Code setup.",
                           fixTitle: claude.loggingIn ? "Re-open…" : "Sign in…",
                           fix: claude.loggedIn ? nil : { claude.startLogin() })
                failureLine(claude.loginStatusLine)
                codexCLIRow
                computerUseRow
            }
        }
    }

    @ViewBuilder private var codexCLIRow: some View {
        StatusLine(title: backend == .claude ? "Codex CLI for computer use" : "Codex CLI",
                   health: codex.installing ? .warn : (codex.computerUseReady && !codex.outdated ? .ok : .bad),
                   note: codex.installing ? "preparing…" : !codex.installed ? "not installed"
                       : codex.outdated || !codex.computerUseReady ? "needs an update"
                       : (codex.version.map { "installed · \($0)" } ?? "installed"),
                   tip: backend == .claude
                       ? "Runs Sidekick's computer actions using your Claude subscription. A ChatGPT account is not required."
                       : "Sentient’s verified copy of Codex, using your selected frontier model. New versions arrive with Sentient updates. Repair preserves your login and saved tasks.",
                   fixTitle: codex.installed ? "Repair…" : "Install…",
                   fix: codex.installing ? nil : { Task { await codex.installCodex() } })
        failureLine(codex.installStatus)
    }

    /// The same signed native helper serves every model backend.
    @ViewBuilder private var computerUseRow: some View {
        StatusLine(title: "Computer use",
                   health: ComputerUseSetup.current.ready ? .ok : (ComputerUseSetup.current.isInstalling ? .warn : .bad),
                   note: ComputerUseSetup.current.isInstalling ? "setting up…"
                       : (ComputerUseSetup.current.ready ? "ready" : "not set up"),
                   tip: "Downloads and verifies OpenAI's signed computer-use helper. Your selected model powers its actions.",
                   fixTitle: "Set up…",
                   fix: ComputerUseSetup.current.isInstalling ? nil : { Task { await ComputerUseSetup.current.install() } })
        // The download deserves live narration, not just an amber dot.
        if ComputerUseSetup.current.isInstalling, let line = ComputerUseSetup.current.status {
            SettingsProse(line).padding(.top, 2).padding(.bottom, 6)
        } else {
            failureLine(ComputerUseSetup.current.status)
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
        computerGate.refresh()
        fdaGranted = Permissions.hasFullDiskAccess()
        loginOn = LoginItem.isEnabled
        await refreshDaemon()
        refreshMicSpeech()
        // The preflight is this process's view (stale until relaunch after a grant), so the
        // FDA-backed TCC read rides along as the live truth — same manners as the gate.
        screenRec = Permissions.hasScreenRecording()
            || (fdaGranted && Permissions.isTCCGranted(
                    service: "kTCCServiceScreenCapture",
                    clientBundleID: Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS"))
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        ComputerUseSetup.current.refresh()
        // Only the LIVE engine's rows are probed (the login checks shell out, seconds each).
        // Custom backends keep the codex CLI probe (codex is their harness) but skip the login
        // check — no ChatGPT account is needed there.
        switch backend {
        case .chatgpt:
            await codex.refreshInstalled()
            plan = CodexAuth.currentPlan()   // pure file read (the JWT claim on disk)
            await codex.refreshLoginStatus()   // last — it shells out to `codex login status`
        case .claude:
            await codex.refreshInstalled()
            await claude.refreshInstalled()
            await claude.refreshLoginStatus()  // shells out to `claude auth status`
        case .custom:
            await codex.refreshInstalled()
        }
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

#if DEBUG
#Preview("Permissions & Health pane") {
    HealthPane(expandEngine: true)
        .background(Theme.bg)
        .frame(width: 720, height: 760)
}
#endif
