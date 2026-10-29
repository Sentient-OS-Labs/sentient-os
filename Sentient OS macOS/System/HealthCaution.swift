//
//  HealthCaution.swift
//  Sentient OS macOS
//
//  The home's LIVE health banner — the sibling of OvernightCaution (which records a past event,
//  this probes CURRENT state). One ladder, most severe first: ① access to a selected protected
//  source has failed, or explicitly enabled overnight work needs its wake/login setup
//  → ② codex is gone, signed out, or out of date (a run
//  failed on the stale-client signature and the update hasn't landed) → ③ computer use broke
//  AFTER it was once seen working (the everReady latch, so a user who never set it up is never
//  nagged). The home renders the top un-muted rung as a red capsule (HomeView.cautionBanner) and
//  re-probes on foreground, so a fix in Settings clears the banner the moment the user returns.
//  Nothing is persisted: no state, no record — broken shows, fixed melts away. ✕ mutes an issue
//  KIND for the app session; lower rungs still surface. Knowledge-base-only (free plan) homes get
//  no banners at all — nothing nightly runs for them. The codex login check shells out (seconds),
//  so its verdict is cached ~5 min; the cache is bypassed while a codex banner is up.
//
//  Key methods: probe(forceCodexRecheck:) · dismiss(_:) · latchComputerUse()
//

import Foundation

@MainActor
enum HealthCaution {

    // MARK: The issues

    enum EssentialPermission: Equatable {
        case fullDiskAccess, overnightWake, launchAtLogin
        case protectedSources([String])
    }

    enum Issue {
        case permissions([EssentialPermission])
        case codexMissing
        case codexSignedOut
        case codexOutdated                          // a run failed on the stale-client signature; CodexSetup.outdated
        case claudeMissing                          // Claude backend: the Claude Code binary vanished
        case claudeSignedOut                        // Claude backend: `claude auth status` reads logged out
        case computerUseBroken(payloadGone: Bool)   // true = the cua-driver binary vanished; false = Sentient's own grants did

        /// The banner line — quiet, first-person, honest about what happens next.
        var message: String {
            switch self {
            case .permissions(let missing):
                guard missing.count == 1, let one = missing.first else {
                    return "Some selected sources or overnight settings need attention. Check Permissions & Health."
                }
                switch one {
                case .fullDiskAccess: return "A selected protected source needs access. Your other sources remain available."
                case .protectedSources(let names):
                    return "I can't read \(names.joined(separator: ", ")). Check access for these selected sources; your other sources remain available."
                case .overnightWake:  return "The overnight wake helper is off, so I can't work while you sleep."
                case .launchAtLogin:  return "Launch at login is off. Turn it on so Sentient can resume your overnight schedule after login."
                }
            case .codexMissing:
                return ModelBackend.current == .claude
                    ? "Computer use needs Codex CLI. A quick setup in Permissions & Health fixes it."
                    : "Codex is missing from this Mac, so my cloud work is paused. A quick reinstall fixes it."
            case .codexSignedOut:
                return "ChatGPT is signed out. Sign back in to use Sidekick and resume any scheduled work."
            case .codexOutdated:
                return "Codex needs attention. Open Settings to repair it or check for a Sentient update."
            case .claudeMissing:
                return "Claude Code is missing from this Mac, so my cloud work is paused. A quick reinstall fixes it."
            case .claudeSignedOut:
                return "Claude Code is signed out. Sign back in to use Sidekick and resume any scheduled work."
            case .computerUseBroken(let payloadGone):
                return payloadGone
                    ? "Computer use needs setting up again. One click in Settings fixes it."
                    : "Computer use is missing its permissions, so I can't act on your Mac for you."
            }
        }

        /// Dismissal identity — ✕ mutes the whole KIND for the session, not one exact payload.
        var kindKey: String {
            switch self {
            case .permissions:                   return "permissions"
            case .codexMissing, .codexSignedOut, .codexOutdated,
                 .claudeMissing, .claudeSignedOut: return "codex"   // one engine-rung mute kind
            case .computerUseBroken:             return "computerUse"
            }
        }
    }

    // MARK: Session mutes

    /// Issue kinds ✕'d this session — quiet until relaunch; lower rungs still surface.
    private static var dismissed: Set<String> = []

    static func dismiss(_ issue: Issue) { dismissed.insert(issue.kindKey) }

