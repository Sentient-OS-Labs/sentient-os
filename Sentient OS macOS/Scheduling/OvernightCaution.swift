//
//  OvernightCaution.swift
//  Sentient OS macOS
//
//  Cycle-failure classification + the morning-after caution. `classify(_:)` turns a cycle failure
//  into one of the reasons a user can actually act on or should simply know about — codex signed
//  out · no internet · usage limit · a full disk · connector sign-in · a stalled night.
//  The scheduler records connector sign-in failures and watchdog stalls directly; classify(_:)
//  handles shared cycle failures. Both the unattended morning caution and watched processing
//  failure UI use this vocabulary. The home renders the saved caution as an amber capsule; the
//  WATCHED processing takeover shows the same kind live on its failed screen
//  (ProcessingView.failedView — "Codex isn't logged in" + a login button, "Your Mac's disk is
//  full" + a storage button). Any later fully successful cycle clears the caution; so does the
//  banner's ✕. Other failure kinds stay log/Sentry territory — no banner.
//
//  Key methods: classify(_:) · record(_:) (3am only) · latest() · clear()
//

import Foundation
import Network
import os

enum OvernightCaution {

    enum Kind: String, Codable {
        case loggedOut      // codex had no working login when the night's cloud work started
        case noInternet     // the Mac was offline, so the cloud legs couldn't run
        case usageLimit     // the ChatGPT plan's window was exhausted mid-run
        case inputTooLarge  // a prompt exceeded codex's turn-input cap (a canary — corpus
                            // slicing budgets every prompt path, so this should never fire)
        case diskFull       // the Mac's disk is full: the device stage stopped (nothing it read
                            // could be saved) or the knowledge-base staging copy couldn't be written
        case connectorAuth  // a KB-enabled connector's own sign-in expired account-side, so its
                            // nightly read couldn't run (the engine login itself was fine); the
                            // record's `detail` carries the connector's display name
        case stalled        // the night made no progress for over an hour (no error, no timeout —
                            // just silence), so the scheduler's watchdog ended it and restored sleep

        /// The banner line — quiet, first-person, honest about what happens next. Engine-aware
        /// at RENDER time (the record persists only overnight, so the live backend names the
        /// engine truthfully).
        var message: String {
            let claude = ModelBackend.current == .claude
            switch self {
            case .loggedOut:  return claude
                ? "I couldn't work last night. Claude Code was signed out; sign back in and I'll catch up tonight."
                : "I couldn't work last night. Codex was signed out; log back in and I'll catch up tonight."
            case .noInternet: return "No internet last night, so I couldn't do my overnight work. I'll try again tonight."
            case .usageLimit: return claude
                ? "We hit Claude's usage limit last night. I'll pick it up again tomorrow."
                : "We hit ChatGPT's usage limit last night. I'll pick it up again tomorrow."
            case .inputTooLarge: return claude
                ? "Last night's batch was more than Claude accepts at once. Your analysis is saved; I'll try again tonight."
                : "Last night's batch was more than ChatGPT accepts at once. Your analysis is saved; I'll try again tonight."
            case .diskFull:   return "Your Mac's disk is full, so I couldn't save last night's work. Free up some space and I'll catch up tonight."
            case .connectorAuth: return claude
                ? "I couldn't read one of your connected apps last night. Sign in to it again on claude.ai and I'll catch up tonight."
                : "I couldn't read one of your connected apps last night. Sign in to it again on chatgpt.com and I'll catch up tonight."
            case .stalled:    return "Last night's work got stuck partway, so I stopped and let your Mac sleep. Everything's saved; I'll try again tonight."
            }
        }
    }

    struct Record: Codable {
        let kind: Kind
        let date: Date
        /// Kind-specific context for the banner line — today only `.connectorAuth` uses it (the
        /// connector's display name). Optional so records persisted before the field decode fine.
        var detail: String?

