//
//  OvernightCaution.swift
//  Sentient OS macOS
//
//  The morning-after caution: when the UNATTENDED 3am cycle fails for one of the three reasons a
//  user can actually act on or should simply know about — codex signed out · no internet · usage
//  limit — the failure is classified here (at ProactiveCycle's catch sites, the one choke point
//  every codex call already funnels typed errors through) and persisted, and the home renders it
//  as a quiet amber capsule (HomeView.cautionBanner). Any later fully successful cycle clears it;
//  so does the banner's ✕. Other failure kinds stay log/Sentry territory — no banner.
//
//  Key methods: note(_:) (classify + record) · latest() · clear()
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

    /// Classify a scheduled-cycle failure into one of the three user-facing kinds and persist it.
    /// Anything unclassifiable records nothing (the banner only ever states what we verified).
    static func note(_ error: Error) async {
        let kind: Kind?
        if case CodexCLI.CLIError.usageLimit = error {
            kind = .usageLimit                       // typed — certain, no probing needed
        } else if await !CodexCLI.loginStatus() {    // local auth check — reliable even offline
            kind = .loggedOut
        } else if await !networkUp() {
            kind = .noInternet
        } else {
            kind = nil
        }
        guard let kind else { return }
        if let data = try? JSONEncoder().encode(Record(kind: kind, date: Date())) {
            UserDefaults.standard.set(data, forKey: key)
        }
        Log("OvernightCaution: recorded .\(kind.rawValue)")
        CrashReporting.captureEvent("overnight.caution", level: .info,
            tags: ["kind": kind.rawValue], fingerprint: ["overnight", "caution", kind.rawValue])
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
