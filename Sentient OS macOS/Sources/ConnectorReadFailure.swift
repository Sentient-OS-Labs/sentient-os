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
        let calls = MCPCallEvidence.receipts(raw: envelope.raw, backend: ModelBackend.current)
        guard !calls.contains(where: { $0.status == .succeeded }) else { return }
        let authMessages = ["invalid_grant", "invalid_token", "unauthenticated", "not connected",
                            "authentication required", "reauthentication required", "token expired",
                            "expired token", "sign in to", "please reconnect"]
        if calls.contains(where: { call in
            guard call.status == .failed, let data = call.output,
                  let text = String(data: data, encoding: .utf8)?.lowercased() else { return false }
            return authMessages.contains(where: text.contains)
        }) {
            throw MCPSource.MCPError.connectorAuth(slug: slug)
        }
    }
}
