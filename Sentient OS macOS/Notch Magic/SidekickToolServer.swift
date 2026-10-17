// Per-invocation MCP tools for notch answers, instruction updates and task usage descriptions.
// The app owns listener, calls and cancellation; repeated RPC IDs reuse the same result.
// Doc: Documentation - Sidekick - General.md

import Foundation
import CoreFoundation

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
        if interaction.conversationRun != nil { tools += SidekickConversationTools.names }
        if interaction.personalization != nil { tools.append(SidekickPersonalization.toolName) }
        if interaction.taskSummary != nil { tools.append(SidekickTaskSummary.toolName) }
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
        if let number = id as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { throw CancellationError() }
        func reply(_ result: [String: Any]) throws -> Data { try Self.json(["jsonrpc": "2.0", "id": id, "result": result]) }
        switch rpc["method"] as? String {
        case "initialize":
            let params = rpc["params"] as? [String: Any]
            return try reply(["protocolVersion": params?["protocolVersion"] as? String ?? "2024-11-05",
                "capabilities": ["tools": [:]], "serverInfo": ["name": "Sidekick tools", "version": "2"]])
        case "ping": return try reply([:])
        case "tools/list":
            return try reply(["tools": [Self.tool]
                + (interaction.conversationRun == nil ? [] : SidekickConversationTools.schemas)
                + (interaction.personalization == nil ? [] : [SidekickPersonalization.tool])
                + (interaction.taskSummary == nil ? [] : [SidekickTaskSummary.tool])])
        case "tools/call":
            guard let params = rpc["params"] as? [String: Any], let name = params["name"] as? String else {
                return try reply(Self.invalidArguments)
            }
            guard let arguments = params["arguments"] as? [String: Any] else {
                if name == SidekickTaskSummary.toolName {
                    interaction.taskSummary?.reject(.invalidArguments)
                    return try reply(Self.rejectedSummary)
                }
                return try reply(Self.invalidArguments)
            }
            let key = String(decoding: try Self.json(id), as: UTF8.self)
            let fingerprint = try Self.json(["name": name, "arguments": arguments])
            let call: Call
            if let existing = calls[key] {
                guard existing.fingerprint == fingerprint else {
                    if name == SidekickTaskSummary.toolName {
                        interaction.taskSummary?.reject(.invalidArguments)
                        return try reply(Self.rejectedSummary)
                    }
                    return try reply(Self.invalidArguments)
                }
                call = existing
            } else {
                let quietMessage = name == "message_user"
                guard activeCall == nil, (quietMessage || !interaction.hasActiveTools), !interaction.isWaiting, calls.count < 512 else {
                    if name == SidekickTaskSummary.toolName {
                        interaction.taskSummary?.reject(.toolBusy)
                        return try reply(Self.rejectedSummary)
                    }
                    if name == SidekickPersonalization.toolName {
                        let message = await Self.rejectedPersonalization(SidekickPersonalization.Failure.unavailable)
                        return try reply(Self.toolError(message))
                    }
                    return try reply(Self.invalidArguments)
                }
                let action: @Sendable () async throws -> Data
                if SidekickConversationTools.names.contains(name), let run = interaction.conversationRun {
                    let encoded = try Self.json(arguments)
                    action = {
                        guard let values = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                            throw SidekickConversationRun.Failure.invalidMessage
                        }
                        return try SidekickConversationTools.invoke(name, arguments: values, run: run)
                    }
                } else if name == "ask_user" {
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
                        let message = await Self.rejectedPersonalization(error)
                        return try reply(Self.toolError(message))
                    }
                    action = { [interaction] in
                        let message = try await interaction.updateInstructions(review)
                        return try Self.json(["message": message])
                    }
                } else if name == SidekickTaskSummary.toolName, let summary = interaction.taskSummary {
                    do { try summary.stage(arguments) }
                    catch { return try reply(Self.rejectedSummary) }
                    action = {
                        try Self.json(["message": "Description received for reporting after the attempt ends. Continue the original task; if it has ended, emit its final answer and STATUS."])
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
                    let message = await Self.rejectedPersonalization(error)
                        return try reply(Self.toolError(message))
                }
                if SidekickConversationTools.names.contains(name) {
                    SidekickDiagnostics.failure(name == "message_user" ? .messageDelivery : .historyRead,
                        reason: error is SidekickConversationRun.Failure ? .invalidInput : .persistence,
                        taskID: interaction.conversationRun?.taskID,
                        backend: .init(rawValue: interaction.conversationRun?.backend ?? "unknown") ?? .unknown)
                    return try reply(["isError": true, "content": [["type": "text", "text":
                        "The conversation operation could not be completed. Check its arguments and the supplied size limits. Do not claim a message was saved unless the tool returned saved=true. Original history has not been overwritten."]]])
                }
                throw error
            }
        default: return try Self.json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method unavailable"]])
        }
    }

    private static var invalidArguments: [String: Any] {
        ["isError": true, "content": [["type": "text", "text": "Use this tool's declared schema. Only one Sidekick tool call may be pending. Questions require all actions to finish first. Do not reuse an earlier request ID with changed arguments."]]]
    }
    private static var rejectedSummary: [String: Any] {
        ["isError": true, "content": [["type": "text",
            "text": "Description not accepted. Do not retry for analytics. Continue the original task; when it ends, give its final answer and required STATUS."]]]
    }
    @MainActor private static func rejectedPersonalization(_ error: Error) -> String {
        let code = SidekickPersonalization.rejectionCode(error)
        Log("Sidekick personalization: tool rejected reason=\(code)")
        return SidekickPersonalization.failureMessage(error)
    }

    private static func toolError(_ message: String) -> [String: Any] {
        ["isError": true, "content": [["type": "text", "text": message]]]
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
