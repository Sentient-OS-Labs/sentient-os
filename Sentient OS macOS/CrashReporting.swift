//
//  CrashReporting.swift
//  Sentient OS macOS
//
//  Sentry integration — the app's crash-log + error + performance reporter. One entry
//  point, `CrashReporting.start(process:)`, called from main.swift before anything else in
//  BOTH process roles (the GUI app and the root --wake-helper LaunchDaemon), each tagged so a
//  3am overnight-run crash is told apart from a UI crash. `Log()` (Log.swift) tees every line
//  in as a breadcrumb, so a crash report arrives carrying the recent log trail that led to it.
//
//  Setup: paste your project DSN from sentry.io into `dsn` below (Settings → Projects →
//  <project> → Client Keys (DSN)). Until then reporting stays off and we log a one-line notice.
//

import Foundation
import Sentry

enum CrashReporting {

    /// The Sentry project DSN. NOT a secret — it can only write crash reports in, never read
    /// anything out — so it lives in source, public-facing, even when the repo goes open source.
    private static let dsn = "https://10ff4d2487c4913fcc9c61bd596bcf9f@o4511650390933504.ingest.us.sentry.io/4511651474636800"

    /// Which process this is, used as the `process` tag on every event.
    enum Role: String {
        case app          // the normal GUI app
        case wakeHelper   // the root LaunchDaemon (main.swift --wake-helper branch)
    }

    private static var started = false

    /// Boot Sentry once for this process. Safe to call from either main.swift branch.
    static func start(_ role: Role) {
        guard !started else { return }
        started = true

        guard !dsn.isEmpty, !dsn.hasPrefix("PASTE_") else {
            Log("CrashReporting: no DSN set — Sentry disabled (set Secrets.sentryDSN to enable)")
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn

            // Crashes: native signals + unhandled NSExceptions, with the full stack attached
            // to every event (not just crashes).
            options.attachStacktrace = true
            options.enableCrashHandler = true

            // Performance: trace + profile everything. This is a single-user desktop app, not a
            // high-traffic server, so 100% sampling is cheap and gives complete pictures. Profiling
            // uses the current trace-lifecycle API (tied to traces), not the deprecated rate knob.
            options.tracesSampleRate = 1.0
            options.configureProfiling = {
                $0.sessionSampleRate = 1.0
                $0.lifecycle = .trace
            }

            // Sessions (release health) + app-hang ("beachball") detection.
            options.enableAutoSessionTracking = true
            options.enableAppHangTracking = true

            #if DEBUG
            options.environment = "debug"
            #else
            options.environment = "release"
            #endif

            // We feed our own Log() breadcrumbs (below); the SDK's automatic console/UI
            // breadcrumbs stay on too for extra context.
        }

        SentrySDK.configureScope { scope in
            scope.setTag(value: role.rawValue, key: "process")
        }

        Log("CrashReporting: Sentry started (process=\(role.rawValue))")
    }

    /// Record a Log() line as a Sentry breadcrumb so crash reports carry the recent trail.
    /// No-op until Sentry has started. Called from Log() (Log.swift).
    static func breadcrumb(_ message: String) {
        guard started else { return }
        let crumb = Breadcrumb(level: .info, category: "log")
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Report a caught error that we still want visibility into (one that doesn't crash the app).
    static func capture(_ error: Error) {
        guard started else { return }
        SentrySDK.capture(error: error)
    }

    #if DEBUG
    /// DEV verification: send a non-fatal test event (lands in the dashboard within seconds).
    static func sendTestEvent() {
        guard started else { Log("CrashReporting.sendTestEvent: Sentry not started (no DSN?)"); return }
        SentrySDK.capture(message: "Sentry test event from DEV TOOLS")
        Log("CrashReporting: sent test event")
    }

    /// DEV verification: hard-crash so the native crash handler fires. The report lands on the
    /// NEXT launch (that's how crash capture works). Only ever called from the DEBUG dev button.
    static func forceCrash() {
        guard started else { Log("CrashReporting.forceCrash: Sentry not started (no DSN?)"); return }
        Log("CrashReporting: forcing a test crash now")
        SentrySDK.crash()
    }
    #endif
}
