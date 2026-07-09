//
//  CodexAuth.swift
//  Sentient OS macOS
//
//  ChatGPT plan identity, read from the user's own codex login (~/.codex/auth.json).
//  The file's OAuth tokens are JWTs whose claims carry `chatgpt_plan_type` — so the app can
//  tell a free/go account (tiny MONTHLY codex quota, no Gmail/Calendar connectors) from a
//  plus/pro one without any network call. Codex itself only re-mints the token every 8 days,
//  so `refreshPlan()` replays codex's own refresh POST on demand (same endpoint, same public
//  client id, same faithful write-back — rotated refresh_token honored, `last_refresh` reset,
//  every other key preserved, atomic replace). After our refresh, auth.json is indistinguishable
//  from a codex-native one. Verified live end-to-end (refresh → login status → real exec) 2026-07-08.
//
//  Key methods:
//   - currentPlan()          → decode the plan claim from auth.json (pure file read, no network)
//   - refreshPlan()          → the on-demand refresh POST + write-back → the FRESH plan
//   - knowledgeBaseOnly      → the persisted "free user chose to continue anyway" mode flag
//
//  Fail-open policy: no file / no tokens / unknown plan string → treated as full. Worst case a
//  limited account hits codex usage-limit errors, which every caller already survives (typed
//  errors + resume handles). Only a POSITIVE free/go read gates anything.
//

import Foundation

enum CodexAuth {

    // MARK: Plan

    /// Plans that can't run Sentient fully: tiny MONTHLY codex quota (the initial knowledge-base
    /// build alone eats ~70% of it) and no ChatGPT connectors (Gmail/Calendar). Everything else —
    /// plus, pro, prolite, team, business, edu, enterprise, and any future string — is full.
    enum Tier: Sendable, Equatable {
        case full
        case limited
    }

    struct Plan: Sendable, Equatable {
        /// The raw `chatgpt_plan_type` claim ("plus", "free", "go", "pro", "prolite", …).
        let raw: String

        var tier: Tier { ["free", "go"].contains(raw.lowercased()) ? .limited : .full }

        /// For UI ("Plus", "Free", "Go"…). Unknown strings just get capitalized.
        var displayName: String { raw.prefix(1).uppercased() + raw.dropFirst() }
    }

    /// The ChatGPT pricing page — where the crossroads screen and every upsell surface send users.
    static let upgradeURL = URL(string: "https://chatgpt.com/#pricing")!

    /// The hover notice on locked Gmail/Calendar chips (knowledge-base-only mode) — shared by
    /// every surface that shows them, so the wording never drifts.
    static let connectorLockedTip = "Only supported on ChatGPT Plus"

    // MARK: Persisted state

    /// The user is a free/go account who chose "continue with just the knowledge base" in
    /// onboarding. THE gate every limited-mode surface checks (scheduler auto-enable, Sidekick
    /// arming, proactive stages, connector chips, the home's preview state).
    static let kbOnlyKey = "plan.kbOnly"
    static var knowledgeBaseOnly: Bool {
        get { UserDefaults.standard.bool(forKey: kbOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: kbOnlyKey) }
    }

    /// Server-supplied refresh throttle (the POST answers `earliest_refresh_at`) — respected so
    /// focus-return re-checks can never hammer the endpoint.
    private static let earliestRefreshKey = "plan.earliestRefresh"

    // MARK: Read (no network)

    private static var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    /// Decode the plan from auth.json's JWT claims. Pure file read — safe to call every launch,
    /// every cycle. Returns nil when it can't know (no file, API-key-only auth, undecodable) —
    /// callers treat nil as full (fail open).
    static func currentPlan() -> Plan? {
        guard let data = try? Data(contentsOf: authURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any] else { return nil }
        // id_token first (the one codex itself parses for plan display), access_token as backstop.
        for key in ["id_token", "access_token"] {
            if let jwt = tokens[key] as? String,
               let plan = planClaim(fromJWT: jwt) { return Plan(raw: plan) }
        }
        return nil
    }

    /// True only on a POSITIVE free/go read — the convenience most gates want.
    static func isLimited() -> Bool { currentPlan()?.tier == .limited }

