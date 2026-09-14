//
// DirectMCPProbe.swift
// Performs the native MCP handshake and captures a complete, bounded tool inventory.
// The same metadata feeds policy validation; optional account calls establish workspace identity.
//
// Doc: Documentation - Connectors (Direct MCP).md

import Foundation

nonisolated enum DirectMCPProbe {
    static func initializeBody(id: Int) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "initialize", "params": [
            "protocolVersion": "2025-11-25", "capabilities": [:],
            "clientInfo": ["name": "Sentient OS", "version": "2"]]]
    }

    static func tools(connection: DirectMCPConnection) async throws -> [DirectMCPTool] {
        try await capture(connection: connection).tools
    }
    struct Snapshot: Sendable { let tools: [DirectMCPTool]; let account: Data? }

    static func capture(connection: DirectMCPConnection, includeAccount: Bool = false) async throws -> Snapshot {
        func checkGeneration() throws {
            guard DirectMCPStore.connection(id: connection.id)?.generation == connection.generation else {
                throw DirectMCPError.connectionChanged
            }
        }
        try checkGeneration()
        guard let provider = connection.provider else { throw DirectMCPError.unsupportedProvider }
        let token = try await DirectMCPAuth.accessToken(id: connection.id, generation: connection.generation)
        try checkGeneration()
        var headers = ["Authorization": "Bearer " + token, "Content-Type": "application/json",
                       "Accept": "application/json, text/event-stream"]
        let initialization = try await DirectMCPHTTP.request(provider.endpoint, provider: provider, method: "POST",
            headers: headers, body: DirectMCPHTTP.json(initializeBody(id: 1)), rpcID: 1)
        if initialization.status == 401 { throw DirectMCPError.reconnectRequired }
        let envelope = try DirectMCPHTTP.object(initialization)
        guard envelope["id"] as? Int == 1, envelope["error"] == nil,
              let initialized = envelope["result"] as? [String: Any],
              let version = initialized["protocolVersion"] as? String,
              ["2025-11-25", "2025-06-18", "2025-03-26"].contains(version) else { throw DirectMCPError.invalidResponse }
        headers["MCP-Protocol-Version"] = version
        if let session = initialization.headers["mcp-session-id"] {
            guard session.utf8.count < 1_024, session.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
                throw DirectMCPError.invalidResponse
            }
            headers["MCP-Session-Id"] = session
        }
        let sessionHeaders = headers
        defer {
            if sessionHeaders["MCP-Session-Id"] != nil {
                Task { _ = try? await DirectMCPHTTP.request(provider.endpoint, provider: provider, method: "DELETE",
                                                           headers: sessionHeaders, limit: 16_384) }
            }
        }
        try checkGeneration()
        let notified = try await DirectMCPHTTP.request(provider.endpoint, provider: provider, method: "POST", headers: headers,
            body: DirectMCPHTTP.json(["jsonrpc": "2.0", "method": "notifications/initialized"]), limit: 16_384)
        guard (200..<300).contains(notified.status) else { throw DirectMCPError.http(notified.status) }
        var tools: [DirectMCPTool] = [], cursor: String?, seenCursors = Set<String>(), names = Set<String>()
        for id in 2...33 {
            try checkGeneration()
            let params: [String: Any] = cursor.map { ["cursor": $0] } ?? [:]
            let response = try await DirectMCPHTTP.request(provider.endpoint, provider: provider, method: "POST", headers: headers,
                body: DirectMCPHTTP.json(["jsonrpc": "2.0", "id": id, "method": "tools/list", "params": params]), rpcID: id)
            if response.status == 401 { throw DirectMCPError.reconnectRequired }
            let object = try DirectMCPHTTP.object(response)
            guard object["id"] as? Int == id, object["error"] == nil,
                  let result = object["result"] as? [String: Any], let page = result["tools"] as? [[String: Any]] else {
                throw DirectMCPError.invalidResponse
            }
            for tool in page {
                guard let name = tool["name"] as? String, DirectMCPTool.validName(name), names.insert(name).inserted,
                      tool["inputSchema"] is [String: Any], tools.count < 512 else { throw DirectMCPError.invalidResponse }
                let definition = try DirectMCPHTTP.json(tool)
                guard definition.count <= 128_000 else { throw DirectMCPError.tooLarge }
                tools.append(.init(name: name, description: tool["description"] as? String ?? "", definition: definition))
            }
            guard let next = result["nextCursor"] as? String else {
                guard !tools.isEmpty else { throw DirectMCPError.noTools }
                var account: Data?
                let accountCall: (name: String, arguments: [String: String])?
                switch provider.slug {
                case "granola": accountCall = ("get_account_info", [:])
                case "notion": accountCall = ("notion-fetch", ["id": "self"])
                default: accountCall = nil
                }
                if includeAccount, let accountCall, names.contains(accountCall.name) {
                    try checkGeneration()
                    let reply = try await DirectMCPHTTP.request(provider.endpoint, provider: provider, method: "POST", headers: headers,
                        body: DirectMCPHTTP.json(["jsonrpc": "2.0", "id": 34, "method": "tools/call",
                            "params": ["name": accountCall.name, "arguments": accountCall.arguments]]), limit: 64_000, rpcID: 34)
                    let object = try DirectMCPHTTP.object(reply)
                    guard object["id"] as? Int == 34, object["error"] == nil,
                          let result = object["result"] as? [String: Any] else {
                        throw DirectMCPError.invalidResponse
                    }
                    try validateAccountResult(result)
                    account = try DirectMCPHTTP.json(result)
                }
                return Snapshot(tools: tools.sorted { $0.name < $1.name }, account: account)
            }
            guard !next.isEmpty, next.utf8.count < 8_192, seenCursors.insert(next).inserted else { throw DirectMCPError.invalidResponse }
            cursor = next
        }
        throw DirectMCPError.tooLarge
    }

    static func validateAccountResult(_ result: [String: Any]) throws {
        guard result["isError"] as? Bool == true else { return }
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ").lowercased()
        if text.contains("user has not created a granola account yet") { throw DirectMCPError.accountSetupRequired }
        if text.contains("unauthorized") || text.contains("unauthenticated") { throw DirectMCPError.reconnectRequired }
        throw DirectMCPError.invalidResponse
    }
}
