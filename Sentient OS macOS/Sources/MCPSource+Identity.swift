//
// MCPSource+Identity.swift
// Binds Codex Drive checkpoints to the connected account using the verified profile read.
// Only a local fingerprint is retained. Claude currently exposes no equivalent profile tool.
// Doc: Sources/Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation
import CryptoKit
import os

extension MCPSource {
    static func checkpointOrigin(slug: String, backend: ModelBackend, fingerprint: String?, fallback: String) -> String {
        let origin = fingerprint.map { "v2:\(backend.rawValue):account:\($0)" } ?? fallback
        // One successful bounded backfill upgrades old Notion checkpoints. The revision is
        // committed with the summaries, so failures retry and pending knowledge is preserved.
        return ConnectorRegistry.pack(forSlug: slug)?.slug == "notion" ? origin + ":notion-history-v1" : origin
    }

    static func readIdentity(slug: String, onReceipt: ReceiptObserver? = nil) async throws -> String? {
        if slug == OutlookCalendarConnector.slug { return try await OutlookCalendarConnector.readIdentity(onReceipt: onReceipt).fingerprint }
        if slug == OutlookMailConnector.slug { return try await OutlookMailConnector.readIdentity(onReceipt: onReceipt).fingerprint }
        if slug == "slack" { return try await SlackConnector.readIdentity(onReceipt: onReceipt).fingerprint }
        guard slug == "google-drive", ModelBackend.current == .chatgpt else { return nil }
        let prompt = """
        Discover Google Drive get_profile using tool search if it is not already visible,
        then call get_profile exactly once to verify the connected account. Tool discovery
        is allowed; do not call any other connector tool. Do not repeat profile data in your reply.
        Reply OK if it worked, AUTH if it requires sign-in or the connector is missing, or FAILED for any other failure.
        """
        for attempt in 1...2 {
            try Task.checkCancellation()
            var envelope: CodexCLI.Envelope?
            do {
                var inv = readInvocation(slug: slug, prompt: prompt)
                inv.mcpReadToolNames = ["get_profile"]
                inv.effort = .low
                inv.timeout = 60
                let result = try await FrontierRun.run(inv)
                envelope = result
                meter.withLock { values in
                    var total = values[slug] ?? (0, 0)
                    total.tokensIn += result.inputTokens ?? 0
                    total.tokensOut += result.outputTokens ?? 0
                    values[slug] = total
                }
                try Task.checkCancellation()
                let fingerprint: String?
                do { fingerprint = try profileFingerprint(raw: result.raw) }
                catch {
                    if result.result.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "AUTH" {
                        throw MCPError.connectorAuth(slug: slug)
                    }
                    throw error
                }
                onReceipt?(result, nil, attempt, prompt, "identity", [:])
                return fingerprint
            } catch {
                onReceipt?(envelope, nil, attempt, prompt, "identity_error", [:])
                try Task.checkCancellation()
                if error is CancellationError || ConnectorReadFailure.isConnectionFailure(error) { throw error }
                if case CodexCLI.CLIError.usageLimit = error { throw error }
                if case CodexCLI.CLIError.notAvailable = error { throw error }
                if attempt == 2 { throw error }
            }
        }
        throw MCPError.toolFailure(slug: slug)
    }

    /// Trust the actual successful tool result, never an account ID repeated by the model.
    /// A valid empty profile is an explicit unavailable identity; a missing call/invalid
    /// response is a failed read. Account changes between successful calls are refused.
    static func profileFingerprint(raw: String) throws -> String? {
        struct Profile: Decodable { let id: String?; let email: String?; let workspace_id: String? }
        struct Reply: Decodable { let result: Profile }
        func profile(_ value: Any) -> Profile? {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            if let wrapped = try? JSONDecoder().decode(Reply.self, from: data) { return wrapped.result }
            if let object = value as? [String: Any],
               Set(object.keys).isSubset(of: ["id", "email", "name", "nickname", "picture", "workspace_id", "workspace_name"]),
               object["id"] != nil || object["email"] != nil {
                return try? JSONDecoder().decode(Profile.self, from: data)
            }
            return nil
        }
        var identities = Set<String?>()
        for reply in successfulCodexMCPResults(raw: raw)
            where ["google_drive.get_profile", "gdrive.get_profile"].contains(reply.tool) {
            let result = reply.result
            var found = result["structuredContent"].flatMap(profile) ?? result["structured_content"].flatMap(profile)
            if found == nil, let blocks = result["content"] as? [[String: Any]] {
                for block in blocks {
                    if let text = block["text"] as? String, let bytes = text.data(using: .utf8),
                       let value = try? JSONSerialization.jsonObject(with: bytes), let decoded = profile(value) {
                        found = decoded; break
                    }
                }
            }
            guard let found else { throw MCPError.invalidResponse(slug: "google-drive", rule: "identity") }
            let id = found.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = found.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let stable = id.flatMap { $0.isEmpty ? nil : "id:" + $0 }
                ?? email.flatMap { $0.isEmpty ? nil : "email:" + $0 }
            let workspace = found.workspace_id?.trimmingCharacters(in: .whitespacesAndNewlines)
            let scoped = stable.map { account in
                workspace.flatMap { $0.isEmpty ? nil : account + "|workspace:" + $0 } ?? account
            }
            identities.insert(scoped.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() })
        }
        guard !identities.isEmpty else { throw MCPError.toolFailure(slug: "google-drive") }
        guard identities.count == 1 else { throw MCPError.connectionChanged }
        return identities.first!
    }
}
