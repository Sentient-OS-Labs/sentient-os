// ConnectorReadFailure.swift
// Identifies unavailable connections from actual reads, shared by foreground and overnight runs.
// Connection failures leave read checkpoints untouched and are reported after the KB completes.
// Doc: Documentation - Sources - Cloud (Gmail, Calendar).md

import Foundation

enum ConnectorReadFailure {
    enum GmailFailure: LocalizedError {
        case accountLimit, rateLimited
        var errorDescription: String? {
            switch self {
            case .accountLimit: "Gmail reached an account usage limit. Saved progress is retained; try again when the limit resets."
            case .rateLimited: "Gmail is temporarily limiting requests. Saved progress is retained; try again shortly."
            }
        }
    }

    static func isConnectionFailure(_ error: Error) -> Bool {
        switch error {
        case MCPSource.MCPError.connectorAuth,
             DirectMCPError.reconnectRequired, DirectMCPError.registrationExpired,
             DirectMCPError.accountSetupRequired, DirectMCPError.authorizationDenied,
             DirectMCPError.noTools:
            return true
        case DirectMCPError.http(let code): return code == 401 || code == 403
        default: return false
        }
    }

    /// The final reported outcome determines success. Native diagnostics only classify an
    /// explicitly reported failure; earlier tool errors never veto a completed summary.
    static func validate(_ envelope: CodexCLI.Envelope, slug: String) throws {
        guard let data = envelope.jsonResult.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let failure = result["tool_failure"] as? String, !failure.isEmpty else { return }
        let slug = ConnectorRegistry.canonicalSlug(slug)
        if failure == "auth" { throw MCPSource.MCPError.connectorAuth(slug: slug) }
        guard failure == "other" else { return } // The source decoder handles invalid schema values.
        let backend = ModelBackend.current
        let failures = MCPCallEvidence.receipts(raw: envelope.raw, backend: backend).filter {
            $0.status == .failed && belongsToSource($0, slug: slug, backend: backend)
        }
        if failures.contains(where: { call in
            // Gmail also uses HTTP 403 for quota. Do not mislabel a reported quota as OAuth.
            let providerLimit = slug == "gmail" && (isRateLimited(call) || isAccountLimited(call))
            return authenticationFailure(call.failure, ignoringForbidden: providerLimit)
                || authenticationFailure(call.output, ignoringForbidden: providerLimit)
        }) { throw MCPSource.MCPError.connectorAuth(slug: slug) }
        if slug == "gmail" {
            if failures.contains(where: isAccountLimited) { throw GmailFailure.accountLimit }
            if failures.contains(where: isRateLimited) { throw GmailFailure.rateLimited }
        }
        throw MCPSource.MCPError.toolFailure(slug: slug)
    }

    enum GmailRetry { case sourceRead, rateLimited, timeout }

    /// An explicit failed read may retry once without requiring native receipt evidence.
    /// Typed account/auth errors remain terminal; throttling gets a short bounded backoff.
    static func gmailRetry(_ error: Error) -> GmailRetry? {
        if case CodexCLI.CLIError.timedOut = error { return .timeout }
        if case GmailFailure.rateLimited = error { return .rateLimited }
        if case MCPSource.MCPError.toolFailure(let slug) = error, slug == "gmail" { return .sourceRead }
        return nil
    }

    nonisolated private static func isRateLimited(_ call: MCPCallEvidence.Receipt) -> Bool {
        failureDiagnostic(call.failure, matches: rateLimitDiagnostic)
            || failureDiagnostic(call.output, matches: rateLimitDiagnostic)
    }