    /// Extract `chatgpt_plan_type` from a JWT's payload segment (base64url, no signature check —
    /// we're reading our own user's token off their own disk, not authenticating anyone).
    private static func planClaim(fromJWT jwt: String) -> String? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var b64 = segments[1].replacingOccurrences(of: "-", with: "+")
                             .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let payload = Data(base64Encoded: b64),
              let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_plan_type"] as? String
    }

    // MARK: Refresh (the on-demand plan re-check)

    enum AuthError: Error, CustomStringConvertible {
        case notLoggedIn                    // no auth.json / no refresh_token to present
        case refreshRejected(String)        // the server said no (expired/reused/revoked token)
        case network(String)

        var description: String {
            switch self {
            case .notLoggedIn:              return "Not logged in to codex"
            case .refreshRejected(let m):   return "Token refresh rejected: \(m.prefix(200))"
            case .network(let m):           return "Token refresh failed: \(m.prefix(200))"
            }
        }
    }

    /// Codex's own public OAuth client id (codex-rs `login/src/auth/manager.rs`).
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!

    /// One in-flight refresh at a time — a second concurrent POST would present an
    /// already-rotated refresh token and brick the user's codex login.
    @MainActor private static var inFlight: Task<Plan?, Error>?

    /// Re-mint the tokens NOW (instead of codex's 8-day timer) and return the fresh plan —
    /// how "I've upgraded" gets verified. Single-flight; honors the server's
    /// `earliest_refresh_at` throttle by returning the current claim without a network call.
    @MainActor
    static func refreshPlan() async throws -> Plan? {
        if let inFlight { return try await inFlight.value }
        let task = Task<Plan?, Error> { try await performRefresh() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private static func performRefresh() async throws -> Plan? {
        // The server told us when the next refresh is allowed — before that, the claim on disk
        // is as fresh as a POST would mint anyway.
        let earliest = UserDefaults.standard.double(forKey: earliestRefreshKey)
        if Date().timeIntervalSince1970 < earliest { return currentPlan() }

        guard let data = try? Data(contentsOf: authURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let refreshToken = tokens["refresh_token"] as? String else {
            throw AuthError.notLoggedIn
        }

        var request = URLRequest(url: refreshEndpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])

        let body: Data, status: Int
        do {
            let (d, response) = try await URLSession.shared.data(for: request)
            body = d
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw AuthError.network("\(error)")
        }
        guard (200..<300).contains(status),
              let fresh = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            let detail = String(data: body, encoding: .utf8) ?? "HTTP \(status)"
            emitRefreshFailed(status: status)
            throw AuthError.refreshRejected(detail)
        }

        try writeBack(fresh, into: root)

        if let next = earliestRefreshDate(from: fresh["earliest_refresh_at"]) {
            UserDefaults.standard.set(next.timeIntervalSince1970, forKey: earliestRefreshKey)
        }
        return currentPlan()
    }

    /// The faithful write-back: only the fields the server returned, every other key preserved,
    /// `last_refresh` reset (so codex's 8-day timer restarts, exactly like a native refresh),
    /// 0600 permissions, atomic replace. Success-only — a failed POST never touches the file.
    private static func writeBack(_ fresh: [String: Any], into root: [String: Any]) throws {
        var updated = root
        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        for key in ["id_token", "access_token", "refresh_token"] {
            if let value = fresh[key] as? String { tokens[key] = value }
        }
        updated["tokens"] = tokens

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        updated["last_refresh"] = stamp.string(from: Date())

        let out = try JSONSerialization.data(withJSONObject: updated,
                                             options: [.prettyPrinted, .withoutEscapingSlashes])
        let tmp = authURL.deletingLastPathComponent()
            .appendingPathComponent("auth.json.sentient-\(UUID().uuidString.prefix(8))")
        try out.write(to: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(authURL, withItemAt: tmp)
    }

    /// `earliest_refresh_at` arrives as epoch seconds or an ISO string depending on the server's
    /// mood — accept both, ignore anything else.
    private static func earliestRefreshDate(from value: Any?) -> Date? {
        switch value {
        case let seconds as Double: return Date(timeIntervalSince1970: seconds)
        case let seconds as Int:    return Date(timeIntervalSince1970: Double(seconds))
        case let iso as String:
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        default: return nil
        }
    }

    /// §7.9-style structured signal — status code only, never token material or response bodies.
    private static func emitRefreshFailed(status: Int) {
        CrashReporting.captureEvent("codex_auth.refresh_failed", level: .warning,
            tags: ["status": String(status)],
            extra: [:], fingerprint: ["codex_auth", "refresh_failed"])
    }
}
