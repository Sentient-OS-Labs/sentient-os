// Authenticated, bounded loopback HTTP transport and engine configuration for app-owned MCP tools.
// Sidekick and proactive research supply their own RPC handlers and tool policy.
// Doc: Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md

import Foundation
import Network

actor LocalMCPServer {
    nonisolated struct Connection: Sendable {
        let name: String
        let timeout: TimeInterval
        let tools: [String]
        let url: String
        let token: String
        var codexOverrides: [String] {
            let key = "mcp_servers.\(name)"
            return ["\(key).url=\(DirectMCPRuntime.quoted(url))",
                "\(key).http_headers={Authorization=\(DirectMCPRuntime.quoted("Bearer " + token))}",
                "\(key).enabled_tools=[\(tools.map(DirectMCPRuntime.quoted).joined(separator: ","))]",
                "\(key).default_tools_approval_mode=\"approve\"", "\(key).required=true",
                "\(key).tool_timeout_sec=\(Int(timeout))"]
        }
        var claudeServer: [String: Any] {
            ["type": "http", "url": url, "headers": ["Authorization": "Bearer " + token]]
        }
    }

    /// Extend the existing recipe wall and hooks without replacing connector policy.
    nonisolated static func addToClaudeArguments(_ arguments: [String], connection: Connection?) throws -> [String] {
        guard let connection else { return arguments }
        var args = arguments
        if let flag = args.firstIndex(of: "--mcp-config"), flag + 1 < args.count {
            guard var config = try JSONSerialization.jsonObject(with: Data(args[flag + 1].utf8)) as? [String: Any] else { throw URLError(.cannotParseResponse) }
            var servers = config["mcpServers"] as? [String: Any] ?? [:]
            servers[connection.name] = connection.claudeServer; config["mcpServers"] = servers
            args[flag + 1] = String(decoding: try json(config), as: UTF8.self)
        } else {
            args += ["--mcp-config", String(decoding: try json(["mcpServers": [connection.name: connection.claudeServer]]), as: UTF8.self)]
        }
        for flag in args.indices where args[flag] == "--settings" && flag + 1 < args.count {
            guard var settings = try JSONSerialization.jsonObject(with: Data(args[flag + 1].utf8)) as? [String: Any] else { throw URLError(.cannotParseResponse) }
            if var wall = settings["allowedMcpServers"] as? [[String: Any]] {
                wall.append(["serverName": connection.name]); settings["allowedMcpServers"] = wall
                args[flag + 1] = String(decoding: try json(settings), as: UTF8.self)
            }
        }
        return args
    }

    private let token = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, Error>?
    private var clients: [UUID: NWConnection] = [:]
    private var handlers: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    private let name: String
    private let tools: [String]
    private let timeout: TimeInterval
    private let maximumBody: Int
    private let response: @Sendable (Data) async throws -> Data

    init(name: String, tools: [String], timeout: TimeInterval, maximumBody: Int = 65_536,
         response: @escaping @Sendable (Data) async throws -> Data) {
        self.name = name; self.tools = tools; self.timeout = timeout; self.maximumBody = maximumBody; self.response = response
    }
    func start() async throws -> Connection {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] client in Task { await self?.accept(client) } }
        server.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state) } }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { await self?.startupFailed() }
        }
        defer { deadline.cancel() }
        let port = try await withCheckedThrowingContinuation { continuation in
            startup = continuation; server.start(queue: DispatchQueue(label: "sentient.local-mcp.listener"))
        }
        try Task.checkCancellation()
        return Connection(name: name, timeout: timeout, tools: tools, url: "http://127.0.0.1:\(port)/mcp", token: token)
    }

    private func changed(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue { startup?.resume(returning: port); startup = nil }
        case .failed: startupFailed()
        default: break
        }
    }
    private func startupFailed() {
        startup?.resume(throwing: URLError(.cannotConnectToHost)); startup = nil
        listener?.cancel(); listener = nil
    }

    func stop() {
        guard !closed else { return }
        closed = true; startup?.resume(throwing: CancellationError()); startup = nil
        listener?.cancel(); listener = nil
        handlers.values.forEach { $0.cancel() }; handlers.removeAll()
        clients.values.forEach { $0.cancel() }; clients.removeAll()
    }

    private func accept(_ client: NWConnection) {
        guard !closed, clients.count < 16 else { client.cancel(); return }
        let id = UUID(); clients[id] = client
        client.start(queue: DispatchQueue(label: "sentient.local-mcp.client"))
        handlers[id] = Task { await serve(client, id: id) }
    }

    private func serve(_ client: NWConnection, id: UUID) async {
        defer { client.cancel(); clients[id] = nil; handlers[id] = nil }
        do {
            let request = try await LoopbackHTTP.read(client, maximumBody: maximumBody) { [token] headers in
                headers["authorization"] == "Bearer " + token && headers["origin"] == nil
                    && headers["host"]?.hasPrefix("127.0.0.1:") == true
            }
            guard request.path == "/mcp", !closed else {
                try await LoopbackHTTP.write(client, LoopbackHTTP.response(status: 404)); return
            }
            guard request.method == "POST" else {
                try await LoopbackHTTP.write(client, LoopbackHTTP.response(status: 405)); return
            }
            guard let rpc = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { throw URLError(.badServerResponse) }
            guard rpc["id"] != nil else {
                try await LoopbackHTTP.write(client, LoopbackHTTP.response(status: 202)); return
            }
            let body = try await response(request.body)
            try await LoopbackHTTP.write(client, LoopbackHTTP.response(status: 200, body: body))
        } catch {
            let status = (error as? URLError)?.code == .userAuthenticationRequired ? 403 : 400
            try? await LoopbackHTTP.write(client, LoopbackHTTP.response(status: status))
        }
    }

    nonisolated private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
}
