// ConnectorReadFailure.swift
// Identifies unavailable connections from actual reads, shared by foreground and overnight runs.
// Connection failures leave read checkpoints untouched and are reported after the KB completes.
// Doc: Documentation - Sources - Cloud (Gmail, Calendar).md

import Foundation

enum ConnectorReadFailure {
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

    /// A failed tool call or an explicit failure result is different from a successful empty
    /// search. Never infer disconnection from an empty window or malformed model output.
    static func validate(_ envelope: CodexCLI.Envelope, slug: String) throws {
        if let data = envelope.jsonResult.data(using: .utf8),
           let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           result["tool_failure"] as? String == "auth" {
            throw MCPSource.MCPError.connectorAuth(slug: slug)
        }
        let backend = ModelBackend.current
        let calls = MCPCallEvidence.receipts(raw: envelope.raw, backend: backend)
        if calls.contains(where: { call in
            call.status == .failed && belongsToSource(call, slug: slug, backend: backend)
                && (authenticationFailure(call.failure) || authenticationFailure(call.output))
        }) {
            throw MCPSource.MCPError.connectorAuth(slug: slug)
        }
    }

    /// Successful discovery or WaitForMcpServers cannot excuse a later failed source read.
    /// Conversely, another source's failure must not label this connection as disconnected.
    private static func belongsToSource(_ call: MCPCallEvidence.Receipt, slug: String, backend: ModelBackend) -> Bool {
        let slug = ConnectorRegistry.canonicalSlug(slug)
        guard let pack = ConnectorRegistry.pack(forSlug: slug) else { return false }
        switch backend {
        case .claude:
            guard let prefix = pack.claudeToolPrefix, call.tool.hasPrefix(prefix) else { return false }
            return pack.readTools?.contains(String(call.tool.dropFirst(prefix.count))) == true
        case .chatgpt:
            guard call.server == "codex_apps" else { return false }
            let namespaces: [String]
            switch slug {
            case "gmail": namespaces = ["gmail"]
            case "google-calendar": namespaces = ["gcal", "google_calendar"]
            case "google-drive": namespaces = ["gdrive", "google_drive"]
            case "slack": namespaces = ["slack"]
            case "outlook-mail": namespaces = ["microsoft_outlook_email"]
            case "outlook-calendar": namespaces = ["microsoft_outlook_calendar"]
            default: return false
            }
            let prefixes: [String] = namespaces.flatMap { namespace -> [String] in
                let qualified = "mcp__codex_apps__" + namespace
                return [namespace + ".", qualified + "__", qualified + "_", qualified + "."]
            }
            guard let prefix = prefixes.first(where: call.tool.hasPrefix) else { return false }
            return pack.codexReadTools?.contains(String(call.tool.dropFirst(prefix.count))) == true
        case .custom: return false
        }
    }

    /// Inspect only native failure diagnostics, not arbitrary fields in email/event payloads.
    /// A successful message containing "please reconnect" is ordinary source content.
    nonisolated private static func authenticationFailure(_ data: Data?) -> Bool {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if authenticationDiagnostic(object) { return true }
        for key in ["structured_content", "structuredContent"] {
            if let value = object[key], authenticationDiagnostic(value) { return true }
        }
        if let text = object["content"] as? String { return authenticationDiagnostic(text) }
        let blocks = object["content"] as? [[String: Any]] ?? []
        return blocks.contains { block in
            block["type"] as? String == "text" && block["text"].map(authenticationDiagnostic) == true
        }
    }

    nonisolated private static func authenticationDiagnostic(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return ["error", "code", "message", "error_description", "status", "status_code", "http_status"]
                .contains { object[$0].map(authenticationDiagnostic) == true }
        }
        if let code = value as? Int { return code == 401 || code == 403 }
        guard let text = value as? String else { return false }
        // Error text sometimes wraps JSON. Decode diagnostic keys rather than searching
        // quoted subjects, bodies or other user-controlled fields inside that payload.
        if let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) {
            return authenticationDiagnostic(nested)
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
