//
//  CrashReporting.swift
//  Sentient OS macOS
//
//  Sentry integration — the app's crash-log + error + structured-diagnostics reporter. One entry
//  point, `CrashReporting.start(_:)`, called from main.swift before anything else in BOTH process
//  roles (the GUI app and the root --wake-helper LaunchDaemon), each tagged so a 3am overnight-run
//  crash is told apart from a UI crash. `Log()` (Log.swift) tees every line in as a breadcrumb, so a
//  report arrives carrying the recent log trail that led to it.
//
//  Two hard gates decide whether ANYTHING reaches Sentry (Documentation/Source Diagnostics …):
//   1. RELEASE builds only — `start()` no-ops in DEBUG. There is NO debug bypass: Sentry never
//      initializes in a Debug build, so verify the pipeline from a Release build.
//   2. Opt-OUT switch — `diagnosticsEnabled` (default ON); the "Share anonymous crash reports"
//      toggle in Settings → System gates ALL Sentry reporting, crashes included. (Product
//      analytics has its own separate switch — see Analytics.swift.)
//  Privacy is upheld by construction, not by the switch: `captureEvent` only ever takes
//  counts/enums/versions/error-type-names, and `beforeSend`/`beforeBreadcrumb` scrub free text as a
//  backstop. Events carry an anonymous per-install id (a random UUID, never the mirror token).
//
//  Key members:
//   - start(_:)                       → boot Sentry (Release-only, opt-out gated)
//   - captureEvent(_:level:tags:extra:fingerprint:)  → structured, PII-free diagnostics event
//   - capture(_:) / breadcrumb(_:)    → non-fatal error / the Log() trail
//   - diagnosticsEnabled              → the opt-out reader (off-main safe)
//
//  Doc: Documentation/Crash Reporting (Sentry).md · Documentation/Source Diagnostics & Hardening (Sentry).md
//

import Foundation
import Sentry

enum CrashReporting {

    /// The Sentry project DSN. NOT a secret — it can only write reports in, never read anything out —
    /// so it lives in source, public-facing, even when the repo goes open source.
    private static let dsn = "https://10ff4d2487c4913fcc9c61bd596bcf9f@o4511650390933504.ingest.us.sentry.io/4511651474636800"

    /// Which process this is, used as the `process` tag on every event.
    enum Role: String {
        case app          // the normal GUI app
        case wakeHelper   // the root LaunchDaemon (main.swift --wake-helper branch)
    }

    /// Diagnostics severity — our own Sendable enum so the SDK type never crosses the call boundary.
    enum DiagLevel: String, Sendable { case info, warning, error, fatal }

    private static var started = false

    // MARK: - Opt-out gate + anonymous identity

    private static let diagnosticsKey = "diagnosticsEnabled"
    private static let installIDKey = "diagnostics.installID"

