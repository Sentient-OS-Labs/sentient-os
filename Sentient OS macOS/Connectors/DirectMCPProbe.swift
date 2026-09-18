//
// DirectMCPProbe.swift
// Performs the native MCP handshake and captures a complete, bounded tool inventory.
// The same metadata feeds policy validation; optional account calls establish workspace identity.
//
// Doc: Documentation - Connectors (Direct MCP).md

import Foundation

nonisolated enum DirectMCPProbe {
    static func tools(connection: DirectMCPConnection) async throws -> [DirectMCPTool] {
        try await capture(connection: connection).tools
    }
    struct Snapshot: Sendable { let tools: [DirectMCPTool]; let account: Data? }

    /// Fixed account-info call only: login never needs the tool inventory or a model.
    static func account(connection: DirectMCPConnection) async throws -> Data? {
        let session = try await DirectMCPSession.open(connection)
        defer { Task { await session.close() } }
        return try await account(session: session)
    }

    static func capture(connection: DirectMCPConnection, includeAccount: Bool = false) async throws -> Snapshot {
        let session = try await DirectMCPSession.open(connection)
        defer { Task { await session.close() } }
        var tools: [DirectMCPTool] = [], cursor: String?, seenCursors = Set<String>(), names = Set<String>()
        for id in 2...33 {
            try DirectMCPSession.check(connection)
            let params: [String: Any] = cursor.map { ["cursor": $0] } ?? [:]
            let result = try await session.request(method: "tools/list", parameters: params, id: id)
            guard let page = result["tools"] as? [[String: Any]] else { throw DirectMCPError.invalidResponse }
            for tool in page {
                guard let name = tool["name"] as? String, DirectMCPTool.validName(name), names.insert(name).inserted,
                      tool["inputSchema"] is [String: Any], tools.count < 512 else { throw DirectMCPError.invalidResponse }
                let definition = try DirectMCPHTTP.json(tool)
                guard definition.count <= 128_000 else { throw DirectMCPError.tooLarge }
                tools.append(.init(name: name, description: tool["description"] as? String ?? "", definition: definition))
            }
            guard let next = result["nextCursor"] as? String else {
                guard !tools.isEmpty else { throw DirectMCPError.noTools }
                let account = includeAccount ? try await account(session: session, availableNames: names) : nil
                return Snapshot(tools: tools.sorted { $0.name < $1.name }, account: account)
            }
            guard !next.isEmpty, next.utf8.count < 8_192, seenCursors.insert(next).inserted else { throw DirectMCPError.invalidResponse }
            cursor = next
        }
        throw DirectMCPError.tooLarge
    }

    private static func account(session: DirectMCPSession, availableNames: Set<String>? = nil) async throws -> Data? {
        let call: (name: String, arguments: [String: String])
        switch session.connection.providerSlug {
        case "granola": call = ("get_account_info", [:])
        case "notion": call = ("notion-fetch", ["id": "self"])
        default: return nil
        }
        if let availableNames, !availableNames.contains(call.name) { return nil }
        try DirectMCPSession.check(session.connection)
        let result = try await session.call(call.name, arguments: call.arguments, id: 34, limit: 64_000)
        try validateAccountResult(result)
        return try DirectMCPHTTP.json(result)
    }

    static func validateAccountResult(_ result: [String: Any]) throws {
        guard result["isError"] as? Bool == true else { return }
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ").lowercased()
        if text.contains("user has not created a granola account yet") { throw DirectMCPError.accountSetupRequired }
        if text.contains("unauthorized") || text.contains("unauthenticated") { throw DirectMCPError.reconnectRequired }
        throw DirectMCPError.invalidResponse
    }
}
