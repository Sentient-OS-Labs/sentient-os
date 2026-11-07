//
//  HealthPane.swift
//  Sentient OS macOS
//
//  Settings → Permissions & Help. Shared setup rows prepare native computer use for every
//  backend; Claude users see both CLIs and only their Claude login. Required grants remain
//  separate from optional voice and notifications. Fixes use the existing setup engines.
//  Doc: Documentation - Settings.md
//

import SwiftUI
import AppKit
import AVFoundation
import UserNotifications

struct HealthPane: View {
    /// Optional on purpose: the pane's #Preview renders without an AppState in the environment.
    @Environment(AppState.self) private var appState: AppState?
    @State private var codex = CodexSetup.shared
    @State private var claude = ClaudeSetup.shared
    @State private var sentient = SentientSetup.shared
    private var computerGate: ComputerUseGate { .shared }
    /// The live frontier-model choice — observed so switching engines re-renders the pane's
    /// engine group in place.
    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue

    private var backend: ModelBackend { ModelBackend(rawValue: backendRaw) ?? .chatgpt }

    @State private var exportingDiagnostics = false
    @State private var diagnosticFile: URL?
    @State private var diagnosticError: String?

    // Sentient's own grants
    @State private var selectedProtectedSources: [ProtectedLocalSource] = []
    @State private var unreadableProtectedSources: [ProtectedLocalSource] = []
    @State private var wakeSetup = OvernightWakeSetup()
    @State private var loginOn = LoginItem.isEnabled
    @State private var confirmLoginOff = false
    @State private var micSpeech: MicSpeechState = .notAsked
    @State private var screenRec = Permissions.hasScreenRecording()   // Sentient's own grant — the driver's eyes

    @State private var grantedExpanded = false
    @State private var optionalExpanded = false
    @State private var troubleshootingExpanded = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var checked = false        // first full probe done (codex login check is seconds)

    #if DEBUG
    init(expandEngine: Bool = false) { _troubleshootingExpanded = State(initialValue: expandEngine) }
    #endif

    private enum MicSpeechState { case granted, notAsked, denied }

    /// Connection health drives troubleshooting; unverified permission evidence is kept separate.
    /// Provider usage limits are enforced when a task runs, not inferred from the account plan.
    private var modelConnectionReady: Bool {
        switch backend {
        case .sentient: return sentient.configured && sentient.ready
        case .chatgpt: return codex.installed && !codex.outdated
                           && codex.loggedIn
        case .claude:  return claude.installed && claude.loggedIn && codex.installed && !codex.outdated
        case .custom:  return codex.installed && !codex.outdated
                           && CustomProvider.current.isUsable
        }
    }

    private var helperProblem: Bool {
        if computerGate.backend == .cua { return !computerGate.sentientAccessibility }
        return computerGate.automation == .denied
            || computerGate.helperPermissionState.accessibility == .denied
            || computerGate.helperPermissionState.screenRecording == .denied
            || computerGate.nativePermissionError != nil
            || NativePermissionSetup.shared.recoveryNeeded
    }

    private var helperVerified: Bool {
        if computerGate.backend == .cua { return computerGate.sentientAccessibility }
        return computerGate.helperPermissionState.isReady && computerGate.automation == .granted && !helperProblem
    }

    private var permissionOverview: PermissionsOverview {
        PermissionsOverview(hasProtectedSources: !selectedProtectedSources.isEmpty,
            protectedSourcesReadable: unreadableProtectedSources.isEmpty, screenGranted: screenRec,
            helperInstalled: ComputerUseSetup.current.ready, helperVerified: helperVerified, helperProblem: helperProblem,
            overnightRequested: requiresOvernightSetup, wakeReady: wakeSetup.ready,
            voiceGranted: micSpeech == .granted,
            notificationsGranted: notificationStatus == .authorized || notificationStatus == .provisional)
    }

    private var troubleshootingHasProblem: Bool {
        checked && PermissionsOverview.shouldOpenTroubleshooting(
            connectionProblem: !modelConnectionReady, sourceProblem: !sourceIssues.isEmpty,
            helperProblem: helperProblem, runtimeMissing: !ComputerUseSetup.current.ready || !codex.computerUseReady)
    }

    private var requiresOvernightSetup: Bool { HealthCaution.overnightRequested() }

    private var protectedAccessNote: String {
        if selectedProtectedSources.isEmpty { return "not needed for your selected sources" }
        return unreadableProtectedSources.isEmpty ? "selected sources are readable" : "selected sources need access"
    }

