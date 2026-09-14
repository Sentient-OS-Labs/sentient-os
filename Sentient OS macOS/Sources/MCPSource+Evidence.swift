//
// MCPSource+Evidence.swift
// Verifies a real successful Drive read before accepting a model's summary or quiet result.
// Matches Claude tool calls to results; Codex supplies completed MCP-call events directly.
// Doc: Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation

extension MCPSource {
    static func hasDriveReadEvidence(raw: String, backend: ModelBackend,
                                     requiresDiscovery: Bool) -> Bool {
        let reads: Set<String>
        let discovery: Set<String>
        switch backend {
        case .claude:
            let names = ConnectorRegistry.pack(forSlug: "google-drive")?.readTools ?? []
            let prefix = ConnectorRegistry.pack(forSlug: "google-drive")?.claudeToolPrefix ?? ""
            reads = Set(names.flatMap { [$0, prefix + $0] })
            discovery = Set(["search_files", "list_recent_files"].flatMap { [$0, prefix + $0] })
        case .chatgpt:
            let names = ConnectorRegistry.pack(forSlug: "google-drive")?.codexReadTools ?? []
            reads = Set(names.filter { $0 != "get_profile" }.flatMap { ["google_drive." + $0, "gdrive." + $0] })
            discovery = Set(["search", "recent_documents"].flatMap { ["google_drive." + $0, "gdrive." + $0] })
        case .custom:
            return false
        }
        let required = requiresDiscovery ? discovery : reads
        if backend == .chatgpt {
            return successfulCodexMCPResults(raw: raw).contains { required.contains($0.tool) }
        }
        var claudeCalls: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            guard let message = event["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                if event["type"] as? String == "assistant", block["type"] as? String == "tool_use",
                   let id = block["id"] as? String, let name = block["name"] as? String {
                    claudeCalls[id] = name
                }
                if event["type"] as? String == "user", block["type"] as? String == "tool_result",
                   let id = block["tool_use_id"] as? String, let name = claudeCalls[id],
                   required.contains(name), block["content"] != nil, !(block["content"] is NSNull),
                   block["is_error"] as? Bool != true, block["isError"] as? Bool != true {
                    return true
                }
            }
        }
        return false
    }

    /// Shared transport check for the content reader and account-identity probe.
    static func successfulCodexMCPResults(raw: String) -> [(tool: String, result: [String: Any])] {
        var replies: [(tool: String, result: [String: Any])] = []
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  event["type"] as? String == "item.completed",
                  let item = event["item"] as? [String: Any], item["type"] as? String == "mcp_tool_call",
                  let name = item["tool"] as? String, item["status"] as? String == "completed",
                  item["error"] == nil || item["error"] is NSNull,
                  let result = item["result"] as? [String: Any],
                  result["content"] is [Any] || result["structured_content"] is [String: Any]
                    || result["structuredContent"] is [String: Any],
                  result["isError"] as? Bool != true, result["is_error"] as? Bool != true else { continue }
            replies.append((tool: name, result: result))
        }
        return replies
    }
}
