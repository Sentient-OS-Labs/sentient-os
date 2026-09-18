//
//  CodexDiagnostics.swift
//  Sentient OS macOS
//
//  The structure-only "why" behind a codex failure. Sentry only ever received the CLIError CASE
//  name (`notAvailable`, `exitFailure`), which turned every dead 3 AM cloud stage into a mystery
//  (Aug 2026 triage: 861 `notAvailable` events / 196 users, per-Mac chronic, unexplained). These
//  four small types give every codex.failure a closed-vocabulary reason, a trigger, and the
//  login/network conditions at the moment it failed — never a byte of codex output, prompt,
//  token, or account id.
//
//   - CodexFailureReason   → closed enum classified from codex's stderr/JSONL error text; the
//                            text stays on the Mac, only the enum's rawValue is reported.
//   - CodexTrigger         → task-local "who started this cloud work" (overnight / analyze_now /
//                            onboarding / probe / sidekick / card), set once by each driver and
//                            inherited by every child task, so a failure can be attributed
//                            without threading a parameter through every call.
//   - CodexAuthSnapshot    → what ~/.codex/auth.json says right now: auth mode, plan, whether
//                            the access token's `exp` claim has passed, minutes since codex last
//                            refreshed. Key presence + JWT claims only; no token bytes.
//   - NetworkSnapshot      → one process-wide NWPathMonitor, read synchronously: satisfied /
//                            unsatisfied + the interface family.
//
//  Everything here is `nonisolated`: the project defaults to MainActor isolation, and these are
//  read from the CodexCLI actor and background tasks with no reason to hop.
//
//  Doc: Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md
//

import Foundation
import Network
import os

// MARK: - Failure reason (closed vocabulary)

