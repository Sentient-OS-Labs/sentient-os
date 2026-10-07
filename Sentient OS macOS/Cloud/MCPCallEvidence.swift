//
// MCPCallEvidence.swift
// Extracts successful MCP calls from the two CLI event streams. Source readers and direct
// action completion use the same receipt checks instead of trusting a model's success claim.
// Doc: Documentation - Cloud - CodexCLI (the codex exec spine).md
//

import Foundation

nonisolated enum MCPCallEvidence {
    /// A provider call, including unfinished and failed attempts. Payloads stay in memory;
    /// callers may decode them for scope and outcome checks, but must never log them.
    struct Receipt: Sendable {
        enum Status: Sendable { case pending, succeeded, failed }
        let id: String
        let server: String?
        let tool: String
        let arguments: Data?
        let output: Data?
        let status: Status
        /// Native transport failures can live outside the MCP result (Codex's item.error).
        /// Keep that diagnostic separate from provider content and successful read evidence.
        var failure: Data? = nil
    }

    static func receipts(raw: String, backend: ModelBackend) -> [Receipt] {
        switch backend {
        case .claude: claudeReceipts(raw: raw)
        case .chatgpt: codexReceipts(raw: raw)
        case .custom: []
        }
    }

    private static func json(_ value: Any?) -> Data? {
        guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func arguments(_ value: Any?) -> Data? {
        if let text = value as? String, let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return json(object) }
        guard value is [String: Any] else { return nil }
        return json(value)
    }

    private static func events(_ raw: String) -> [[String: Any]] {
        raw.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    private static func claudeReceipts(raw: String) -> [Receipt] {
        var order: [String] = []
        var calls: [String: Receipt] = [:]
        var invalid = Set<String>()
        for event in events(raw) {
            guard let message = event["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                if event["type"] as? String == "assistant", block["type"] as? String == "tool_use",
                   let id = block["id"] as? String, !id.isEmpty,
                   let name = block["name"] as? String, !name.isEmpty {
                    let input = arguments(block["input"])
                    if let old = calls[id] {
                        if old.tool != name || old.arguments != input { invalid.insert(id) }
                        continue
                    }
                    order.append(id)
                    calls[id] = Receipt(id: id, server: nil, tool: name, arguments: input,
                                        output: nil, status: .pending)
                }
                if event["type"] as? String == "user", block["type"] as? String == "tool_result",
                   let id = block["tool_use_id"] as? String, let call = calls[id] {
                    let output = json(block)
                    if call.status != .pending {
                        if call.output != output { invalid.insert(id) }
                        continue
                    }
                    let hasContent = block["content"] != nil && !(block["content"] is NSNull)
                    let success = hasContent && block["is_error"] as? Bool != true
                        && block["isError"] as? Bool != true
                    calls[id] = Receipt(id: id, server: nil, tool: call.tool, arguments: call.arguments,
                                        output: output, status: success ? .succeeded : .failed)
                }
            }
        }
        return order.compactMap { id in
            guard let call = calls[id] else { return nil }
            return invalid.contains(id)
                ? Receipt(id: id, server: nil, tool: call.tool, arguments: call.arguments, output: nil, status: .failed)
                : call
        }
    }

    private static func codexReceipts(raw: String) -> [Receipt] {
        var order: [String] = []
        var calls: [String: Receipt] = [:]
        var invalid = Set<String>()
        for (index, event) in events(raw).enumerated() {
            guard let type = event["type"] as? String,
                  ["item.started", "item.updated", "item.completed"].contains(type),
                  let item = event["item"] as? [String: Any], item["type"] as? String == "mcp_tool_call",
                  let name = item["tool"] as? String, !name.isEmpty else { continue }
            let id = item["id"] as? String ?? "event-\(index)"
            let server = item["server"] as? String
            let input = arguments(item["arguments"])
            let output = json(item["result"])
            let failure = item["error"].flatMap { $0 is NSNull ? nil : json(["error": $0]) }
            if let old = calls[id] {
                if old.tool != name || old.server != server
                    || (old.arguments != nil && input != nil && old.arguments != input) {
                    invalid.insert(id)
                }
                if old.status != .pending {
                    if type == "item.completed", old.output != output || old.failure != failure { invalid.insert(id) }
                    continue
                }
            } else { order.append(id) }
            let result = item["result"] as? [String: Any]
            let hasResult = result?["content"] is [Any] || result?["structured_content"] is [String: Any]
                || result?["structuredContent"] is [String: Any]
            let success = item["status"] as? String == "completed"
                && (item["error"] == nil || item["error"] is NSNull) && hasResult
                && result?["isError"] as? Bool != true && result?["is_error"] as? Bool != true
            calls[id] = Receipt(id: id, server: server, tool: name, arguments: input ?? calls[id]?.arguments,
                output: output, status: type == "item.completed" ? (success ? .succeeded : .failed) : .pending,
                failure: failure)
        }
        return order.compactMap { id in
            guard let call = calls[id] else { return nil }
            return invalid.contains(id)
                ? Receipt(id: id, server: call.server, tool: call.tool, arguments: call.arguments, output: nil, status: .failed)
                : call
        }
    }

    static func claude(raw: String) -> Set<String> {
        Set(claudeReceipts(raw: raw).filter { $0.status == .succeeded }.map(\.tool))
    }

    static func codex(raw: String) -> [(server: String?, tool: String, result: [String: Any])] {
        codexReceipts(raw: raw).compactMap { call in
            guard call.status == .succeeded, let output = call.output,
                  let result = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else { return nil }
            return (server: call.server, tool: call.tool, result: result)
        }
    }
}
