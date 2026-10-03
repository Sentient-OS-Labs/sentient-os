// Owns one Claude subscription-backed Codex computer task: loopback provider, CLI, and MCP relay.
// Claude authenticates and reasons; Codex executes every advertised tool and returns its real result.
// Doc: Documentation - Cloud - ClaudeCLI (the claude -p engine).md

import Foundation
import Network

actor ClaudeSubscriptionBridge {
    typealias Wire = ClaudeSubscriptionProtocol
    typealias Failure = Wire.Failure
    nonisolated static let environmentKey = "SENTIENT_CLAUDE_BRIDGE_TOKEN"

    struct Configuration: Sendable {
        let overrides: [String]
        let environment: [String: String]
    }

    private let binary: String
    private let model: String
    private let effort: String
    private let timeout: TimeInterval
    private let namespaces: Set<String>
    private let onProgress: @Sendable (String) -> Void
    private let secret = UUID().uuidString + UUID().uuidString
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-claude-\(UUID().uuidString)", isDirectory: true)
    private var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var claudeTask: Task<Void, Never>?
    private var closed = false
    private var started = false
    private var sessionKey: String?
    private var tools: [Wire.Tool] = []
    private(set) var failure: Error?
    var requestedToolCount: Int { calls.count }
    private var finalUsage: [String: Any]?

    private struct Call {
        let fingerprint: String
        var waiters: [CheckedContinuation<Data, Error>]
        var outputFingerprint: String?
        var reply: Data?
    }
    private var calls: [String: Call] = [:] // Claude RPC id -> the one Codex call it created
    private var callOwners: [String: String] = [:] // Codex call id -> Claude RPC id
    private var recentCalls: [String] = []
    private var queue: [[String: Any]] = []
    private var activeRequest: String?
    private var responseWaiters: [CheckedContinuation<Data, Error>] = []
    private var responses: [String: Data] = [:]
    private var responseOrder: [String] = []
    private var retiredRequests = Set<String>()

    init(binary: String, model: String, effort: String, timeout: TimeInterval,
         namespaces: Set<String>, onProgress: @escaping @Sendable (String) -> Void) {
        self.binary = binary; self.model = model; self.effort = effort; self.timeout = timeout
        self.namespaces = namespaces; self.onProgress = onProgress
    }

    func start() async throws -> Configuration {
        guard !closed, listener == nil,
              [ClaudeCLI.Model.sonnet.rawValue, ClaudeCLI.Model.opus.rawValue].contains(model),
              ["low", "medium", "high"].contains(effort) else { throw Failure.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let catalog = directory.appendingPathComponent("models.json")
        try writePrivate(Wire.json(Wire.catalog(model: model)), to: catalog)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            Task { await self?.serve(connection) }
        }
        server.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerChanged(state) }
        }
        let startupTimeout = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { listenerFailed() }
        }
        defer { startupTimeout.cancel() }
        let port = try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            server.start(queue: DispatchQueue(label: "sentient.claude-provider"))
        }
        try Task.checkCancellation()
        let base = "http://127.0.0.1:\(port)"
        let mcp: [String: Any] = ["mcpServers": ["sentient_relay": ["type": "http", "url": base + "/mcp",
            "headers": ["Authorization": "Bearer " + secret]]]]
        try writePrivate(Wire.json(mcp), to: directory.appendingPathComponent("mcp.json"))
        let table = "model_providers.sentient_claude={name=\"Claude subscription\",base_url=\"\(base)/v1\","
            + "wire_api=\"responses\",env_key=\"\(Self.environmentKey)\",requires_openai_auth=false,"
            + "supports_websockets=false,request_max_retries=2,stream_max_retries=2,stream_idle_timeout_ms=\(Int(timeout * 1000))}"
        return Configuration(overrides: [table, "model_provider=\"sentient_claude\"",
            "model_catalog_json=\(OpenAIComputerUse.tomlString(catalog.path))", "web_search=\"disabled\"",
            "features.apps=false", "features.plugins=false", "features.multi_agent=false",
            "features.enable_request_compression=false",
            "model_reasoning_summary=\"none\"",
            // Claude owns compaction of its live session. A second summarizer in Codex would
            // sever that session's tool-result correspondence. Transport and task budgets remain bounded.
            "model_auto_compact_token_limit=9223372036854775807"],
            environment: [Self.environmentKey: secret])
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue { startup?.resume(returning: port); startup = nil }
        case .failed: listenerFailed()
        default: break
        }
    }

    private func listenerFailed() {
        startup?.resume(throwing: Failure.unavailable); startup = nil
        fail(Failure.unavailable)
    }

    /// Called for success, failure, timeout, and cancellation. The caller awaits the owned child.
    func stop() async {
        if !closed {
            closed = true
            startup?.resume(throwing: CancellationError()); startup = nil
            listener?.cancel(); listener = nil
            fail(CancellationError())
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
            claudeTask?.cancel()
        }
        await claudeTask?.value
        try? FileManager.default.removeItem(at: directory)
    }

    private func writePrivate(_ data: Data, to file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.unavailable
        }
    }

    private func serve(_ connection: NWConnection) async {
        guard !closed, connections.count < 32 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: DispatchQueue(label: "sentient.claude-provider.connection"))
        defer { connection.cancel(); connections.removeValue(forKey: id) }
        do {
            let request = try await LoopbackHTTP.read(connection, authorize: { [secret] headers in
                headers["authorization"] == "Bearer " + secret && headers["origin"] == nil
            })
            guard !closed else { return }
            let path = String(request.path.split(separator: "?", maxSplits: 1)[0])
            if request.method == "GET", path == "/v1/models" {
                try await LoopbackHTTP.write(connection, LoopbackHTTP.response(status: 200,
                    body: Wire.json(["object": "list", "data": [["id": model, "object": "model", "owned_by": "anthropic"]]])))
            } else if request.method == "POST", path == "/v1/responses" {
                guard let payload = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { throw Failure.invalidRequest }
                let data = try await response(payload)
                try await LoopbackHTTP.write(connection, LoopbackHTTP.response(status: 200, contentType: "text/event-stream", body: data))
            } else if request.method == "POST", path == "/mcp" {
                guard let payload = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { throw Failure.invalidRequest }
                if payload["id"] == nil {
                    try await LoopbackHTTP.write(connection, LoopbackHTTP.response(status: 202))
                } else {
                    let data = try await mcp(payload)
                    try await LoopbackHTTP.write(connection, LoopbackHTTP.response(status: 200, body: data))
                }
            } else {
                try await LoopbackHTTP.write(connection, LoopbackHTTP.response(status: 404))
            }
        } catch {
            if (error as? URLError)?.code == .userAuthenticationRequired {
                try? await LoopbackHTTP.write(connection, LoopbackHTTP.response(status: 403)); return
            }
            // No prompts, tool arguments, paths, endpoint capabilities, or provider transcripts in logs.
            let body = try? Wire.json(["error": ["type": "invalid_request_error", "message": "The Claude computer-use connection could not complete this request."]])
            try? await LoopbackHTTP.write(connection, LoopbackHTTP.response(status: 400, body: body ?? Data()))
        }
    }

    private func response(_ payload: [String: Any]) async throws -> Data {
        if let failure { throw failure }
        guard payload["model"] as? String == model,
              let input = payload["input"] as? [[String: Any]], payload["previous_response_id"] == nil else { throw Failure.changedSession }
        let key = payload["prompt_cache_key"] as? String ?? "single-run"
        guard sessionKey == nil || sessionKey == key else { throw Failure.changedSession }
        let fingerprint = try Wire.fingerprint(["input": input, "model": model,
            "instructions": payload["instructions"] ?? "", "tools": payload["tools"] ?? []])
        if let cached = responses[fingerprint] { return cached }
        guard !retiredRequests.contains(fingerprint) else { throw Failure.staleRetry }
        if let activeRequest, activeRequest != fingerprint { throw Failure.concurrentRequest }
        if !started {
            tools = try Wire.tools(payload, namespaces: namespaces)
            sessionKey = key
            try launch(payload)
            started = true
        } else {
            var suppliedOutput = false
            for item in input where item["type"] as? String == "function_call_output" {
                guard let callID = item["call_id"] as? String, let owner = callOwners[callID], var call = calls[owner] else {
                    throw Failure.invalidResult
                }
                let output = item["output"] ?? ""
                let digest = try Wire.fingerprint(output)
                if let previous = call.outputFingerprint {
                    guard digest == previous else { throw Failure.changedSession }
                    continue
                }
                let content = try Wire.content(output)
                let reply = try Wire.json(["jsonrpc": "2.0", "id": try JSONSerialization.jsonObject(with: Data(owner.utf8), options: [.fragmentsAllowed]),
                    "result": ["content": content]])
                call.outputFingerprint = digest; call.reply = reply
                let waiters = call.waiters; call.waiters = []
                calls[owner] = call
                for waiter in waiters { waiter.resume(returning: reply) }
                recentCalls.append(owner)
                if recentCalls.count > 4, let oldest = recentCalls.first {
                    recentCalls.removeFirst(); calls[oldest]?.reply = nil
                }
                suppliedOutput = true
            }
            // A continuation must deliver a real result or consume an already queued call.
            // A compaction/new user turn cannot silently start a second executor or repeat actions.
            guard suppliedOutput || !queue.isEmpty || activeRequest == fingerprint else { throw Failure.changedSession }
        }
        return try await withCheckedThrowingContinuation { continuation in
            activeRequest = fingerprint
            responseWaiters.append(continuation)
            flush()
        }
    }

    private func mcp(_ payload: [String: Any]) async throws -> Data {
        guard !closed, let id = payload["id"], let method = payload["method"] as? String else { throw Failure.invalidRequest }
        func reply(_ value: Any) throws -> Data { try Wire.json(["jsonrpc": "2.0", "id": id, "result": value]) }
        switch method {
        case "initialize":
            let parameters = payload["params"] as? [String: Any] ?? [:]
            return try reply(["protocolVersion": parameters["protocolVersion"] as? String ?? "2024-11-05",
                "capabilities": ["tools": [:]], "serverInfo": ["name": "Sentient Codex tool relay", "version": "1"]])
        case "ping": return try reply([String: Any]())
        case "tools/list": return try reply(["tools": tools.map(\.mcp)])
        case "tools/call":
            if let failure { throw failure }
            guard let parameters = payload["params"] as? [String: Any],
                  let name = parameters["name"] as? String, let tool = tools.first(where: { $0.alias == name }),
                  let arguments = parameters["arguments"] as? [String: Any] else { throw Failure.unsupportedTool }
            let owner = String(decoding: try Wire.json(id), as: UTF8.self)
            let fingerprint = try Wire.fingerprint(parameters)
            if let call = calls[owner] {
                guard call.fingerprint == fingerprint else { throw Failure.changedSession }
                if let reply = call.reply { return reply }
                guard call.outputFingerprint == nil else { throw Failure.staleRetry }
                return try await withCheckedThrowingContinuation { calls[owner]?.waiters.append($0) }
            }
            guard calls.count < 2_000 else { throw Failure.contextLimit }
            let callID = "call_" + UUID().uuidString
            var item: [String: Any] = ["id": "fc_" + UUID().uuidString, "type": "function_call", "status": "completed",
                "name": tool.name, "call_id": callID,
                "arguments": String(decoding: try Wire.json(arguments), as: UTF8.self)]
            if !tool.namespace.isEmpty { item["namespace"] = tool.namespace }
            return try await withCheckedThrowingContinuation { continuation in
                calls[owner] = Call(fingerprint: fingerprint, waiters: [continuation])
                callOwners[callID] = owner
                queue.append(item)
                onProgress(Self.toolProgress(tool, arguments: arguments))
                flush()
            }
        default:
            return try Wire.json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method unavailable"]])
        }
    }

    private func launch(_ payload: [String: Any]) throws {
        let system = (payload["instructions"] as? String ?? Wire.instructions) + """

        The sentient_relay MCP tools correspond to this Codex client's tools. Codex executes
        them and supplies the actual results. Use only the advertised tools for the user's task.
        Prefer set_value for editable text fields; verify accents, emoji, and other Unicode text.
        Never infer success from an attempted call. Do not obtain credentials or change permissions.
        """
        let systemFile = directory.appendingPathComponent("instructions.txt")
        try writePrivate(Data(system.utf8), to: systemFile)
        let input = try Wire.initialInput(payload)
        let arguments = ["-p", "--model", model, "--effort", effort,
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "dontAsk", "--tools", "", "--allowedTools", "mcp__sentient_relay__*",
            "--strict-mcp-config", "--mcp-config", directory.appendingPathComponent("mcp.json").path,
            "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence",
            "--system-prompt-file", systemFile.path]
        var environment = ClaudeCLI.baseEnv
        environment.merge(["ENABLE_TOOL_SEARCH": "false", "MCP_CONNECTION_NONBLOCKING": "0",
            "MCP_TIMEOUT": "30000", "MCP_CONNECT_TIMEOUT_MS": "30000", "MCP_TOOL_TIMEOUT": String(Int(timeout * 1_000)),
            "MAX_MCP_OUTPUT_TOKENS": "50000"]) { _, new in new }
        guard let executable = Bundle.main.executableURL?.path else { throw Failure.unavailable }
        let invocation = ClaudeSubscriptionProcess.Invocation(parent: getpid(), binary: binary,
            arguments: arguments, input: input, environment: environment, timeout: timeout)
        let invocationJSON = String(decoding: try JSONEncoder().encode(invocation), as: UTF8.self)
        let timeout = timeout, directory = directory, onProgress = onProgress
        claudeTask = Task {
            let began = Date()
            do {
                let result = try await CodexCLI.executeAsync(binary: executable,
                    args: [ClaudeSubscriptionProcess.argument], stdinText: invocationJSON,
                    cwd: directory.path, timeout: timeout + 5, includeCustomProviderKey: false,
                    terminationGrace: 3, retainStdoutLine: ClaudeSubscriptionProcess.retainEnvelopeLine) { line in
                        for progress in Self.narrationLines(fromStreamJSON: line) { onProgress(progress) }
                    }
                try Task.checkCancellation()
                if result.status == 124 { throw CodexCLI.CLIError.timedOut(after: timeout) }
                let envelope = try ClaudeCLI.parseEnvelope(result, durationMS: Int(Date().timeIntervalSince(began) * 1_000))
                complete(envelope)
            } catch { fail(error) }
        }
    }

    /// Only assistant narration reaches the notch. Relay activity is emitted when a validated
    /// tool call is queued, so retries, tool results, arguments, and thinking never become logs.
    nonisolated static func narrationLines(fromStreamJSON line: String) -> [String] {
        ClaudeCLI.humanLines(fromStreamJSON: line)
            .filter { !$0.hasPrefix("→ sentient_relay.") }
            .flatMap { $0.components(separatedBy: .newlines) }
    }

    nonisolated static func toolProgress(_ tool: Wire.Tool, arguments: [String: Any]) -> String {
        guard tool.namespace == "mcp__sentient_native" else {
            if ["exec_command", "shell_command", "write_stdin"].contains(tool.name) {
                return tool.name == "write_stdin" ? "Continuing a command" : "Running a command"
            }
            return "→ \(tool.namespace.replacingOccurrences(of: "mcp__", with: "")).\(tool.name)"
        }
        let app = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = app.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
        switch tool.name {
        case "get_app_state": return target.map { "Looking at \($0)" } ?? "Looking at the app"
        case "get_desktop_state", "list_apps": return "Looking at your Mac"
        case "click", "double_click", "right_click": return target.map { "Clicking in \($0)" } ?? "Clicking"
        case "set_value", "type_text": return target.map { "Entering text in \($0)" } ?? "Entering text"
        case "press_key": return target.map { "Using the keyboard in \($0)" } ?? "Using the keyboard"
        case "scroll": return target.map { "Scrolling in \($0)" } ?? "Scrolling"
        case "drag": return target.map { "Dragging in \($0)" } ?? "Dragging"
        default: return "→ computer.\(tool.name)"
        }
    }

    private func complete(_ result: CodexCLI.Envelope) {
        guard !closed, failure == nil else { return }
        guard calls.values.allSatisfy({ $0.outputFingerprint != nil }) else { fail(Failure.invalidResult); return }
        let input = result.inputTokens ?? 0, output = result.outputTokens ?? 0
        finalUsage = ["input_tokens": input, "output_tokens": output, "total_tokens": input + output,
            "input_tokens_details": ["cached_tokens": result.cachedInputTokens ?? 0]]
        queue.append(["id": "msg_" + UUID().uuidString, "type": "message", "role": "assistant", "status": "completed",
            "phase": "final_answer", "content": [["type": "output_text", "text": result.result, "annotations": []]]])
        flush()
    }

    private func flush() {
        guard let fingerprint = activeRequest, !queue.isEmpty, failure == nil else { return }
        do {
            let item = queue.removeFirst()
            let response = try Wire.response(item: item, model: model,
                usage: item["type"] as? String == "message" ? finalUsage : nil)
            responses[fingerprint] = response; responseOrder.append(fingerprint)
            if responseOrder.count > 128 {
                let oldest = responseOrder.removeFirst()
                responses.removeValue(forKey: oldest); retiredRequests.insert(oldest)
            }
            activeRequest = nil
            let waiters = responseWaiters; responseWaiters = []
            for waiter in waiters { waiter.resume(returning: response) }
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        if failure == nil { failure = error }
        let waiters = responseWaiters; responseWaiters = []; activeRequest = nil
        for waiter in waiters { waiter.resume(throwing: error) }
        for owner in Array(calls.keys) {
            let pending = calls[owner]?.waiters ?? []
            calls[owner]?.waiters = []
            for waiter in pending { waiter.resume(throwing: error) }
        }
    }
}
