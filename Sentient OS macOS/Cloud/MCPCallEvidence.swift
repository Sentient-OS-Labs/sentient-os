//
// MCPCallEvidence.swift
// Extracts successful MCP calls from the two CLI event streams. Source readers and direct
// action completion use the same receipt checks instead of trusting a model's success claim.
// Doc: Documentation - Cloud - CodexCLI (the codex exec spine).md
//

import Foundation

nonisolated enum MCPCallEvidence {
    static func claude(raw: String) -> Set<String> {
        var calls: [String: String] = [:]
        var successful = Set<String>()
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let message = event["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                if event["type"] as? String == "assistant", block["type"] as? String == "tool_use",
                   let id = block["id"] as? String, let name = block["name"] as? String { calls[id] = name }
                if event["type"] as? String == "user", block["type"] as? String == "tool_result",
                   let id = block["tool_use_id"] as? String, let name = calls[id],
                   block["content"] != nil, !(block["content"] is NSNull),
                   block["is_error"] as? Bool != true, block["isError"] as? Bool != true { successful.insert(name) }
            }
        }
        return successful
    }

    static func codex(raw: String) -> [(server: String?, tool: String, result: [String: Any])] {
        var replies: [(server: String?, tool: String, result: [String: Any])] = []
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  event["type"] as? String == "item.completed",
                  let item = event["item"] as? [String: Any], item["type"] as? String == "mcp_tool_call",
                  let name = item["tool"] as? String, item["status"] as? String == "completed",
                  item["error"] == nil || item["error"] is NSNull,
                  let result = item["result"] as? [String: Any],
                  result["content"] is [Any] || result["structured_content"] is [String: Any] || result["structuredContent"] is [String: Any],
                  result["isError"] as? Bool != true, result["is_error"] as? Bool != true else { continue }
            replies.append((server: item["server"] as? String, tool: name, result: result))
        }
        return replies
    }
}
