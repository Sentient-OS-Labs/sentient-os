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
        guard let data, let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              data.count <= 128_000, DirectMCPResult.errorState(result) == false,
              DirectMCPResult.hasValidStructuredContent(result) else { return nil }
        if let content = result["content"] {
            guard let blocks = content as? [[String: Any]], blocks.count <= 32,
                  blocks.allSatisfy({ block in
                      guard let type = block["type"] as? String else { return false }
                      return type == "text" ? block["text"] is String
                          : ["image", "audio", "resource", "resource_link"].contains(type)
                  }) else { return nil }
        }
        let candidates = DirectMCPResult.objects(result)
        guard candidates.allSatisfy({ $0["error"] == nil }) else { return nil }
        var identities: [Identity] = []
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
            identities.append(Identity(fingerprint: fingerprint, label: name.map { email + " · " + $0 } ?? email))
        }
        // A second distinct native identity is an account conflict, never an invitation
        // to pick the first text block. Equivalent structured/text mirrors remain valid.
        guard Set(identities.map(\.fingerprint)).count == 1 else { return nil }
        return identities.first
    }
}
