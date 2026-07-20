//
//  HealthCaution.swift
//  Sentient OS macOS
//
//  The home's LIVE health banner — the sibling of OvernightCaution (which records a past event,
//  this probes CURRENT state). One ladder, most severe first: ① an essential permission is off
//  (Full Disk Access · the overnight wake helper · launch at login — all gated green in
//  onboarding, so any red here is drift) → ② codex is gone or signed out → ③ computer use broke
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
        case computerUseBroken(payloadGone: Bool)   // true = the ~/.codex bootstrap vanished; false = the helper's grants did

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
                return "Codex is missing from this Mac, so my cloud work is paused. A quick reinstall fixes it."
            case .codexSignedOut:
                return "Codex is signed out, so proactive work is paused. Log back in and I'll catch up tonight."
            case .computerUseBroken(let payloadGone):
                return payloadGone
                    ? "Computer use needs setting up again; Codex may have updated. One click in Settings fixes it."
                    : "Codex's computer use lost its permissions, so I can't act on your Mac for you."
            }
        }

        /// Dismissal identity — ✕ mutes the whole KIND for the session, not one exact payload.
        var kindKey: String {
            switch self {
            case .permissions:                   return "permissions"
            case .codexMissing, .codexSignedOut: return "codex"
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

    static func latchComputerUse() {
        UserDefaults.standard.set(true, forKey: computerUseEverReadyKey)
    }

    private static var computerUseEverReady: Bool {
        UserDefaults.standard.bool(forKey: computerUseEverReadyKey)
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

        // ② Codex — gone, or signed out.
        let codexInstalled = CodexCLI.locateBinary() != nil
        if !dismissed.contains("codex") {
            if !codexInstalled { return .codexMissing }
            if await !loggedIn(force: forceCodexRecheck) { return .codexSignedOut }
        }

        // ③ Computer use — only once latched, and only with FDA to read the helper's system-TCC
        // grants (without FDA rung ① already speaks; unverifiable must never claim broken).
        if fda, codexInstalled, !dismissed.contains("computerUse") {
            if !ComputerUseSetup.isInstalled {
                if computerUseEverReady { return .computerUseBroken(payloadGone: true) }
            } else {
                let hands = Permissions.hasComputerUseAccessibility()
                let eyes = Permissions.hasComputerUseScreenRecording()
                if hands && eyes {
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
}