    var body: some View {
        SettingsPane(title: "Permissions & Help",
                     whisper: "Manage access, startup, and troubleshooting for this Mac.") {
            VStack(alignment: .leading, spacing: 16) {
                startupGroup
                permissionsSection
                troubleshootingSection
            }
        }
        .environment(\.settingsCompactLayout, true)
        .task {
            await refresh()
            await computerGate.checkNativePermissionsIfNeeded()
        }
        .onChange(of: troubleshootingHasProblem, initial: true) { _, problem in
            if problem { troubleshootingExpanded = true }
        }
        .onChange(of: wakeSetup.ready) { _, ready in
            if ready && requiresOvernightSetup {
                appState?.scheduler.reevaluate()
            }
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

    // MARK: - Startup

    private var startupGroup: some View {
        settingsCard {
            HStack(spacing: 16) {
                sectionHeading("Launch at login", icon: "power",
                    subtitle: LoginItem.needsApproval
                        ? "Approve Sentient in System Settings → Login Items."
                        : "Keep Sentient ready in your menu bar.")
                Toggle("Launch at login", isOn: $loginOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.Ink.green)
            }
        }
        .onChange(of: loginOn) { _, on in
            if on {
                guard !LoginItem.isEnabled else { return }
                Task {
                    await LoginItem.enableOrRequestApproval()
                    loginOn = LoginItem.isEnabled
                    if LoginItem.needsApproval {
                        PermissionGuide.shared.guide(.loginItems, dragging: nil)
                    }
                }
            } else if LoginItem.isEnabled {
                loginOn = true          // hold the switch until the user confirms
                confirmLoginOff = true
            }
        }
        .alert("Turn off launch at login?", isPresented: $confirmLoginOff) {
            Button("Keep It On", role: .cancel) {}
            Button("Turn Off Anyway", role: .destructive) {
                Task {
                    await LoginItem.disable()
                    loginOn = LoginItem.isEnabled
                }
            }
        } message: {
            Text("To stay helpful, your Sentient runs its on-device intelligence at your chosen overnight wake time, and that can only happen if Sentient is already running. It's heavily optimized and stays out of your RAM and CPU the rest of the time.\n\nWe recommend leaving this on to keep your Sentient alive.")
        }
    }

    private var permissionsSection: some View {
        settingsCard {
            sectionHeading("Permissions", icon: "checkmark.shield")
            if !checked {
                checkingLine
            } else {
                if !permissionOverview.visible.isEmpty {
                    permissionRows(permissionOverview.visible)
                }
                if !permissionOverview.granted.isEmpty {
                    SettingsHairline(opacity: 0.07)
                    DisclosureGroup(isExpanded: $grantedExpanded) {
                        permissionRows(permissionOverview.granted)
                    } label: {
                        disclosureLabel("Granted permissions", count: permissionOverview.granted.count)
                    }
                }
                if !permissionOverview.optional.isEmpty {
                    DisclosureGroup(isExpanded: $optionalExpanded) {
                        permissionRows(permissionOverview.optional)
                    } label: {
                        disclosureLabel("Optional permissions", count: permissionOverview.optional.count)
                    }
                }
            }
        }
        .disclosureGroupStyle(PermissionDisclosureStyle())
    }

    private func permissionRows(_ items: [PermissionsOverview.Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                switch item {
                case .fullDisk: fullDiskRow
                case .screenRecording: screenRecordingRow
                case .computerUse: helperPermissionsRow
                case .overnightWake: OvernightWakeRow(setup: wakeSetup)
                case .voice: voiceRow
                case .notifications:
                    NotificationPermissionSetting(status: notificationStatus) { notificationStatus = $0 }
                }
            }
        }
    }

    private var troubleshootingSection: some View {
        settingsCard {
            DisclosureGroup(isExpanded: $troubleshootingExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsHairline(opacity: 0.07)
                    if !checked {
                        checkingLine
                    } else {
                        if !sourceIssues.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                subsectionTitle("Sources to retry")
                                ForEach(sourceIssues, id: \.self) { SettingsProse($0) }
                            }
                        }
                        switch backend {
                        case .sentient: sentientSetupGroup
                        case .chatgpt, .custom: codexSetupGroup
                        case .claude: claudeSetupGroup
                        }
                        SettingsHairline(opacity: 0.07)
                        ComputerUseCheckRow()
                    }
                    SettingsHairline(opacity: 0.07)
                    helpSection
                }
            } label: {
                HStack(spacing: 12) {
                    sectionHeading("Troubleshooting & Help", icon: "wrench.and.screwdriver",
                        subtitle: "Check connections, troubleshoot, or contact support.")
                    if troubleshootingHasProblem {
                        Text("Needs attention")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Ink.amber)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.Ink.amber.opacity(0.08), in: Capsule())
                    }
                }
            }
        }
        .disclosureGroupStyle(PermissionDisclosureStyle())
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            subsectionTitle("Support")
            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "https://github.com/Sentient-OS-Labs/sentient-os/issues") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image("GitHubMark")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                        Text("Report an issue")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SettingsActionStyle())
                Button(action: exportDiagnostics) {
                    Label(exportingDiagnostics ? "Preparing…" : "Export support file", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SettingsActionStyle())
                .disabled(exportingDiagnostics || appState == nil)
                .accessibilityLabel("Export diagnostic file")
            }
            Text("Includes recent prompts and replies. Review before sharing. Nothing is sent automatically.")
                .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
            SettingsDetails(title: "What’s in the support file?") {
                SettingsProse(DiagnosticExport.disclosure)
                SettingsProse(DiagnosticExport.sharingNote)
            }
            .disclosureGroupStyle(PermissionDisclosureStyle())
            if let diagnosticError {
                Text(diagnosticError).font(.system(size: 13)).foregroundStyle(Theme.Ink.amber)
            }
            if let diagnosticFile {
                HStack {
                    Text("Saved. Review before sharing.").font(.system(size: 12))
                        .foregroundStyle(SettingsStyle.secondary)
                    Spacer()
                    SettingsPillButton(title: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([diagnosticFile])
                    }
                }
            }
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func sectionHeading(_ title: String, icon: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Theme.Ink.bright)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Ink.statusInk)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func disclosureLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Ink.bright)
            Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.Ink.body)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.white.opacity(0.05), in: Capsule())
        }
    }

    private func subsectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.Ink.body)
    }

    private func exportDiagnostics() {
        guard let appState, !exportingDiagnostics else { return }
        exportingDiagnostics = true
        diagnosticError = nil
        diagnosticFile = nil
        Task {
            defer { exportingDiagnostics = false }
            do { diagnosticFile = try await DiagnosticExport.save(appState: appState) }
            catch {
                diagnosticError = DiskSpace.isDiskFull(error)
                    ? "Your disk is full. Free up space and try exporting again."
                    : "The diagnostics file couldn't be saved. Try another location."
                Log("Diagnostics export: save failed (\(ErrorLabel(error)))")
            }
        }
    }

    // MARK: - SENTIENT (severity order)

    @AppStorage(AppleCalendarSource.issueKey) private var calendarIssue = ""
    @AppStorage(AppleMailHealth.key) private var mailHealth = ""
    @AppStorage(AppleMailHealth.needsRetryKey) private var mailNeedsRetry = false
    @AppStorage(SourceHealth.readStatusKey) private var readStatusData = Data()

    private var sourceIssues: [String] {
        var issues: [String] = []
        if AppleCalendarSource.isEnabled, let message = AppleCalendarSource.issueMessage(calendarIssue) {
            issues.append("Apple Calendar: " + message)
        }
        if !AppleMailSelection.accounts.isEmpty, mailNeedsRetry, !mailHealth.isEmpty { issues.append(mailHealth) }
        let statuses = (try? JSONDecoder().decode([String: String].self, from: readStatusData)) ?? [:]
        for slug in MCPSource.kbSlugs() {
            guard let status = statuses[Diagnostics.source(slug)], status != "ok" else { continue }
            let name = ConnectorRegistry.displayName(slug: slug)
            issues.append(status == "connector_auth" ? "\(name): reconnect this source in Knowledge Sources."
                : "\(name): the last analysis did not finish. Run analysis to retry; saved knowledge is retained.")
        }
        let defaults = UserDefaults.standard
        let filesEnabled = !CustomRoots.urls.isEmpty || ["desktop", "documents", "downloads"].contains {
            defaults.bool(forKey: "dbg.run." + $0)
        }
        for (source, name, enabled) in [("file", "Files", filesEnabled),
            ("whatsapp", "WhatsApp", defaults.bool(forKey: "dbg.run.whatsapp")),
            ("imessage", "iMessage", defaults.bool(forKey: "dbg.run.imessage")),
            ("notes", "Notes", defaults.bool(forKey: "dbg.run.notes")),
            ("siyuan", "SiYuan", defaults.bool(forKey: SiYuanSource.enabledKey))] {
            guard enabled, let status = statuses[source], status != "ok" else { continue }
            issues.append(status == "time_cap" ? "\(name): more items remain. Run analysis to continue from saved progress."
                : "\(name): the last analysis did not finish. Check access and run analysis again.")
        }
        return issues
    }

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

    private var fullDiskRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            StatusLine(title: "Full Disk Access",
                       health: unreadableProtectedSources.isEmpty ? .ok : .bad,
                       note: protectedAccessNote,
                       tip: PrivacyCopy.fullDiskAccess,
                       fixTitle: "Grant…") {
                PermissionGuide.shared.guide(.fullDiskAccess, dragging: Bundle.main.bundleURL)
            }
            if !unreadableProtectedSources.isEmpty {
                HStack(spacing: 6) {
                    SettingsProse("Check access for \(unreadableProtectedSources.map(\.title).joined(separator: ", ")). After changing Full Disk Access:")
                    Button { Permissions.relaunch() } label: {
                        Text("Relaunch Sentient")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Ink.bright)
                            .underline(true, color: Theme.Ink.deepMuted)
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(!SafeAppRelaunch.shared.canRelaunch)
                }
                .padding(.bottom, 6)
                if let reason = SafeAppRelaunch.shared.statusReason {
                    SettingsProse(reason).padding(.bottom, 6)
                }
            }
        }
    }

    private var voiceRow: some View {
        StatusLine(title: "Microphone (optional)",
                   health: micSpeech == .granted ? .ok : .warn,   // optional — Sidekick's voice; tap-to-type works without it
                   note: micSpeechNote,
                   tip: ComputerUseGate.micSpeechTip,
                   fixTitle: micSpeech == .notAsked ? "Allow…" : "Fix…") {
            fixMicSpeech()
        }
    }

    private var screenRecordingRow: some View {
        StatusLine(title: "Screen Recording",
                   health: screenRec ? .ok : .bad,   // the driver's eyes — computer use is off without it
                   note: screenRec ? "granted" : "not granted",
                   tip: PrivacyCopy.screenCapture,
                   fixTitle: "Allow…") {
            fixScreenRecording()
        }
    }

    private var helperPermissionsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Computer-use access").font(.system(size: 14))
                        .foregroundStyle(Theme.Ink.statusInk)
                    Text(helperAccessStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(helperProblem ? Theme.Ink.amber : Theme.Ink.body)
                }
                Spacer(minLength: 12)
                SettingsPillButton(title: helperVerified ? "Manage…" : "Review access…") {
                    if computerGate.backend == .cua {
                        PermissionGuide.shared.guide(.accessibility, dragging: Bundle.main.bundleURL)
                    } else { computerGate.fixNativePermissions() }
                }
                .disabled(computerGate.requestingAutomation || computerGate.checkingCapabilities
                    || computerGate.checkingAutomation || !computerGate.setup.ready || ComputerUseDoctor.shared.isRunning)
            }
            if let error = computerGate.nativePermissionError {
                SettingsProse(error)
            }
        }
        .padding(.vertical, 6)
    }

    private var helperAccessStatus: String {
        if computerGate.checkingCapabilities || computerGate.requestingAutomation {
            return "Finish setup in the helper’s window"
        }
        if helperVerified { return "Ready" }
        return helperProblem ? "Needs attention" : "Managed in the computer-use helper"
    }

    // MARK: Microphone (one row — one microphone grant; optional, so yellow, never red)

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
            Permissions.openMicrophoneSettings()
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
        if mic == .authorized {
            micSpeech = .granted
        } else if mic == .denied || mic == .restricted {
            micSpeech = .denied
        } else {
            micSpeech = .notAsked
        }
    }

    // MARK: - SET UP CODEX (the cloud brain — all three are core, red when missing)
    //
    // The fix buttons drive the shared CodexSetup engine DIRECTLY — no intermediate sheet (the
    // old wiring bounced every button through CodexSetupView, which is the dev cockpit; decided
    // gone 2026-07-11). While a step runs, its LED goes amber, the note narrates, and the pill
    // hides; failures surface as a quiet prose line under the row. The browser login is
    // noticed automatically (the same 2s poll onboarding uses) — no "I'm done" button.

    private var codexSetupGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            subsectionTitle("Model connection")
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
                               tip: "Sentient's cloud thinking runs through your own model endpoint instead of a ChatGPT login.\n\nPick and test it in AI Models & Accounts.",
                               fixTitle: "Configure…") {
                        MainNavigation.shared.show(.settings, settingsPane: .frontierModel)
                    }
                } else {
                    StatusLine(title: "ChatGPT account",
                               health: codex.loggedIn ? .ok : (codex.loggingIn ? .warn : .bad),
                               note: codex.loggedIn ? "logged in"
                                   : codex.loggingIn ? "finish in your browser" : "not logged in",
                               tip: "Manage your ChatGPT sign-in in AI Models & Accounts. Your login stays in Sentient’s private folder on this Mac.",
                               fixTitle: "Manage account…",
                               fix: codex.loggedIn ? nil : { MainNavigation.shared.show(.settings, settingsPane: .frontierModel) })
                    failureLine(codex.loginStatusLine)

                }
                computerUseRow
            }
        }
    }

    private var sentientSetupGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            SentientInferencePanel()
            VStack(alignment: .leading, spacing: 8) {
                subsectionTitle("Local runtimes")
                VStack(alignment: .leading, spacing: 2) {
                    StatusLine(title: "Claude Code runtime",
                               health: claude.installing ? .warn : (claude.installed ? .ok : .bad),
                               note: claude.installed ? "installed" : "not installed",
                               tip: "Runs your selected AI through Sentient’s hosted service. A Claude subscription login is not required.",
                               fixTitle: "Set up…",
                               fix: sentient.preparing ? nil : { Task { _ = await sentient.prepare() } })
                    codexCLIRow
                    computerUseRow
                }
            }
        }
    }

    // MARK: - SET UP CLAUDE (the Claude backend's twin — Claude Code CLI · account · computer use)

    private var claudeSetupGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            subsectionTitle("Model connection")
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
                               : claude.verifyingLogin ? "checking sign-in…"
                               : claude.loggingIn ? "finish in your browser"
                               : claude.verificationPending ? "sign-in needs checking" : "not signed in",
                           tip: "Sign in directly through Claude Code in your browser. Its login is kept in your Mac’s Keychain and shared with your existing Claude Code setup.",
                           fixTitle: "Manage account…",
                           fix: claude.loggedIn ? nil : {
                               MainNavigation.shared.show(.settings, settingsPane: .frontierModel)
                           })
                failureLine(claude.loginStatusLine)
                codexCLIRow
                computerUseRow
            }
        }
    }

    @ViewBuilder private var codexCLIRow: some View {
        StatusLine(title: backend == .claude || backend == .sentient ? "Codex CLI for computer use" : "Codex CLI",
                   health: codex.installing ? .warn : (codex.computerUseReady && !codex.outdated ? .ok : .bad),
                   note: codex.installing ? "preparing…" : !codex.installed ? "not installed"
                       : codex.outdated || !codex.computerUseReady ? "needs an update"
                       : (codex.version.map { "installed · \($0)" } ?? "installed"),
                   tip: backend == .sentient
                       ? "Runs Sidekick’s computer actions on this Mac. Sentient covers inference; no ChatGPT or Claude subscription login is required."
                       : backend == .claude
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

    // MARK: - Probes

    private func refresh() async {
        computerGate.refresh()
        selectedProtectedSources = SourceSelection.selectedProtectedSources
        unreadableProtectedSources = selectedProtectedSources.filter { !$0.isReadable }
        loginOn = await LoginItem.refresh()
        if requiresOvernightSetup { await wakeSetup.refresh() }
        refreshMicSpeech()
        // Match the effective permission used by capture and the setup gates.
        screenRec = Permissions.hasScreenRecording()
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        await computerGate.awaitAutomationRefresh()
        ComputerUseSetup.current.refresh()
        // Only the LIVE engine's rows are probed (the login checks shell out, seconds each).
        // Custom backends keep the codex CLI probe (codex is their harness) but skip the login
        // check — no ChatGPT account is needed there.
        switch backend {
        case .sentient:
            await sentient.refresh()
        case .chatgpt:
            await codex.refreshInstalled()
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

/// Makes the complete disclosure header clickable, with a quiet trailing chevron.
private struct PermissionDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    configuration.label
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Ink.label)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content.padding(.top, 12)
            }
        }
    }
}

#if DEBUG
#Preview("Permissions & Help pane") {
    HealthPane(expandEngine: true)
        .background(Theme.bg)
        .frame(width: 720, height: 760)
}
#endif