/// Why a codex call failed, as a fixed enum. `classify` maps a CLIError plus whatever text codex
/// left behind onto one case; the text itself never leaves the Mac. Order of the checks matters:
/// the specific families (usage limit, plan, model, DNS, TLS) win over the generic ones
/// (403, connect, unknown).
nonisolated enum CodexFailureReason: String, Sendable {
    case notInstalled     = "not_installed"
    case notLoggedIn      = "not_logged_in"
    case tokenExpired     = "login_expired"   // "token_*" would be redacted server-side
    case refreshFailed    = "refresh_failed"
    case planDenied       = "plan_denied"
    case modelNotFound    = "model_not_found"
    case usageLimit       = "usage_limit"
    case dns              = "dns"
    case connectTimeout   = "connect_timeout"
    case tls              = "tls"
    case http403          = "http_403"
    case http5xx          = "http_5xx"
    case streamDisconnect = "stream_disconnect"
    case staleClient      = "stale_client"
    case sandboxDenied    = "sandbox_denied"
    case spawnFailed      = "spawn_failed"
    case timeoutOurs      = "timeout_ours"
    case unknown          = "unknown"

    /// Classify a typed spine error. Typed cases are certain; `notAvailable(.notWorking(detail))`,
    /// `exitFailure(_, message)` and `badEnvelope(message)` fall through to the text classifier.
    static func classify(_ error: Error) -> CodexFailureReason {
        switch error {
        case CodexCLI.CLIError.notAvailable(.notInstalled):          return .notInstalled
        case CodexCLI.CLIError.notAvailable(.notWorking(let d)):     return classify(text: d)
        case CodexCLI.CLIError.notAvailable(.available):             return .unknown
        case CodexCLI.CLIError.timedOut:                             return .timeoutOurs
        case CodexCLI.CLIError.launchFailed:                         return .spawnFailed
        case CodexCLI.CLIError.usageLimit:                           return .usageLimit
        case CodexCLI.CLIError.staleClient:                          return .staleClient
        case CodexCLI.CLIError.exitFailure(_, let m):                return classify(text: m)
        case CodexCLI.CLIError.badEnvelope(let m):                   return classify(text: m)
        case CodexCLI.CLIError.inputTooLarge:                        return .unknown   // its own canary case
        default:                                                     return classify(text: "\(error)")
        }
    }

    /// Classify free text (codex stderr, a JSONL error message, our own error description). Pure
    /// substring rules on the lowercased text; the text is consumed here and dropped.
    static func classify(text: String) -> CodexFailureReason {
        let t = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { t.contains($0) } }
        /// An HTTP status code as its own number (not "1500 chars" or a port).
        func code(_ codes: Int...) -> Bool {
            codes.contains { c in
                t.range(of: "(^|[^0-9])\(c)([^0-9]|$)", options: .regularExpression) != nil
            }
        }

        // Our own wall clock, not codex's.
        if has("timed out after", "timeoutours") { return .timeoutOurs }
        // Quota first — its wording overlaps "limit"/"plan". The "hit your …" family is Claude's
        // subscription-window wording ("You've hit your session limit · resets 3:45pm").
        if has("usage limit", "rate limit", "limit reached", "limit resets", "quota",
               "too many requests", "out of extra usage", "plan limit",
               "hit your session limit", "hit your weekly limit", "hit your opus limit",
               "out of credits", "credit balance") || code(429) { return .usageLimit }
        // Login state.
        if has("token expired", "token has expired", "expired token", "access token expired",
               "token_expired", "jwt expired") { return .tokenExpired }
        if has("refresh") && has("fail", "reject", "invalid_grant", "revoked") { return .refreshFailed }
        if has("not logged in", "please log in", "please login", "codex login", "login required",
               "no credentials", "not authenticated", "unauthenticated", "unauthorized",
               "invalid api key", "incorrect api key", "invalid_grant", "invalid_api_key") || code(401) { return .notLoggedIn }
        // Entitlement / model.
        if has("not available for your plan", "not available on your plan", "your plan",
               "insufficient_quota", "insufficient quota", "not entitled", "entitlement",
               "upgrade to", "requires chatgpt plus", "requires a paid", "model_not_available") { return .planDenied }
        if has("model_not_found", "does not exist", "unknown model", "unsupported model",
               "no such model", "not a valid model", "invalid model") { return .modelNotFound }
        // Network, specific → generic.
        if has("dns error", "failed to lookup address", "nodename nor servname",
               "could not resolve", "name resolution", "temporary failure in name",
               "no such host") { return .dns }
        if has("tls", "ssl", "certificate", "handshake") { return .tls }
        if has("stream disconnected", "stream error", "reconnecting", "unexpected eof",
               "unexpected end of stream", "connection closed before", "incomplete message",
               "body error", "stream ended") { return .streamDisconnect }
        if has("connection refused", "refused", "network is unreachable", "no route to host",
               "error sending request", "connection reset", "failed to connect",
               "connect timed out", "connection timed out", "operation timed out",
               "os error 60", "os error 61", "os error 64", "os error 65",
               "client error (connect)", "connect error") { return .connectTimeout }
        // HTTP families (after plan/model so a wordy 403 lands in the specific bucket).
        if has("forbidden", "unsupported_country", "unsupported country",
               "unsupported region", "not available in your country",
               "not available in your region") || code(403) { return .http403 }
        if has("internal server error", "bad gateway", "service unavailable", "gateway timeout",
               "overloaded", "server_error") || code(500, 502, 503, 504) { return .http5xx }
        // Local execution.
        if has("sandbox", "seatbelt", "operation not permitted") { return .sandboxDenied }
        if has("stale", "cache schema", "schema mismatch") { return .staleClient }
        if has("no such file", "permission denied", "exec format", "spawn") { return .spawnFailed }
        return .unknown
    }
}

// MARK: - Trigger (task-local)

/// Who started the cloud work a codex call belongs to. Each driver sets it once with
/// `CodexTrigger.$current.withValue(...)`; every `Task {}` spawned inside inherits it (detached
/// tasks do not, by design). Read by CodexCLI when it reports a failure, so overnight failures,
/// onboarding-time failures, and a Sidekick press each get their own fingerprint.
nonisolated enum CodexTrigger: String, Sendable {
    case overnight
    case analyzeNow = "analyze_now"
    case onboarding
    case probe
    case sidekick
    case card
    case unknown

    @TaskLocal static var current: CodexTrigger = .unknown
}

// MARK: - Auth snapshot (~/.codex/auth.json, keys + claims only)

