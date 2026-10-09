// Per-invocation authenticated MCP tools for real notch answers and automatic instruction updates.
// The app owns listener, calls and cancellation; repeated RPC IDs reuse the same result.
// Doc: Documentation - Sidekick - General.md

import Foundation

actor SidekickToolServer {
    nonisolated static let name = "sentient_recovery"
    nonisolated static let maximumWait: TimeInterval = 86_400
    @TaskLocal static var connection: Connection?

    typealias Connection = LocalMCPServer.Connection
    private let interaction: SidekickInteraction
    private var transport: LocalMCPServer?
    private var closed = false
    private struct Call {
        let fingerprint: Data
        let task: Task<Data, Error>
    }
    private var calls: [String: Call] = [:]
    private var activeCall: String?

    init(interaction: SidekickInteraction) { self.interaction = interaction }

    nonisolated static func addToClaudeArguments(_ arguments: [String]) throws -> [String] {
        try LocalMCPServer.addToClaudeArguments(arguments, connection: connection)
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
        var tools = ["ask_user"]
        if interaction.personalization != nil { tools.append(SidekickPersonalization.toolName) }
        let transport = LocalMCPServer(name: Self.name, tools: tools, timeout: Self.maximumWait, maximumBody: 1_048_576) { [weak self] data in
            guard let self, let rpc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CancellationError() }
            return try await self.response(rpc)
        }
        self.transport = transport
        return try await transport.start()
    }

    func stop() async {
        closed = true
        calls.values.forEach { $0.task.cancel() }; calls.removeAll()
        await transport?.stop(); transport = nil
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