    // MARK: The computer-use latch

    /// "Computer use was seen working once" — arms rung ③, so only a REGRESSION banners (never a
    /// setup the user hasn't done yet). Set by the probe when the whole stack reads healthy and by
    /// ComputerUseGate at its moment of truth. FactoryReset clears it: a rebuild re-runs the gate.
    static let computerUseEverReadyKey = "computerUse.everReady"

    static let nativeComputerUseEverReadyKey = "computerUse.nativeEverReady"

    static func latchComputerUse() {
        UserDefaults.standard.set(true, forKey: computerUseEverReadyKey)
        if ComputerUseBackend.current == .openAI {
            UserDefaults.standard.set(true, forKey: nativeComputerUseEverReadyKey)
        }
    }

    private static var computerUseEverReady: Bool {
        UserDefaults.standard.bool(forKey: ComputerUseBackend.current == .openAI ? nativeComputerUseEverReadyKey : computerUseEverReadyKey)
    }

    // MARK: The probe

    /// `codex login status` shells out — cache the verdict so foreground flurries can't spam it.
    private static var codexLogin: (verdict: Bool, at: Date)?

    /// Optional background requirements follow saved intent, never Home admission. A pending
    /// scheduled first analysis is an explicit choice even when recurring overnight work is off.
    static func overnightRequested(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: OvernightScheduler.enabledKey)
            || defaults.bool(forKey: OvernightScheduler.prodEnabledKey)
            || ProcessingPlan.read(defaults).status == .scheduled
    }

    /// Read only selected sources, and only after setup or a known successful read. This pure
    /// policy seam lets regression tests supply synthetic availability without touching TCC.
    static func unreadableProtectedSources(personalSetupComplete: Bool,
                                           selected: [ProtectedLocalSource],
                                           readStatuses: [String: String],
                                           isReadable: (ProtectedLocalSource) -> Bool) -> [ProtectedLocalSource] {
        selected.filter { source in
            let statusKey = source == .mail ? "apple_mail" : source.rawValue
            guard personalSetupComplete || readStatuses[statusKey] == "ok" else { return false }
            return !isReadable(source)
        }
    }

    static func permissionRequirements(unreadableSources: [ProtectedLocalSource], overnightRequested: Bool,
                                       wakeReady: Bool, loginEnabled: Bool) -> [EssentialPermission] {
        var missing: [EssentialPermission] = []
        if !unreadableSources.isEmpty { missing.append(.protectedSources(unreadableSources.map(\.title))) }
        if overnightRequested {
            if !wakeReady { missing.append(.overnightWake) }
            if !loginEnabled { missing.append(.launchAtLogin) }
        }
        return missing
    }

    /// A session starts with unknown helper evidence. Only a confirmed loss can be regression;
    /// pending proof, an unavailable helper, or a generic check error never fabricate denial.
    static func hasConfirmedComputerPermissionLoss(everReady: Bool, nativeBackend: Bool,
                                                   sentientScreen: Bool, sentientAccessibility: Bool,
                                                   automation: Permissions.AutomationState,
                                                   helper: NativePermissionReadiness.Snapshot) -> Bool {
        guard everReady else { return false }
        guard sentientScreen else { return true }
        if !nativeBackend { return !sentientAccessibility }
        return automation == .denied || helper.accessibility == .denied || helper.screenRecording == .denied
    }

    /// The ladder, most severe first. Returns the worst LIVE issue the user hasn't muted, or nil.
    /// `forceCodexRecheck` bypasses the login cache — the home passes it while a codex banner is
    /// showing, so logging back in clears the capsule on the very next foreground.
    static func probe(forceCodexRecheck: Bool = false) async -> Issue? {
        // The free-plan preview home: nightly runs, proactive, and Sidekick are all Plus-gated,
        // so nothing this ladder checks is worth interrupting that home for.
        guard !CodexAuth.knowledgeBaseOnly else { return nil }

        // ① Only capabilities the user chose. No broad FDA probe or unrelated database reads.
        let unreadable = unreadableProtectedSources(personalSetupComplete: PersonalSetupProgress.isComplete(),
            selected: SourceSelection.selectedProtectedSources, readStatuses: SourceHealth.readStatuses(),
            isReadable: { $0.isReadable })
        let overnight = overnightRequested()
        var wakeReady = true
        var loginEnabled = true
        if overnight {
            // Actual reachability is the scheduler's ground truth, rather than a file existing.
            wakeReady = await WakeHelperClient.shared.isReachable()
            loginEnabled = LoginItem.isEnabled
        }
        let missing = permissionRequirements(unreadableSources: unreadable, overnightRequested: overnight,
                                             wakeReady: wakeReady, loginEnabled: loginEnabled)
        if !missing.isEmpty, !dismissed.contains("permissions") { return .permissions(missing) }

        // ② The frontier engine — gone, signed out, or (codex) out of date. Engine-aware: the
        // Claude backend probes Claude Code; chatgpt/custom probe codex (a custom endpoint still
        // runs THROUGH the codex harness — only the login rung is skipped there, since custom
        // needs no ChatGPT login, and a live endpoint check would cost a model call per
        // foreground). The out-of-date rung is codex-only, evidence-driven (stale-client
        // signature) and melts the moment CodexSetup's update lands.
        let engineIsClaude = ModelBackend.current == .claude
        let engineBinaryPresent = engineIsClaude ? ClaudeCLI.locateBinary() != nil
                                                 : CodexCLI.locateBinary() != nil
        if !dismissed.contains("codex") {
            if engineIsClaude {
                if !engineBinaryPresent { return .claudeMissing }
                if await !claudeLoggedIn(force: forceCodexRecheck) { return .claudeSignedOut }
                if computerUseEverReady, CodexCLI.locateBinary() == nil { return .codexMissing }
                if CodexSetup.shared.outdated { return .codexOutdated }
            } else {
                if !engineBinaryPresent { return .codexMissing }
                if ModelBackend.current == .chatgpt,
                   await !loggedIn(force: forceCodexRecheck) { return .codexSignedOut }
                if CodexSetup.shared.outdated { return .codexOutdated }
            }
        }

        // ③ Computer use — only once latched, and only confirmed failures. Passive refresh
        // never opens the synthetic capability-check window or requests a system grant.
        if engineBinaryPresent, !dismissed.contains("computerUse") {
            if !ComputerUseBackend.current.isInstalled || !ComputerUseSetup.current.ready {
                // The update-migration window (ComputerUseUpgrade) presents on this exact state at
                // home open, with the download as ITS one glowing fix — while it's up, a red
                // banner behind it would be the same message twice. The banner still covers the
                // window-less case (the driver vanishing mid-session; the next home open raises
                // the window and this rung goes quiet again).
                // Startup verification is pending, not a broken installation. Home rechecks
                // when the shared installer finishes, including after a failed download.
                if computerUseEverReady, !ComputerUseSetup.current.isInstalling,
                   !ComputerUseUpgrade.shared.isPresenting,
                   ComputerUseSetup.current.updateNotice == .hidden {
                    return .computerUseBroken(payloadGone: true)
                }
            } else {
                let gate = ComputerUseGate.shared
                gate.refresh()
                await gate.awaitAutomationRefresh()
                if gate.allRequiredGranted {
                    latchComputerUse()   // healthy — arm the latch so future drift banners
                } else if hasConfirmedComputerPermissionLoss(everReady: computerUseEverReady,
                    nativeBackend: ComputerUseBackend.current == .openAI,
                    sentientScreen: gate.sentientScreen, sentientAccessibility: gate.sentientAccessibility,
                    automation: gate.automation, helper: gate.helperPermissionState) {
                    return .computerUseBroken(payloadGone: false)
                }
            }
        }
        return nil
    }

    private static func loggedIn(force: Bool) async -> Bool {
        if !force, let cached = codexLogin, Date().timeIntervalSince(cached.at) < 300 {
            return cached.verdict
        }
        let verdict = await CodexCLI.loginStatus()
        codexLogin = (verdict, Date())
        return verdict
    }

    /// The Claude twin (`claude auth status` shells out too — same ~5 min cache, same bypass
    /// while an engine banner is showing).
    private static var claudeLogin: (verdict: Bool, at: Date)?

    private static func claudeLoggedIn(force: Bool) async -> Bool {
        if !force, let cached = claudeLogin, Date().timeIntervalSince(cached.at) < 300 {
            return cached.verdict
        }
        let verdict = await ClaudeCLI.loginStatus()
        claudeLogin = (verdict, Date())
        return verdict
    }
}
