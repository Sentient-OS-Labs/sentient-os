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
//  Two hard gates decide whether ANYTHING reaches Sentry (Diagnostics/Documentation - Diagnostics (Sentry & TelemetryDeck).md):
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
//  Doc: Diagnostics/Documentation - Diagnostics (Sentry & TelemetryDeck).md
//

import Foundation
import Sentry
import Synchronization

nonisolated enum CrashReporting {

    /// The Sentry project DSN. NOT a secret — it can only write reports in, never read anything out —
    /// so it lives in source, public-facing, even when the repo goes open source.
    private static let dsn = "https://10ff4d2487c4913fcc9c61bd596bcf9f@o4511650390933504.ingest.us.sentry.io/4511651474636800"

    /// Which process this is, used as the `process` tag on every event.
    enum Role: String, Sendable {
        case app          // the normal GUI app
        case wakeHelper   // the root LaunchDaemon (main.swift --wake-helper branch)
    }

    /// Diagnostics severity — our own Sendable enum so the SDK type never crosses the call boundary.
    enum DiagLevel: String, Sendable { case info, warning, error, fatal }

    private struct State: Sendable {
        var started = false
        var role: Role = .app
        var helperConsent = false
        var helperConsentRevision = 0
        var helperInstallID: String?
    }
    private static let state = Mutex(State())
    private static var started: Bool {
        get { state.withLock { $0.started } }
        set { state.withLock { $0.started = newValue } }
    }

    // MARK: - Opt-out gate + anonymous identity

    private static let diagnosticsKey = "diagnosticsEnabled"
    private static let installIDKey = "diagnostics.installID"

    /// The opt-OUT switch: default ON, gates ALL Sentry. Off-main safe (UserDefaults is sync +
    /// thread-safe), so the off-main diagnostics call sites read it with no executor hop. Treats an
    /// unset key as ON (a bare `bool(forKey:)` returns false for a missing key → would read as off).
    nonisolated static var diagnosticsEnabled: Bool {
        if let consent = state.withLock({ $0.role == .wakeHelper ? $0.helperConsent : nil }) { return consent }
        let d = UserDefaults.standard
        if d.object(forKey: diagnosticsKey) == nil { return true }
        return d.bool(forKey: diagnosticsKey)
    }

    /// A random per-install id (minted once, kept in UserDefaults) — lets recurring faults on one
    /// machine correlate WITHOUT any account or link to a person. Never the mirror token, never
    /// hardware-derived; resets on reinstall / clear-data, which is fine (coarse correlation only).
    nonisolated static var installID: String {
        if let id = state.withLock({ $0.role == .wakeHelper ? $0.helperInstallID : nil }) { return id }
        let d = UserDefaults.standard
        if let existing = d.string(forKey: installIDKey), UUID(uuidString: existing) != nil { return existing }
        let id = UUID().uuidString
        d.set(id, forKey: installIDKey)
        return id
    }

    // MARK: - Boot

    /// Boot Sentry for this process — but only in RELEASE and only if diagnostics are on. Safe to call
    /// from either main.swift branch. In DEBUG this is a deliberate no-op.
    static func start(_ role: Role) {
        state.withLock { $0.role = role }
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
            // A distinct cache per role and anonymous identity prevents cross-user helper replay.
            options.cacheDirectoryPath = cacheDirectory.path
            options.shutdownTimeInterval = 0

            // Crashes: native signals + uncaught NSExceptions, with the full stack on every event.
            // ⚠️ NSException reporting DEFAULTS OFF on macOS (unlike iOS) — without the explicit
            // flag a whole class of AppKit/ObjC crashes never reached Sentry (found 2026-07-12).
            options.attachStacktrace = true
            options.enableCrashHandler = true
            options.enableUncaughtNSExceptionReporting = true

            // No APM: tracing/profiling stays at the OFF default. The SDK's auto transactions
            // never fire on a macOS SwiftUI app (measured: 0 ingested over the whole beta) — the
            // old 100% traces+profiling config was dead weight. Sentry is the smoke detector;
            // durations live in TelemetryDeck.

            // App-hang ("beachball") detection at 10s — NOT the SDK's 2s default: onboarding and
            // codex-install legs stall the main thread for a beat routinely, and 2s pages us with
            // unactionable noise (field-proven by the beta wave, 2026-07-12). Only a real freeze
            // should report. Auto session tracking is deliberately OFF: release-health sessions
            // are a "how many people use Sentient" signal, and ALL usage counting belongs to the
            // ANALYTICS toggle (TelemetryDeck), never the crash toggle.
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 10
            options.enableAutoSessionTracking = false

            // ⚠️ The SDK's URL-capturing defaults are a LEAK VECTOR and must stay OFF: network
            // breadcrumbs and failed-request capture both record full request URLs — and the MCP
            // mirror's URL carries the user's mirror password in its path (the §8 invariant:
            // request paths must NEVER be logged; locked down in the 2026-07-12 hardening pass).
            // The beforeBreadcrumb data scrub below is the backstop, not the defense.
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false

            options.environment = "release"

            // PII backstop (defense in depth — clean-at-source is the primary defense): scrub free
            // text on both outgoing events and Log()-fed breadcrumbs, on the SDK's transport thread.
            options.beforeSend = { event in diagnosticsEnabled ? scrub(event) : nil }
            options.beforeBreadcrumb = { crumb in
                guard diagnosticsEnabled else { return nil }
                crumb.message = crumb.message.map(scrub(text:))
                // SDK-authored crumbs carry their payload in `data`, not `message` (URLs live
                // here) — a message-only scrub would never see it, so scrub every string value
                // as the backstop.
                if let data = crumb.data {
                    crumb.data = scrubData(data)
                }
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

    private static var cacheDirectory: URL {
        let role = state.withLock { $0.role.rawValue }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SentientOS/diagnostics/" + role + "/" + installID, isDirectory: true)
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
                                         fingerprint: [String]? = nil,
                                         cooldown: TimeInterval = 900) {
        guard level != .info else { return } // successful-use signals belong to analytics
        let key = (fingerprint ?? [message]).joined(separator: ":") + ":" + (tags["source"] ?? "") + ":" + (tags["backend"] ?? "") + ":" + (tags["runtime"] ?? "")
        if let operation = Diagnostics.current, !operation.claim(key) { return }
        guard diagnosticsEnabled else { return }
        guard let suppressed = Diagnostics.claim(event: message, fingerprint: fingerprint, tags: tags, cooldown: cooldown) else { return }
        #if DEBUG
        Log("Diagnostic: \(message) phase=\(tags["phase"] ?? "unspecified") reason=\(tags["reason"] ?? "unspecified")")
        #endif
        guard started else { return }
        var details = extra
        if suppressed > 0 { details["suppressed_count"] = String(suppressed) }
        if let operation = Diagnostics.current {
            details["operation_id"] = operation.id
            if let parent = operation.parentID { details["parent_operation_id"] = parent }
            details["operation"] = operation.name
            details["operation_elapsed_ms"] = String(Int(Date().timeIntervalSince(operation.began) * 1000))
        }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(sentryLevel(level))
            scope.setTag(value: osVersion, key: "os_version")
            scope.setTag(value: appVersion, key: "app_version")
            for (k, v) in tags { scope.setTag(value: v, key: k) }
            if !details.isEmpty { scope.setExtras(details) }
            if let fingerprint { scope.setFingerprint(fingerprint) }
        }
    }

    /// Record a Log() line as a Sentry breadcrumb so reports carry the recent trail. No-op until
    /// Sentry has started. Called from Log() (Log.swift). Scrubbing happens in `beforeBreadcrumb`.
    static func breadcrumb(_ message: String) {
        guard started, diagnosticsEnabled else { return }
        let crumb = Breadcrumb(level: .info, category: "log")
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Report a caught error that we still want visibility into (one that doesn't crash the app).
    static func capture(_ error: Error) {
        Diagnostics.report(.serviceFailed, phase: .complete, reason: "caught_error", error: error)
    }

    /// React to a mid-session flip of the opt-out switch (from Settings). Turning it on boots Sentry
    /// (release-only, via `start`); turning it off closes the SDK so nothing more is sent.
    @MainActor static func applyEnabledChange() {
        WakeHelperClient.shared.syncDiagnosticsConsent()
        if diagnosticsEnabled {
            start(.app)
        } else {
            if started { SentrySDK.close(); started = false; try? FileManager.default.removeItem(at: cacheDirectory) }
            Log("CrashReporting: diagnostics turned off — Sentry closed")
        }
    }

    /// Root never reads its own default-on preference. Only a signed GUI client can supply consent.
    /// Kept in memory so helper restarts fail closed; the last choice covers its crash/deadman after GUI exit.
    @MainActor static func configureHelper(enabled: Bool, anonymousID: String, revision: Int = 0) {
        guard UUID(uuidString: anonymousID) != nil else { return }
        guard state.withLock({ value in
            guard value.role == .wakeHelper, revision >= value.helperConsentRevision else { return false }
            value.helperConsentRevision = revision; return true
        }) else { return }
        let changedIdentity = state.withLock { $0.helperInstallID != anonymousID }
        if changedIdentity && started { SentrySDK.close(); started = false }
        state.withLock { $0.helperConsent = enabled; $0.helperInstallID = anonymousID }
        if enabled { start(.wakeHelper) }
        else if started { SentrySDK.close(); started = false; try? FileManager.default.removeItem(at: cacheDirectory) }
    }

    @MainActor static func suspendHelper(revision: Int = 0) {
        guard state.withLock({ value in
            guard value.role == .wakeHelper, revision >= value.helperConsentRevision else { return false }
            value.helperConsentRevision = revision; return true
        }) else { return }
        state.withLock { $0.helperConsent = false }
        if started { SentrySDK.close(); started = false; try? FileManager.default.removeItem(at: cacheDirectory) }
    }

    /// Closed-name breadcrumbs for stage changes. Data must be structural, just like captureEvent.
    nonisolated static func diagnosticBreadcrumb(_ name: String, data: [String: String]) {
        guard started, diagnosticsEnabled else { return }
        let crumb = Breadcrumb(level: .info, category: "operation")
        crumb.message = name
        crumb.data = data
        SentrySDK.addBreadcrumb(crumb)
    }

    nonisolated static func scrubData(_ data: [String: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: data.map { key, value in
            let privateKeys: Set<String> = ["password", "token", "access_token", "refresh_token", "authorization", "secret", "api_key", "url", "path", "prompt", "output", "content"]
            if privateKeys.contains(key.lowercased()) { return (key, "<redacted>" as Any) }
            if let text = value as? String { return (key, scrub(text: text) as Any) }
            if let object = value as? [String: Any] { return (key, scrubData(object) as Any) }
            if let values = value as? [Any] { return (key, values.map { scrubData(["value": $0])["value"]! } as Any) }
            return (key, value)
        }).merging(data.filter { key, value in
            ["operation_id", "parent_operation_id"].contains(key) && (value as? String).flatMap(UUID.init(uuidString:)) != nil
        }) { _, safeID in safeID }
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
        event.tags = event.tags?.mapValues(scrub(text:))
        event.extra = event.extra.map(scrubData)
        event.context = event.context?.mapValues(scrubData)
        event.breadcrumbs?.forEach { crumb in
            crumb.message = crumb.message.map(scrub(text:))
            crumb.data = crumb.data.map(scrubData)
        }
        return event
    }

    /// Redact home-dir paths, emails, phone numbers, and long token/base64 blobs from a string.
    nonisolated static func scrub(text: String) -> String {
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
            (re("https?://[^\\s\"<>]+"), "<url>"),
            // Home-dir paths — redact the WHOLE remainder, not just the username: a folder name
            // ("…/Divorce lawyer/…") or filename ("…/Lab results.pdf") is exactly the PII we can't ship.
            (re("/Users/[^\\n\\r\"']+"), "/Users/<redacted>"),
            (re("/Volumes/[^\\n\\r\"']+"), "/Volumes/<redacted>"),              // custom roots on external volumes
            // The mirror password's URL path segment (/u_<id>/p_<password>/…) — the §8 invariant.
            // Network breadcrumbs are off, but ANY future surface that logs the share URL is
            // covered here by construction.
            (re("/p_[A-Za-z0-9_\\-]{8,}"), "/p_<redacted>"),
            (re("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"), "<email>"),
            (re("\\+?\\d[\\d ()\\-]{7,}\\d"), "<phone>"),                     // 9+ digit runs w/ separators
            // Long tokens / base64 blobs — but ONLY high-entropy runs (≥1 uppercase or digit). This
            // spares snake_case identifiers like our own event names (`zero_sessions_despite_install`),
            // which a plain `{24,}` rule wrongly redacted. Real tokens/hashes always carry entropy.
            (re("(?=[A-Za-z0-9_\\-]{24,})[A-Za-z0-9_\\-]*[A-Z0-9][A-Za-z0-9_\\-]*"), "<token>"),
        ]
    }()
}