        /// The banner line the home renders: personalized when the record carries a connector
        /// name, else the kind's generic message (engine-aware at render time, like the kinds).
        var message: String {
            if kind == .connectorAuth, let detail, !detail.isEmpty {
                let place = ModelBackend.current == .claude ? "claude.ai" : "chatgpt.com"
                return "I couldn't read your \(detail) last night. Sign in to it again on \(place) and I'll catch up tonight."
            }
            return kind.message
        }
    }

    private static let key = "overnight.caution"

    /// The caution the home should show, if any.
    static func latest() -> Record? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// A later cycle succeeded, or the user dismissed the banner.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Classify a cycle failure into one of the three user-facing kinds (nil = unclassifiable —
    /// the UI only ever states what was verified). Shared by the 3am run (record + banner) and
    /// the watched takeover's failed screen.
    static func classify(_ error: Error) async -> Kind? {
        // A full disk is certain and local (the knowledge-base staging copy is written on the Mac);
        // it must never be misread as an internet or login problem, so it goes first.
        if DiskSpace.isDiskFull(error) { return .diskFull }
        // Typed errors first — certain, no probing needed. The cycle's stage wrappers each re-wrap
        // the spine's usage limit in their own enum (create/update/judge/research), so match them
        // all: a stringly wrap here once left the amber banner blind to a vault-leg usage limit.
        switch error {
        case CodexCLI.CLIError.usageLimit,
             VaultGenerator.VaultError.usageLimit,
             VaultCloud.CloudError.usageLimit,
             Proactive.ProError.usageLimit,
             ProactiveResearch.ResError.usageLimit,
             GiftLetter.GiftError.usageLimit:
            return .usageLimit
        case CodexCLI.CLIError.inputTooLarge:
            return .inputTooLarge                    // the canary — see Kind
        default:
            break
        }
        // The logged-out rungs are subscription-backend-only: on a custom frontier model there
        // is no login, and a 401 there means the endpoint rejected the user's API key — "log
        // back in" would be wrong advice. (An endpoint-specific caution kind can come later;
        // unclassifiable stays honest silence.)
        if ModelBackend.current == .claude {
            if case CodexCLI.CLIError.notAvailable(.notWorking(let detail)) = error,
               detail.localizedCaseInsensitiveContains("not logged in") {
                return .loggedOut
            }
            if await !ClaudeCLI.loginStatus() { return .loggedOut }
        }
        if ModelBackend.current == .chatgpt {
            // A 401 in codex's own output means the token died SERVER-side — auth.json still looks
            // logged-in to the local probe below, so codex's stderr is the only tell (the exact
            // failure of 2026-07-12: a token invalidated by a re-login elsewhere).
            if case CodexCLI.CLIError.notAvailable(.notWorking(let detail)) = error,
               detail.contains("401") || detail.localizedCaseInsensitiveContains("unauthorized") {
                return .loggedOut
            }
            if await !CodexCLI.loginStatus() { return .loggedOut }   // local auth check — reliable even offline
        }
        if await !networkUp() { return .noInternet }
        return nil
    }

    /// Persist a classified kind as the morning-after caution (3am runs only; nil records
    /// nothing). `detail` is kind-specific banner context (a connector's display name for
    /// `.connectorAuth`) — user-facing only, never telemetry.
    static func record(_ kind: Kind?, detail: String? = nil) {
        guard let kind else { return }
        if let data = try? JSONEncoder().encode(Record(kind: kind, date: Date(), detail: detail)) {
            UserDefaults.standard.set(data, forKey: key)
        }
        Log("OvernightCaution: recorded .\(kind.rawValue)")
        // Environment weather (signed out / offline / usage limit), not an app defect — product
        // telemetry, so TelemetryDeck, never the Sentry issue feed (2026-07-12).
        Analytics.signal("Scheduler.caution", parameters: ["kind": kind.rawValue])
    }

    /// One NWPathMonitor snapshot — the first path update arrives immediately; guarded so the
    /// continuation can never resume twice.
    private static func networkUp() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let resumed = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                guard resumed.withLock({ done in
                    if done { return false }
                    done = true
                    return true
                }) else { return }
                monitor.cancel()
                cont.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }
}