/// What codex's own login file says right now. Every field is an enum/bool/int — the file's
/// values (tokens, key, account id) are read only to test presence and decode the JWT `exp`
/// claim, then discarded.
nonisolated struct CodexAuthSnapshot: Sendable {
    enum Mode: String, Sendable { case chatgpt, key, none, unreadable }   // "key" not "apikey": the latter is a scrubber word

    let mode: Mode
    let plan: String                 // "plus" / "free" / … / "unknown" — the raw claim, lowercased
    let accessExpired: Bool?         // nil = no decodable access token
    let hasRefreshToken: Bool
    let minutesSinceRefresh: Int?    // from `last_refresh`; nil when absent/unparseable

    /// Read the file once. Cheap (a small JSON), synchronous, safe from any executor.
    static func read() -> CodexAuthSnapshot {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CodexAuthSnapshot(mode: .none, plan: "unknown", accessExpired: nil,
                                     hasRefreshToken: false, minutesSinceRefresh: nil)
        }
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return CodexAuthSnapshot(mode: .unreadable, plan: "unknown", accessExpired: nil,
                                     hasRefreshToken: false, minutesSinceRefresh: nil)
        }
        let tokens = root["tokens"] as? [String: Any]
        let access = tokens?["access_token"] as? String
        let refresh = tokens?["refresh_token"] as? String
        let apiKey = root["OPENAI_API_KEY"] as? String
        let declared = (root["auth_mode"] as? String)?.lowercased()

        let mode: Mode
        if declared == "chatgpt" || (access?.isEmpty == false && declared != "apikey") { mode = .chatgpt }
        else if declared == "apikey" || apiKey?.isEmpty == false { mode = .key }
        else { mode = .none }

        let plan = (CodexAuth.currentPlan()?.raw.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"

        var expired: Bool?
        if let access, let exp = jwtExpiry(access) { expired = exp < Date() }

        var mins: Int?
        if let s = root["last_refresh"] as? String, let d = Self.parseISO(s) {
            mins = max(0, Int(Date().timeIntervalSince(d) / 60))
        }
        return CodexAuthSnapshot(mode: mode, plan: plan, accessExpired: expired,
                                 hasRefreshToken: refresh?.isEmpty == false, minutesSinceRefresh: mins)
    }

    /// The `exp` claim of a JWT's payload segment (base64url, no signature check — we're reading
    /// our own user's token off their own disk to learn ONE timestamp).
    private static func jwtExpiry(_ jwt: String) -> Date? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var b64 = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let payload = Data(base64Encoded: b64),
              let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let exp = claims["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// The tag values Sentry gets (all enums/bools/ints as strings).
    var tags: [String: String] {
        ["login_mode": mode.rawValue,     // not "auth_*": Sentry's server-side scrubber redacts keys/values containing auth/token/session
         "plan": plan,
         "access_expired": accessExpired.map { String($0) } ?? "unknown"]
    }
    var extras: [String: String] {
        ["has_refresh": String(hasRefreshToken),
         "mins_since_last_refresh": minutesSinceRefresh.map(String.init) ?? "n/a"]
    }
    /// One breadcrumb line — the vocabulary deliberately avoids the words Sentry's server-side
    /// scrubber redacts wholesale (token / auth / session / secret).
    var logLine: String {
        "codex signin: mode=\(mode.rawValue) plan=\(plan) expired=\(accessExpired.map { String($0) } ?? "unknown") refreshed=\(minutesSinceRefresh.map { "\($0)min ago" } ?? "n/a")"
    }
}

// MARK: - Network snapshot (one process-wide monitor)

/// The current network path, readable synchronously from anywhere. One `NWPathMonitor` for the
/// process, started lazily on first read (and eagerly at launch by AppState so the first read
/// after a wake isn't "unknown"). Values are the two tag strings codex.failure reports.
nonisolated final class NetworkSnapshot: @unchecked Sendable {   // the monitor is only touched under `started`; readings ride the lock
    static let shared = NetworkSnapshot()

    struct Reading: Sendable {
        let status: String      // satisfied · unsatisfied · requires_connection · unknown
        let interface: String   // wifi · wired · cellular · other · none
    }

    private let monitor = NWPathMonitor()
    private let latest = OSAllocatedUnfairLock<Reading?>(initialState: nil)
    private let started = OSAllocatedUnfairLock(initialState: false)

    private init() {}

    /// Start listening (idempotent). Called from AppState at launch; `current` also calls it.
    func start() {
        let first = started.withLock { s -> Bool in if s { return false }; s = true; return true }
        guard first else { return }
        monitor.pathUpdateHandler = { [latest] path in
            latest.withLock { $0 = Self.reading(path) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    /// The latest reading, or "unknown/none" before the first path update arrives.
    var current: Reading {
        start()
        return latest.withLock { $0 } ?? Reading(status: "unknown", interface: "none")
    }

    private static func reading(_ path: NWPath) -> Reading {
        let status: String
        switch path.status {
        case .satisfied:          status = "satisfied"
        case .unsatisfied:        status = "unsatisfied"
        case .requiresConnection: status = "requires_connection"
        @unknown default:         status = "unknown"
        }
        let interface: String
        if path.usesInterfaceType(.wifi) { interface = "wifi" }
        else if path.usesInterfaceType(.wiredEthernet) { interface = "wired" }
        else if path.usesInterfaceType(.cellular) { interface = "cellular" }
        else if path.status == .satisfied { interface = "other" }
        else { interface = "none" }
        return Reading(status: status, interface: interface)
    }
}
