//
//  HealthCaution.swift
//  Sentient OS macOS
//
//  The home's LIVE health banner — the sibling of OvernightCaution (which records a past event,
//  this probes CURRENT state). One ladder, most severe first: ① an essential permission is off
//  (Full Disk Access · the overnight wake helper · launch at login — all gated green in
//  onboarding, so any red here is drift) → ② codex is gone, signed out, or out of date (a run
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

    enum EssentialPermission {
        case fullDiskAccess, overnightWake, launchAtLogin
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
                    return "A few permissions I rely on are off. Overnight runs are paused."
                }
                switch one {
                case .fullDiskAccess: return "Full Disk Access is off. I can't read anything new without it."
                case .overnightWake:  return "The overnight wake helper is off, so I can't work while you sleep."
                case .launchAtLogin:  return "Launch at login is off, so I won't be awake for the 3 AM run."
                }
            case .codexMissing:
                return ModelBackend.current == .claude
                    ? "Computer use needs Codex CLI. A quick setup in Permissions & Health fixes it."
                    : "Codex is missing from this Mac, so my cloud work is paused. A quick reinstall fixes it."
            case .codexSignedOut:
                return "Codex is signed out, so proactive work is paused. Log back in and I'll catch up tonight."
            case .codexOutdated:
                return "Codex needs attention. Open Settings to repair it or check for a Sentient update."
            case .claudeMissing:
                return "Claude Code is missing from this Mac, so my cloud work is paused. A quick reinstall fixes it."
            case .claudeSignedOut:
                return "Claude Code is signed out, so proactive work is paused. Sign back in and I'll catch up tonight."
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

    /// The ladder, most severe first. Returns the worst LIVE issue the user hasn't muted, or nil.
    /// `forceCodexRecheck` bypasses the login cache — the home passes it while a codex banner is
    /// showing, so logging back in clears the capsule on the very next foreground.
    static func probe(forceCodexRecheck: Bool = false) async -> Issue? {
        // The free-plan preview home: nightly runs, proactive, and Sidekick are all Plus-gated,
        // so nothing this ladder checks is worth interrupting that home for.
        guard !CodexAuth.knowledgeBaseOnly else { return nil }

        // ① Essential permissions (cheap sync probes: file reads + SMAppService status).
        let fda = Permissions.hasFullDiskAccess()
        var missing: [EssentialPermission] = []
        if !fda { missing.append(.fullDiskAccess) }
        // The same ground truth the scheduler gates on: the daemon ANSWERS over XPC. A file
        // check reads green even when the System Settings background toggle has booted the
        // daemon out of launchd (field-found 2026-07-11).
        if await !WakeHelperClient.shared.isReachable() {
            missing.append(.overnightWake)
        }
        if !LoginItem.isEnabled { missing.append(.launchAtLogin) }
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

        // ③ Computer use — only once latched. The cua driver runs inside Sentient's own TCC chain,
        // so its hands and eyes are Sentient's own grants: probed directly, no FDA needed
        // (AXIsProcessTrusted answers live; the Screen Recording preflight is this process's view,
        // so the FDA-backed TCC read rides along as the live truth when it's available).
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
                ComputerUseGate.shared.refresh()
                await ComputerUseGate.shared.awaitAutomationRefresh()
                if ComputerUseGate.shared.allRequiredGranted {
                    latchComputerUse()   // healthy — arm the latch so future drift banners
                } else if computerUseEverReady {
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