    private static func isAccountLimited(_ call: MCPCallEvidence.Receipt) -> Bool {
        let diagnostics = [call.failure, call.output]
        // A daily/billing/account limit wins over a generic rate-limit wrapper. Google
        // also calls per-minute/per-second throttles "quota"; these may back off once.
        if diagnostics.contains(where: { failureDiagnostic($0, matches: accountLimitDiagnostic) }) { return true }
        guard diagnostics.contains(where: { failureDiagnostic($0, matches: quotaDiagnostic) }) else { return false }
        // A bare HTTP 429 does not prove that an otherwise unknown quota can recover.
        return !diagnostics.contains(where: { failureDiagnostic($0, matches: transientRateDiagnostic) })
    }

    nonisolated static func isOutputValidationFailure(_ error: Error) -> Bool {
        guard case CodexCLI.CLIError.exitFailure(_, let message) = error else { return false }
        return message.contains("StructuredOutput") && message.contains("does not match required schema")
    }

    /// Another source's error cannot classify this source's reported failure.
    private static func belongsToSource(_ call: MCPCallEvidence.Receipt, slug: String, backend: ModelBackend) -> Bool {
        sourceToolName(call, slug: slug, backend: backend) != nil
    }

    /// Match native diagnostic entries to the requested source without inspecting content.
    /// Tool naming is used for error classification only, never as a successful-read gate.
    static func sourceToolName(_ call: MCPCallEvidence.Receipt, slug: String, backend: ModelBackend) -> String? {
        let slug = ConnectorRegistry.canonicalSlug(slug)
        guard let pack = ConnectorRegistry.pack(forSlug: slug) else { return nil }
        switch backend {
        case .claude:
            guard let prefix = pack.claudeToolPrefix, call.tool.hasPrefix(prefix) else { return nil }
            let name = String(call.tool.dropFirst(prefix.count))
            return pack.readTools?.contains(name) == true ? name : nil
        case .chatgpt:
            guard call.server == "codex_apps" else { return nil }
            let namespaces: [String]
            switch slug {
            case "gmail": namespaces = ["gmail"]
            case "google-calendar": namespaces = ["gcal", "google_calendar"]
            case "google-drive": namespaces = ["gdrive", "google_drive"]
            case "slack": namespaces = ["slack"]
            case "outlook-mail": namespaces = ["microsoft_outlook_email"]
            case "outlook-calendar": namespaces = ["microsoft_outlook_calendar"]
            default: return nil
            }
            let prefixes: [String] = namespaces.flatMap { namespace -> [String] in
                let qualified = "mcp__codex_apps__" + namespace
                return [namespace + ".", qualified + "__", qualified + "_", qualified + "."]
            }
            guard let prefix = prefixes.first(where: call.tool.hasPrefix) else { return nil }
            let name = String(call.tool.dropFirst(prefix.count))
            return pack.codexReadTools?.contains(name) == true ? name : nil
        case .custom, .sentient: return nil
        }
    }

    /// Inspect only native failure diagnostics, not arbitrary fields in email/event payloads.
    /// A successful message containing "please reconnect" is ordinary source content.
    nonisolated private static func authenticationFailure(_ data: Data?, ignoringForbidden: Bool = false) -> Bool {
        failureDiagnostic(data) { authenticationDiagnostic($0, ignoringForbidden: ignoringForbidden) }
    }

    nonisolated private static func failureDiagnostic(_ data: Data?, matches: (Any) -> Bool) -> Bool {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if matches(object) { return true }
        for key in ["structured_content", "structuredContent"] {
            if let value = object[key], matches(value) { return true }
        }
        if let text = object["content"] as? String { return matches(text) }
        let blocks = object["content"] as? [[String: Any]] ?? []
        return blocks.contains { block in
            block["type"] as? String == "text" && block["text"].map(matches) == true
        }
    }

    nonisolated private static func quotaDiagnostic(_ value: Any) -> Bool {
        textDiagnostic(value) { diagnostic in
            ["quota", "usage limit", "usage_limit", "plan limit", "billing", "daily limit", "dailylimit"].contains(where: diagnostic.contains)
        }
    }

