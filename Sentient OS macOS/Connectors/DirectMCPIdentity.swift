//
// DirectMCPIdentity.swift
// Interprets a provider's explicit account-info result without trusting model-generated identity.
// A missing/unrecognized result supplies no identity; grant generations still separate accounts.
//
// Doc: Documentation - Connectors (Direct MCP).md

import Foundation
import CryptoKit

nonisolated enum DirectMCPIdentity {
    struct Identity: Sendable { let fingerprint: String; let label: String }
    static func parse(_ data: Data?) -> Identity? {
        guard let data, let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var candidates: [[String: Any]] = []
        if let value = result["structuredContent"] as? [String: Any] { candidates.append(value) }
        if let blocks = result["content"] as? [[String: Any]] {
            for block in blocks {
                if let text = block["text"] as? String, let bytes = text.data(using: .utf8),
                   let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { candidates.append(value) }
            }
        }
        for candidate in candidates {
            // Notion's fetch(id: "self") wraps native workspace/user fields in `self`.
            let account = candidate["self"] as? [String: Any] ?? candidate
            let user = account["user"] as? [String: Any]
            guard let email = user?["email"] as? String ?? account["email"] as? String, email.contains("@"), email.count < 254,
                  !email.contains(where: { $0.isNewline }) else { continue }
            let workspace = account["workspace"] as? [String: Any] ?? account["active_workspace"] as? [String: Any]
            let workspaceID = workspace?["id"] as? String ?? account["workspace_id"] as? String
            let workspaceName = workspace?["name"] as? String ?? workspace?["display_name"] as? String ?? account["workspace_name"] as? String
            // Require an explicit workspace identity; email alone would miss a workspace switch.
            guard let workspaceID, !workspaceID.isEmpty, workspaceID.count < 256 else { continue }
            let userID = user?["id"] as? String ?? email.lowercased()
            guard !userID.isEmpty, userID.count < 256 else { continue }
            let key = userID + "\u{0}" + workspaceID
            let fingerprint = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            let name = workspaceName.flatMap { $0.count < 120 && !$0.contains(where: { $0.isNewline }) ? $0 : nil }
            return Identity(fingerprint: fingerprint, label: name.map { email + " · " + $0 } ?? email)
        }
        return nil
    }
}
