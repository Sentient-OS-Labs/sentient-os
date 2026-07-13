//
//  OvernightCaution.swift
//  Sentient OS macOS
//
//  Cycle-failure classification + the morning-after caution. `classify(_:)` turns a cycle failure
//  into one of the three reasons a user can actually act on or should simply know about — codex
//  signed out · no internet · usage limit — and serves BOTH failure surfaces: the UNATTENDED 3am
//  run persists it via `record(_:)` (at ProactiveCycle's catch sites, the one choke point every
//  codex call already funnels typed errors through) and the home renders it as a quiet amber
//  capsule (HomeView.cautionBanner); the WATCHED processing takeover shows the same kind live on
//  its failed screen (ProcessingView.failedView — "Codex isn't logged in" + a login button). Any
//  later fully successful cycle clears the caution; so does the banner's ✕. Other failure kinds
//  stay log/Sentry territory — no banner.
//
//  Key methods: classify(_:) · record(_:) (3am only) · latest() · clear()
//

import Foundation
import Network
import os

enum OvernightCaution {

    enum Kind: String, Codable {
        case loggedOut    // codex had no working login when the night's cloud work started
        case noInternet   // the Mac was offline, so the cloud legs couldn't run
        case usageLimit   // the ChatGPT plan's window was exhausted mid-run

        /// The banner line — quiet, first-person, honest about what happens next.
        var message: String {
            switch self {
            case .loggedOut:  return "I couldn't work last night. Codex was signed out; log back in and I'll catch up tonight."
            case .noInternet: return "No internet last night, so I couldn't do my overnight work. I'll try again tonight."
            case .usageLimit: return "We hit ChatGPT's usage limit last night. I'll pick it up again tomorrow."
            }
        }
    }

    struct Record: Codable {
        let kind: Kind
        let date: Date
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
        if case CodexCLI.CLIError.usageLimit = error {
            return .usageLimit                       // typed — certain, no probing needed
        }
        // A 401 in codex's own output means the token died SERVER-side — auth.json still looks
        // logged-in to the local probe below, so codex's stderr is the only tell (the exact
        // failure of 2026-07-12: a token invalidated by a re-login elsewhere).
        if case CodexCLI.CLIError.notAvailable(.notWorking(let detail)) = error,
           detail.contains("401") || detail.localizedCaseInsensitiveContains("unauthorized") {
            return .loggedOut
        }
        if await !CodexCLI.loginStatus() { return .loggedOut }   // local auth check — reliable even offline
        if await !networkUp() { return .noInternet }
        return nil
    }

    /// Persist a classified kind as the morning-after caution (3am runs only; nil records nothing).
    static func record(_ kind: Kind?) {
        guard let kind else { return }
        if let data = try? JSONEncoder().encode(Record(kind: kind, date: Date())) {
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
