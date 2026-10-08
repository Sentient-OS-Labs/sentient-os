// Per-invocation authenticated MCP tools for real notch answers and automatic instruction updates.
// The app owns listener, calls and cancellation; repeated RPC IDs reuse the same result.
// Doc: Documentation - Sidekick - General.md

import Foundation
import Network

actor SidekickToolServer {
    nonisolated static let name = "sentient_recovery"
    nonisolated static let maximumWait: TimeInterval = 86_400
    @TaskLocal static var connection: Connection?

    struct Connection: Sendable {
        let url: String
        let token: String
        var codexOverrides: [String] {
            let key = "mcp_servers.\(SidekickToolServer.name)"
            return ["\(key).url=\(DirectMCPRuntime.quoted(url))",
                "\(key).http_headers={Authorization=\(DirectMCPRuntime.quoted("Bearer " + token))}",
                "\(key).default_tools_approval_mode=\"approve\"", "\(key).required=true",
                "\(key).tool_timeout_sec=\(Int(SidekickToolServer.maximumWait))"]
        }
        var claudeServer: [String: Any] {
            ["type": "http", "url": url, "headers": ["Authorization": "Bearer " + token]]
        }
    }

    private let interaction: SidekickInteraction
    private let token = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, Error>?
    private var clients: [UUID: NWConnection] = [:]
    private var handlers: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    private struct Call {
        let fingerprint: Data
        let task: Task<Data, Error>
    }
    private var calls: [String: Call] = [:]
    private var activeCall: String?

    init(interaction: SidekickInteraction) { self.interaction = interaction }

    /// Extend the existing recipe wall and hooks without replacing connector policy.
    nonisolated static func addToClaudeArguments(_ arguments: [String]) throws -> [String] {
        guard let connection else { return arguments }
        var args = arguments
        if let flag = args.firstIndex(of: "--mcp-config"), flag + 1 < args.count {
            guard var config = try JSONSerialization.jsonObject(with: Data(args[flag + 1].utf8)) as? [String: Any] else { throw URLError(.cannotParseResponse) }
            var servers = config["mcpServers"] as? [String: Any] ?? [:]
            servers[name] = connection.claudeServer; config["mcpServers"] = servers
            args[flag + 1] = String(decoding: try json(config), as: UTF8.self)
        } else {
            args += ["--mcp-config", String(decoding: try json(["mcpServers": [name: connection.claudeServer]]), as: UTF8.self)]
        }
        for flag in args.indices where args[flag] == "--settings" && flag + 1 < args.count {
            guard var settings = try JSONSerialization.jsonObject(with: Data(args[flag + 1].utf8)) as? [String: Any] else { throw URLError(.cannotParseResponse) }
            if var wall = settings["allowedMcpServers"] as? [[String: Any]] {
                wall.append(["serverName": name]); settings["allowedMcpServers"] = wall
                args[flag + 1] = String(decoding: try json(settings), as: UTF8.self)
            }
        }
        return args
    }

    @MainActor static func withConnection<T>(enabled: Bool = true, _ body: () async throws -> T) async throws -> T {
        guard enabled, let interaction = SidekickInteraction.current else {
            return try await $connection.withValue(nil) { try await body() }
        }
        let server = SidekickToolServer(interaction: interaction)
        do {
            let configuration = try await server.start()
            let result = try await withTaskCancellationHandler {
                try await $connection.withValue(configuration) { try await body() }
            } onCancel: { Task { await server.stop() } }
            await server.stop()
            return result
        } catch { await server.stop(); throw error }
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
            startup = continuation; server.start(queue: DispatchQueue(label: "sentient.recovery.listener"))
        }
        try Task.checkCancellation()
        return Connection(url: "http://127.0.0.1:\(port)/mcp", token: token)
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
        calls.values.forEach { $0.task.cancel() }; calls.removeAll()
        handlers.values.forEach { $0.cancel() }; handlers.removeAll()
        clients.values.forEach { $0.cancel() }; clients.removeAll()
    }

    private func accept(_ client: NWConnection) {
        guard !closed, clients.count < 16 else { client.cancel(); return }
        let id = UUID(); clients[id] = client
        client.start(queue: DispatchQueue(label: "sentient.recovery.client"))
        handlers[id] = Task { await serve(client, id: id) }
    }

    private func serve(_ client: NWConnection, id: UUID) async {
        defer { client.cancel(); clients[id] = nil; handlers[id] = nil }
        do {
            let request = try await LoopbackHTTP.read(client, maximumBody: 1_048_576) { [token] headers in
                headers["authorization"] == "Bearer " + token && headers["origin"] == nil
            }
            guard request.path == "/mcp", request.method == "POST", !closed else {
                try await LoopbackHTTP.write(client, LoopbackHTTP.response(status: 404)); return
            }
            guard let rpc = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { throw URLError(.badServerResponse) }
            guard rpc["id"] != nil else {
                try await LoopbackHTTP.write(client, LoopbackHTTP.response(status: 202)); return
            }
            let body = try await response(rpc)
            try await LoopbackHTTP.write(client, LoopbackHTTP.response(status: 200, body: body))
        } catch {
            let status = (error as? URLError)?.code == .userAuthenticationRequired ? 403 : 400
            try? await LoopbackHTTP.write(client, LoopbackHTTP.response(status: status))
        }
    }

    func response(_ rpc: [String: Any]) async throws -> Data {
        guard !closed, let id = rpc["id"], id is String || id is NSNumber else { throw CancellationError() }
        func reply(_ result: [String: Any]) throws -> Data { try Self.json(["jsonrpc": "2.0", "id": id, "result": result]) }
        switch rpc["method"] as? String {
        case "initialize":
            let params = rpc["params"] as? [String: Any]
            return try reply(["protocolVersion": params?["protocolVersion"] as? String ?? "2024-11-05",
                "capabilities": ["tools": [:]], "serverInfo": ["name": "Sidekick tools", "version": "2"]])
        case "ping": return try reply([:])
        case "tools/list":
            return try reply(["tools": [Self.tool] + (interaction.personalization == nil ? [] : [SidekickPersonalization.tool])])
        case "tools/call":
            guard let params = rpc["params"] as? [String: Any], let name = params["name"] as? String,
                  let arguments = params["arguments"] as? [String: Any] else {
                return try reply(Self.invalidArguments)
            }
            let key = String(decoding: try Self.json(id), as: UTF8.self)
            let fingerprint = try Self.json(["name": name, "arguments": arguments])
            let call: Call
            if let existing = calls[key] {
                guard existing.fingerprint == fingerprint else { return try reply(Self.invalidArguments) }
                call = existing
            } else {
                guard activeCall == nil, !interaction.hasActiveTools, !interaction.isWaiting, calls.count < 64 else {
                    if name == SidekickPersonalization.toolName {
                        return try reply(await Self.rejectedPersonalization(SidekickPersonalization.Failure.unavailable))
                    }
                    return try reply(Self.invalidArguments)
                }
                let action: @Sendable () async throws -> Data
                if name == "ask_user" {
                    guard let question = arguments["question"] as? String, let answers = arguments["answers"] as? [String],
                          Set(arguments.keys) == ["error", "question", "answers"],
                          arguments["error"] is NSNull || arguments["error"] is String,
                          let value = try? SidekickQuestion(error: arguments["error"] as? String, question: question, answers: answers) else {
                        return try reply(Self.invalidArguments)
                    }
                    action = { [interaction] in
                        let answer = try await interaction.ask(value)
                        var payload: [String: Any] = ["text": answer.text, "selectedAnswer": answer.selectedAnswer.map { $0 as Any } ?? NSNull()]
                        if interaction.personalization != nil {
                            payload["personalization_evidence_id"] = SidekickPersonalization.answerSource(value.id)
                        }
                        return try Self.json(payload)
                    }
                } else if name == SidekickPersonalization.toolName, interaction.personalization != nil {
                    let review: SidekickPersonalization.Review
                    do { review = try SidekickPersonalization.decode(arguments) }
                    catch {
                        return try reply(await Self.rejectedPersonalization(error))
                    }
                    action = { [interaction] in
                        let message = try await interaction.updateInstructions(review)
                        return try Self.json(["message": message])
                    }
                } else { return try reply(Self.invalidArguments) }
                activeCall = key
                call = Call(fingerprint: fingerprint, task: Task { try await action() })
                calls[key] = call
            }
            do {
                let result = try await call.task.value
                if activeCall == key { activeCall = nil }
                return try reply(["content": [["type": "text", "text": String(decoding: result, as: UTF8.self)]]])
            } catch {
                if activeCall == key { activeCall = nil }
                if name == SidekickPersonalization.toolName {
                    return try reply(await Self.rejectedPersonalization(error))
                }
                throw error
            }
        default: return try Self.json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method unavailable"]])
        }
    }

    private static var invalidArguments: [String: Any] {
        ["isError": true, "content": [["type": "text", "text": "Ask one nonempty question with exactly two distinct, concise answers. Only one question may be pending, and all other tool calls must finish first. Do not reuse an earlier request ID with changed arguments."]]]
    }
    @MainActor private static func rejectedPersonalization(_ error: Error) -> [String: Any] {
        let code = SidekickPersonalization.rejectionCode(error)
        Log("Sidekick personalization: tool rejected reason=\(code)")
        let hint: String
        switch code {
        case "invalid_review":
            hint = "Use the exact tool schema. With changes, skip_reason must be null. With changes=[], supply skip_reason with a supported code and nonempty detail."
        case "invalid_evidence":
            hint = "Use the supplied revision and quote real user evidence exactly. Starting screens support observed choices only; a user-requested app needs no screenshot evidence."
        case "invalid_change", "size_limit":
            hint = "Use the supplied editable IDs and scopes. Keep changes small, single-line and within the tool limits. Preserve manual instructions."
        default:
            hint = "Settings changed, a preference was removed, or the task is unavailable. Finish the original task honestly without claiming a save."
        }
        return ["isError": true, "content": [["type": "text", "text": "Instructions were not saved (\(code)). \(hint)"]]]
    }
    private static var tool: [String: Any] {
        ["name": "ask_user", "description": "Ask only when a specific missing fact, consequential ambiguity, or user-only action blocks the task after relevant context and reasonable safe checks. Handle routine obstacles yourself; do not repeat answered questions or use this for generic failure/retry prompts. Ask one concrete question with two useful choices. Returns only the user’s actual answer. Call alone after other tools finish; never act while waiting.",
         "inputSchema": ["type": "object", "properties": [
            "error": ["type": ["string", "null"], "description": "The complete error to display, or null for a clarification."],
            "question": ["type": "string", "minLength": 1, "maxLength": 500],
            "answers": ["type": "array", "minItems": 2, "maxItems": 2, "items": ["type": "string", "minLength": 1, "maxLength": 160]]],
            "required": ["error", "question", "answers"], "additionalProperties": false]]
    }
    nonisolated private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }
}