    nonisolated private static func accountLimitDiagnostic(_ value: Any) -> Bool {
        textDiagnostic(value) { diagnostic in
            ["insufficient_quota", "account usage limit", "account limit", "subscription limit", "plan limit", "billing",
             "daily limit", "dailylimit", "daily quota", "monthly limit", "monthly quota", "per day", "per_day", "per month"]
                .contains(where: diagnostic.contains)
        }
    }

    nonisolated private static func transientRateDiagnostic(_ value: Any) -> Bool {
        textDiagnostic(value) { diagnostic in
            ["ratelimitexceeded", "rate_limit_exceeded", "user_rate_limit_exceeded"].contains(where: diagnostic.contains)
                || (diagnostic.contains("quota") && ["per minute", "per second", "per_minute", "per_second"].contains(where: diagnostic.contains))
        }
    }

    /// Only diagnostic fields are traversed. Quoted provider quota names remain visible
    /// here because Google includes limits such as 'Queries per minute' in its message.
    nonisolated private static func textDiagnostic(_ value: Any, matches: (String) -> Bool) -> Bool {
        if let list = value as? [Any] { return list.contains { textDiagnostic($0, matches: matches) } }
        if let object = value as? [String: Any] {
            return ["error", "errors", "code", "reason", "message", "error_description", "status", "status_code", "http_status"]
                .contains { object[$0].map { textDiagnostic($0, matches: matches) } == true }
        }
        guard let text = value as? String else { return false }
        if let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) {
            return textDiagnostic(nested, matches: matches)
        }
        return matches(text.lowercased())
    }

    nonisolated private static func rateLimitDiagnostic(_ value: Any) -> Bool {
        if transientRateDiagnostic(value) { return true }
        if let list = value as? [Any] { return list.contains(where: rateLimitDiagnostic) }
        if let object = value as? [String: Any] {
            return ["error", "errors", "code", "reason", "message", "status", "status_code", "http_status"]
                .contains { object[$0].map(rateLimitDiagnostic) == true }
        }
        if let code = value as? Int { return code == 429 }
        guard let text = value as? String else { return false }
        if let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) {
            return rateLimitDiagnostic(nested)
        }
        let diagnostic = text.replacingOccurrences(of: #""(?:\\.|[^"\\])*"|'[^'\r\n]*'"#, with: " ", options: .regularExpression).lowercased()
        return diagnostic.range(of: #"\b(?:http(?: status)?\s*[:=]?\s*)?429\b"#, options: .regularExpression) != nil
            || ["rate_limit_exceeded", "rate limit", "ratelimitexceeded", "too many requests"].contains(where: diagnostic.contains)
    }

    nonisolated private static func authenticationDiagnostic(_ value: Any, ignoringForbidden: Bool = false) -> Bool {
        if let object = value as? [String: Any] {
            return ["error", "code", "message", "error_description", "status", "status_code", "http_status"]
                .contains { object[$0].map { authenticationDiagnostic($0, ignoringForbidden: ignoringForbidden) } == true }
        }
        if let code = value as? Int { return code == 401 || (code == 403 && !ignoringForbidden) }
        guard let text = value as? String else { return false }
        // Error text sometimes wraps JSON. Decode diagnostic keys rather than searching
        // quoted subjects, bodies or other user-controlled fields inside that payload.
        if let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) {
            return authenticationDiagnostic(nested, ignoringForbidden: ignoringForbidden)
        }
        let diagnostic = text.replacingOccurrences(of: #""(?:\\.|[^"\\])*"|'[^'\r\n]*'"#,
                                                   with: " ", options: .regularExpression).lowercased()
        let phrases = ["invalid_grant", "invalid_token", "unauthenticated", "unauthorized",
                       "authentication required", "reauthentication required", "token expired",
                       "expired token", "sign in to", "please reconnect"]
        return phrases.contains(where: diagnostic.contains)
            || (diagnostic.contains("not connected") && !diagnostic.contains("internet") && !diagnostic.contains("network"))
    }
}