    /// The opt-OUT switch: default ON, gates ALL Sentry. Off-main safe (UserDefaults is sync +
    /// thread-safe), so the off-main diagnostics call sites read it with no executor hop. Treats an
    /// unset key as ON (a bare `bool(forKey:)` returns false for a missing key → would read as off).
    nonisolated static var diagnosticsEnabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: diagnosticsKey) == nil { return true }
        return d.bool(forKey: diagnosticsKey)
    }

    /// A random per-install id (minted once, kept in UserDefaults) — lets recurring faults on one
    /// machine correlate WITHOUT any account or link to a person. Never the mirror token, never
    /// hardware-derived; resets on reinstall / clear-data, which is fine (coarse correlation only).
    nonisolated static var installID: String {
        let d = UserDefaults.standard
        if let existing = d.string(forKey: installIDKey) { return existing }
        let id = UUID().uuidString
        d.set(id, forKey: installIDKey)
        return id
    }

    // MARK: - Boot

    /// Boot Sentry for this process — but only in RELEASE and only if diagnostics are on. Safe to call
    /// from either main.swift branch. In DEBUG this is a deliberate no-op.
    static func start(_ role: Role) {
        guard diagnosticsEnabled else {
            Log("CrashReporting: diagnostics opted out — Sentry disabled")
            return
        }
        #if DEBUG
        Log("CrashReporting: DEBUG build — Sentry disabled (Release-only; verify from a Release build)")
        #else
        boot(role)
        #endif
    }

    /// The actual SDK boot. Reached ONLY via `start()` in a Release build (there is no DEBUG bypass —
    /// Sentry never initializes in Debug; verify the pipeline from a Release build).
    private static func boot(_ role: Role) {
        guard !started else { return }
        guard !dsn.isEmpty, !dsn.hasPrefix("PASTE_") else {
            Log("CrashReporting: no DSN set — Sentry disabled")
            return
        }
        started = true

        SentrySDK.start { options in
            options.dsn = dsn

            // Crashes: native signals + unhandled NSExceptions, with the full stack on every event.
            options.attachStacktrace = true
            options.enableCrashHandler = true

            // Performance: trace + profile everything — a single-user desktop app, so 100% is cheap.
            options.tracesSampleRate = 1.0
            options.configureProfiling = {
                $0.sessionSampleRate = 1.0
                $0.lifecycle = .trace
            }

            // Sessions (release health) + app-hang ("beachball") detection.
            options.enableAutoSessionTracking = true
            options.enableAppHangTracking = true

            options.environment = "release"

            // PII backstop (defense in depth — clean-at-source is the primary defense): scrub free
            // text on both outgoing events and Log()-fed breadcrumbs, on the SDK's transport thread.
            options.beforeSend = { event in scrub(event) }
            options.beforeBreadcrumb = { crumb in
                crumb.message = crumb.message.map(scrub(text:))
                return crumb
            }
        }

        SentrySDK.configureScope { scope in
            scope.setTag(value: role.rawValue, key: "process")
            scope.setTag(value: osVersion, key: "os_version")
            scope.setTag(value: appVersion, key: "app_version")
            scope.setUser(User(userId: installID))   // the anonymous per-install id
        }

        Log("CrashReporting: Sentry started (process=\(role.rawValue))")
    }

    // MARK: - Structured diagnostics event

    /// Report a structured, PII-free diagnostics event (an alert grouped by failure mode). Callable
    /// off-main with no await (nonisolated + Sendable params) — `@ModelActor`s, off-main connectors,
    /// and dispatch closures all hit it directly. OS/app versions are auto-stamped so no call site
    /// forgets. ⚠️ `message`/`tags`/`extra` must be structure only (counts, enums, error-TYPE names,
    /// versions) — NEVER user content; see the PII firewall in the diagnostics doc.
    nonisolated static func captureEvent(_ message: String,
                                         level: DiagLevel = .warning,
                                         tags: [String: String] = [:],
                                         extra: [String: String] = [:],
                                         fingerprint: [String]? = nil) {
        guard started, diagnosticsEnabled else { return }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(sentryLevel(level))
            scope.setTag(value: osVersion, key: "os_version")
            scope.setTag(value: appVersion, key: "app_version")
            for (k, v) in tags { scope.setTag(value: v, key: k) }
            if !extra.isEmpty { scope.setExtras(extra) }
            if let fingerprint { scope.setFingerprint(fingerprint) }
        }
    }

    /// Record a Log() line as a Sentry breadcrumb so reports carry the recent trail. No-op until
    /// Sentry has started. Called from Log() (Log.swift). Scrubbing happens in `beforeBreadcrumb`.
    static func breadcrumb(_ message: String) {
        guard started else { return }
        let crumb = Breadcrumb(level: .info, category: "log")
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Report a caught error that we still want visibility into (one that doesn't crash the app).
    static func capture(_ error: Error) {
        guard started, diagnosticsEnabled else { return }
        SentrySDK.capture(error: error)
    }

    /// React to a mid-session flip of the opt-out switch (from Settings). Turning it on boots Sentry
    /// (release-only, via `start`); turning it off closes the SDK so nothing more is sent.
    static func applyEnabledChange() {
        if diagnosticsEnabled {
            start(.app)
        } else {
            SentrySDK.close()
            started = false
            Log("CrashReporting: diagnostics turned off — Sentry closed")
        }
    }

    // MARK: - Helpers

    private static func sentryLevel(_ l: DiagLevel) -> SentryLevel {
        switch l {
        case .info:    return .info
        case .warning: return .warning
        case .error:   return .error
        case .fatal:   return .fatal
        }
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    // MARK: - PII scrubber (backstop; capture clean at the source is the real defense)

    /// Redact the free-text fields of an outgoing event: the message, exception values, and any
    /// breadcrumb messages. Runs on the SDK transport thread — captures nothing MainActor-isolated.
    private static func scrub(_ event: Event) -> Event {
        if let formatted = event.message?.formatted {
            event.message = SentryMessage(formatted: scrub(text: formatted))
        }
        event.exceptions?.forEach { $0.value = scrub(text: $0.value) }
        event.breadcrumbs?.forEach { crumb in crumb.message = crumb.message.map(scrub(text:)) }
        return event
    }

    /// Redact home-dir paths, emails, phone numbers, and long token/base64 blobs from a string.
    private nonisolated static func scrub(text: String) -> String {
        var s = text
        for (re, replacement) in scrubbers {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                            withTemplate: replacement)
        }
        return s
    }

    /// Compiled once. Order matters (paths before the generic token rule).
    private static let scrubbers: [(NSRegularExpression, String)] = {
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        return [
            (re("/Users/[^/\\s\"']+"), "/Users/<redacted>"),                 // home-dir paths
            (re("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"), "<email>"),
            (re("\\+?\\d[\\d ()\\-]{7,}\\d"), "<phone>"),                     // 9+ digit runs w/ separators
            // Long tokens / base64 blobs — but ONLY high-entropy runs (≥1 uppercase or digit). This
            // spares snake_case identifiers like our own event names (`zero_sessions_despite_install`),
            // which a plain `{24,}` rule wrongly redacted. Real tokens/hashes always carry entropy.
            (re("(?=[A-Za-z0-9_\\-]{24,})[A-Za-z0-9_\\-]*[A-Z0-9][A-Za-z0-9_\\-]*"), "<token>"),
        ]
    }()
}
