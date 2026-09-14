//
// DirectMCPSession.swift
// One bounded native MCP session, shared by inventory probes and fixed provider read plans.
// Checks the account generation around every request and never exports authorization headers.
// Doc: Documentation - Connectors (Direct MCP).md
//

import Foundation

nonisolated struct DirectMCPSession: Sendable {
    let connection: DirectMCPConnection
    private let provider: DirectMCPProvider
    private let headers: [String: String]

    static func initializeBody(id: Int) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "initialize", "params": [
            "protocolVersion": "2025-11-25", "capabilities": [:],
            "clientInfo": ["name": "Sentient OS", "version": "2"]]]
    }

    static func open(_ connection: DirectMCPConnection) async throws -> Self {
        try check(connection)
        guard let provider = connection.provider else { throw DirectMCPError.unsupportedProvider }
        let token = try await DirectMCPAuth.accessToken(id: connection.id, generation: connection.generation)
        try check(connection)
        var headers = ["Authorization": "Bearer " + token, "Content-Type": "application/json",
                       "Accept": "application/json, text/event-stream"]
        let response = try await DirectMCPHTTP.request(provider.endpoint, provider: provider, method: "POST",
            headers: headers, body: DirectMCPHTTP.json(initializeBody(id: 1)), rpcID: 1)
        if response.status == 401 { throw DirectMCPError.reconnectRequired }
        let envelope = try DirectMCPHTTP.object(response)
        guard envelope["id"] as? Int == 1, envelope["error"] == nil,
              let initialized = envelope["result"] as? [String: Any],
              let version = initialized["protocolVersion"] as? String,
              ["2025-11-25", "2025-06-18", "2025-03-26"].contains(version) else {
            throw DirectMCPError.invalidResponse
        }
        headers["MCP-Protocol-Version"] = version
        if let session = response.headers["mcp-session-id"] {
            guard session.utf8.count < 1_024, session.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
                throw DirectMCPError.invalidResponse
            }
            headers["MCP-Session-Id"] = session
        }
        let result = Self(connection: connection, provider: provider, headers: headers)
        do {
            try check(connection)
            let notified = try await DirectMCPHTTP.request(provider.endpoint, provider: provider, method: "POST",
                headers: headers, body: DirectMCPHTTP.json(["jsonrpc": "2.0", "method": "notifications/initialized"]),
                limit: 16_384)
            guard (200..<300).contains(notified.status) else { throw DirectMCPError.http(notified.status) }
            try check(connection)
            return result
        } catch { await result.close(); throw error }
    }

    func request(method: String, parameters: [String: Any], id: Int, limit: Int = 2_000_000) async throws -> [String: Any] {
        try Self.check(connection)
        // Selection/summarization can outlast the access token used for initialization.
        // Reuse the current grant (or renew an expiring one) before every native request.
        let token = try await DirectMCPAuth.accessToken(id: connection.id, generation: connection.generation)
        try Self.check(connection)
        var requestHeaders = headers
        requestHeaders["Authorization"] = "Bearer " + token
        let response = try await DirectMCPHTTP.request(provider.endpoint, provider: provider, method: "POST",
            headers: requestHeaders, body: DirectMCPHTTP.json(["jsonrpc": "2.0", "id": id, "method": method, "params": parameters]),
            limit: limit, rpcID: id)
        if response.status == 401 { throw DirectMCPError.reconnectRequired }
        let envelope = try DirectMCPHTTP.object(response)
        try Self.check(connection)
        guard envelope["id"] as? Int == id, envelope["error"] == nil,
              let result = envelope["result"] as? [String: Any] else { throw DirectMCPError.invalidResponse }
        return result
    }

    func call(_ name: String, arguments: [String: Any], id: Int, limit: Int) async throws -> [String: Any] {
        try await request(method: "tools/call", parameters: ["name": name, "arguments": arguments], id: id, limit: limit)
    }

    func close() async {
        guard headers["MCP-Session-Id"] != nil else { return }
        _ = try? await DirectMCPHTTP.request(provider.endpoint, provider: provider, method: "DELETE",
                                            headers: headers, limit: 16_384)
    }

    static func check(_ connection: DirectMCPConnection) throws {
        try Task.checkCancellation()
        guard DirectMCPStore.connection(id: connection.id)?.generation == connection.generation else {
            throw DirectMCPError.connectionChanged
        }
    }
}
