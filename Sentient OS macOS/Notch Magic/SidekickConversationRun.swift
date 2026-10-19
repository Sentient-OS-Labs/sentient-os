// Serial, task-scoped recording before events are reduced to transient UI status.
// No screenshots, accessibility trees, reasoning or telemetry enter conversation storage.

import Foundation

nonisolated final class SidekickConversationRun: @unchecked Sendable {
    typealias Event = SidekickConversationEvent
    let store: SidekickConversationStore
    let taskID: UUID
    let generation: UUID
    let backend: String
    let source: String
    private let lock = NSRecursiveLock()
    private var closed = false
    private var seen: [String: Event.Activity] = [:]
    private var executions = Set<UUID>()
    private var tools: [String: Event.Activity] = [:]
    private var answerDelivered = false
    private var recordedCompletion: AgentStatus?
    private struct MessageReceipt { let completion: AgentStatus.Completion? }
    private var deliveredMessages: [String: MessageReceipt] = [:]

    /// Evidence is scoped to this live task/generation. A crash or reset cannot restore a
    /// prior claim. The terminal task event persists the resolved outcome after process drain.
    var completionStatus: AgentStatus? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, (try? store.generation) == generation else { return nil }
        return recordedCompletion
    }

    init(store: SidekickConversationStore, taskID: UUID, generation: UUID,
         backend: String = "unknown", source: String = "unknown") {
        self.store = store; self.taskID = taskID; self.generation = generation
        self.backend = backend; self.source = source
    }

    enum Failure: LocalizedError {
        case closed, invalidMessage, invalidCompletion, invalidReference
        var errorDescription: String? {
            switch self {
            case .closed: "This Sidekick task has ended."
            case .invalidMessage: "The message must contain nonempty Markdown within the size limit."
            case .invalidCompletion: "Completion must be done or could_not, and is only valid on a final answer."
            case .invalidReference: "That conversation reference is unavailable."
            }
        }
    }

    @discardableResult
    func message(_ markdown: String, kind: Event.MessageKind, priority: Event.Priority,
                 id: String = UUID().uuidString, completion: AgentStatus.Completion? = nil) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw Failure.closed }
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              markdown.utf8.count <= 65_536 else { throw Failure.invalidMessage }
        guard completion == nil || kind == .answer else { throw Failure.invalidCompletion }
        let visibleText = kind == .answer ? Self.answerText(markdown) : markdown
        guard !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidMessage }
        if let receipt = deliveredMessages[id] {
            guard try store.generation == generation else { throw SidekickConversationStore.Failure.staleGeneration }
            guard receipt.completion == completion, let original = try store.record(id: id),
                  original.event.text == visibleText, original.event.messageKind == kind,
                  original.event.priority == priority else { throw SidekickConversationStore.Failure.duplicateEvent(id) }
            // A replay acknowledges the original save without restoring an outcome claim
            // invalidated by subsequent work or creating a different timestamp.
            return id
        }
        // An attempted replacement final answer supersedes the old claim even if this
        // write fails. A stale DONE must never survive a failed correction to could_not.
        if kind == .answer { recordedCompletion = nil }
        _ = try append(Event(id: id, taskID: taskID, kind: .assistantMessage, text: visibleText,
                             messageKind: kind, priority: priority))
        deliveredMessages[id] = MessageReceipt(completion: completion)
        if kind == .answer {
            answerDelivered = true
            // A final message sent while substantive tools are still in flight cannot prove
            // their outcome, even if those operations subsequently return without an error.
            let pending = tools.values.contains { $0.status == .started && !Self.isBookkeeping($0.name) }
            switch pending ? nil : completion {
            case .done: recordedCompletion = .done
            case .couldNot: recordedCompletion = .couldNot(reason: Self.bounded(visibleText, bytes: 2048))
            case nil: recordedCompletion = nil
            }
        }
        return id
    }

    func question(id: UUID, text: String, choices: [String], error: String?) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw Failure.closed }
        recordedCompletion = nil
        _ = try append(Event(id: "question:\(id)", taskID: taskID, kind: .question,
                             text: (error.map { $0 + "\n\n" } ?? "") + text,
                             priority: .high, choices: choices))
        answerDelivered = false
    }

    func answer(questionID: UUID, text: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw Failure.closed }
        _ = try append(Event(id: "answer:\(questionID)", taskID: taskID, kind: .answer, text: text,
                             reply: .init(messageID: "question:\(questionID)")))
    }

    /// Called synchronously by the owned process drain. Stable stream identity prevents
    /// item_0 in a fallback invocation from overwriting item_0 in the connector attempt.
    func observe(_ line: String, streamID: UUID) throws {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = event["type"] as? String else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        // A new provider leg needs its own final response, including a text-only fallback.
        // Replayed start notifications in the same stream must not invalidate a later answer.
        if kind == "thread.started" || (kind == "system" && event["subtype"] as? String == "init") {
            if executions.insert(streamID).inserted { answerDelivered = false; recordedCompletion = nil }
            return
        }
        if let item = event["item"] as? [String: Any], let id = item["id"] as? String,
           let type = item["type"] as? String {
            guard ["mcp_tool_call", "command_execution", "web_search"].contains(type),
                  ["item.started", "item.completed"].contains(kind) else { return }
            let server = item["server"] as? String ?? ""
            let name = item["tool"] as? String ?? type
            guard !Self.hidden(server: server, tool: name) else { return }
            let label = server.isEmpty ? name : server + "." + name
            let key = "\(streamID):\(id)"
            let failed = item["status"] as? String == "failed"
                || (item["result"] as? [String: Any])?["isError"] as? Bool == true
                || (item["exit_code"] as? Int).map { $0 != 0 } == true
            let status: Event.Activity.Status = kind == "item.started" ? .started
                : (failed ? .failed : .completed)
            let args = Self.details(item["arguments"] ?? item["command"] ?? item["query"])
            let result = status == .started ? nil : Self.resultDetails(
                item["result"] ?? item["aggregated_output"] ?? item["output"], tool: label, status: status)
            try activity(key: key, streamID: streamID, name: label, arguments: args, result: result, status: status)
        } else if let message = event["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                if kind == "assistant", block["type"] as? String == "tool_use",
                   let id = block["id"] as? String, let name = block["name"] as? String {
                    guard name != "StructuredOutput", !name.hasPrefix("mcp__sentient_relay__"),
                          !Self.hidden(server: "", tool: name) else { continue }
                    try activity(key: "\(streamID):\(id)", streamID: streamID, name: name,
                                 arguments: Self.details(block["input"]), result: nil, status: .started)
                } else if kind == "user", block["type"] as? String == "tool_result",
                          let id = block["tool_use_id"] as? String,
                          let old = tools["\(streamID):\(id)"] {
                    let status: Event.Activity.Status = block["is_error"] as? Bool == true ? .failed : .completed
                    try activity(key: "\(streamID):\(id)", streamID: streamID, name: old.name,
                                 arguments: old.arguments,
                                 result: Self.resultDetails(block["content"], tool: old.name, status: status), status: status)
                }
            }
        }
    }

    private func activity(key: String, streamID: UUID, name: String, arguments: String?, result: String?,
                          status: Event.Activity.Status) throws {
        let identity = "activity:\(taskID):\(key):\(status.rawValue)"
        let value = Event.Activity(toolID: key, name: name, arguments: arguments, result: result, status: status)
        if let previous = seen[identity] {
            guard previous == value else { throw SidekickConversationStore.Failure.duplicateEvent(identity) }
            return
        }
        if status == .started, let old = tools[key], old.status != .started { return }
        if let old = tools[key], old.status != .started, status != old.status {
            throw SidekickConversationStore.Failure.duplicateEvent(identity)
        }
        _ = try append(Event(id: identity, taskID: taskID, attemptID: streamID, kind: .activity,
                             text: name, activity: value))
        seen[identity] = value; tools[key] = value
        if status == .started, !Self.isBookkeeping(name) { answerDelivered = false; recordedCompletion = nil }
    }

    private static func isBookkeeping(_ name: String) -> Bool {
        name.hasPrefix("sentient_recovery.") || name.hasPrefix("mcp__sentient_recovery__")
            || name.hasPrefix("mcp__sentient_relay__") || name == "StructuredOutput"
    }

    /// The process has drained before this method runs. Closing once under the same lock
    /// prevents late UI callbacks from reopening it or attaching results to another task.
    func finish(outcome: Event.Outcome, status: String, finalText: String = "") throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        var events: [Event] = []
        for (key, value) in tools.sorted(by: { $0.key < $1.key }) where value.status == .started {
            events.append(Event(id: "unfinished:\(taskID):\(key)", taskID: taskID, kind: .activity,
                text: "\(value.name): outcome not confirmed",
                activity: .init(toolID: value.toolID, name: value.name, arguments: value.arguments,
                                result: "The task ended before a result was recorded. Verify current state before repeating an action.", status: .interrupted)))
        }
        if !tools.isEmpty {
            let completed = tools.values.filter { $0.status == .completed }.count
            let failed = tools.values.filter { $0.status == .failed }.count
            let pending = tools.values.filter { $0.status == .started }
            var checkpoint = "Observed tool results: \(completed) completed, \(failed) failed. These counts do not verify remote changes."
            if !pending.isEmpty {
                let names = Array(Set(pending.map { Self.bounded(Self.scrubText($0.name), bytes: 160) })).sorted()
                checkpoint += " Outcome not confirmed for \(pending.count) operation(s): " + names.prefix(8).joined(separator: ", ")
                if names.count > 8 { checkpoint += " (and \(names.count - 8) more tool types)" }
                checkpoint += ". Side effects remain unknown. Inspect current state before repeating an action."
            }
            // Context excludes raw activity, so retain only this small factual continuation note.
            events.append(Event(id: "checkpoint:\(taskID)", taskID: taskID, kind: .checkpoint, text: checkpoint))
        }
        if !answerDelivered, outcome != .stopped && outcome != .interrupted {
            let cleaned = outcome == .success ? Self.answerText(finalText).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let text = cleaned.isEmpty ? status : cleaned
            events.append(Event(id: "fallback:\(taskID)", taskID: taskID, kind: .assistantMessage,
                                text: Self.bounded(text, bytes: 65_536), messageKind: .answer, priority: .high))
        }
        events.append(Event(id: "end:\(taskID)", taskID: taskID, kind: .taskFinished,
                            text: status, outcome: outcome))
        _ = try store.appendBatch(events, expectedGeneration: generation)
        closed = true
        recordedCompletion = nil
        tools.removeAll(); seen.removeAll(); deliveredMessages.removeAll()
    }

    func invalidate() { lock.lock(); closed = true; recordedCompletion = nil; tools.removeAll(); seen.removeAll(); deliveredMessages.removeAll(); lock.unlock() }

    /// Read capabilities end with their task too. Reset invalidates this lock before wiping;
    /// a generation recheck also discards a result if an independent store handle reset it.
    func withOpenHistory<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw Failure.closed }
        guard try store.generation == generation else { throw SidekickConversationStore.Failure.staleGeneration }
        let result = try body()
        guard try store.generation == generation else { throw SidekickConversationStore.Failure.staleGeneration }
        return result
    }

    @discardableResult private func append(_ event: Event) throws -> SidekickConversationStore.Record {
        try store.append(event, expectedGeneration: generation)
    }

    static func hidden(server: String, tool: String) -> Bool {
        let local = server == "sentient_recovery" || tool.hasPrefix("mcp__sentient_recovery__")
        let leaf = tool.components(separatedBy: "__").last ?? tool
        return local && ["describe_task_usage", "message_user", "read_history", "search_history"].contains(leaf)
    }

    /// Remove only a standalone terminal protocol line. Models occasionally include their
    /// final STATUS in message_user as well as the CLI reply; it is bookkeeping, not UI text.
    /// Literal examples inside quotes, inline code, indented code or an open fence stay exact.
    /// No-marker messages retain their original whitespace and Markdown unchanged.
    static func answerText(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return raw }
        let candidate = lines[last]
        let indentation = candidate.prefix { $0 == " " || $0 == "\t" }
        guard indentation.count <= 3, !indentation.contains("\t"),
              candidate.trimmingCharacters(in: .whitespacesAndNewlines).range(
                of: #"^STATUS:\s*(DONE|COULD_NOT)(?:\s*[-:—–].*)?$"#,
                options: [.regularExpression, .caseInsensitive]) != nil else { return raw }

        var fence: (marker: Character, length: Int)?
        for line in lines[..<last] {
            let indentation = line.prefix { $0 == " " || $0 == "\t" }
            guard indentation.count <= 3, !indentation.contains("\t") else { continue }
            var body = String(line.dropFirst(indentation.count))
            // Fenced examples may also be the contents of a list item. Treat uncertainty
            // conservatively: retaining a literal is preferable to erasing the user's code.
            if fence == nil, let marker = body.range(of: #"^(?:[-+*]|[0-9]{1,9}[.)]) +"#, options: .regularExpression) {
                body.removeSubrange(marker)
            }
            guard let marker = body.first, marker == "`" || marker == "~" else { continue }
            let length = body.prefix { $0 == marker }.count
            guard length >= 3 else { continue }
            let rest = body.dropFirst(length)
            if let open = fence {
                if marker == open.marker, length >= open.length,
                   rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fence = nil }
            } else if marker == "~" || !rest.contains("`") {
                fence = (marker, length)
            }
        }
        guard fence == nil else { return raw }
        var content = Array(lines[..<last])
        while content.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { content.removeLast() }
        return content.joined(separator: "\n")
    }

    static func bounded(_ text: String, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        guard text.utf8.count > bytes else { return text }
        let suffix = bytes >= 12 ? "\n[truncated]" : (bytes >= 3 ? "…" : "")
        let available = bytes - suffix.utf8.count
        var end = text.startIndex, used = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let size = text[end..<next].utf8.count
            guard used + size <= available else { break }
            used += size; end = next
        }
        return String(text[..<end]) + suffix
    }

    /// Execution wrappers can return arbitrary screenshots/AX dumps as untyped stdout. Keep
    /// their command and observed status, without attempting to retain those output bodies.
    private static func resultDetails(_ value: Any?, tool: String, status: Event.Activity.Status) -> String? {
        let lower = tool.lowercased()
        let leaf = lower.components(separatedBy: "__").last?.components(separatedBy: ".").last ?? lower
        let execution = lower.contains("sentient_native") || lower.contains("node_repl")
            || lower.hasPrefix("cua.") || lower.hasPrefix("mcp__cua__")
            || ["command_execution", "bash", "shell", "exec", "exec_command", "execute_code", "run_code", "js", "python"].contains(leaf)
        if execution {
            return status == .failed ? "Tool reported a failure. Output omitted." : "Tool returned a result. Output omitted."
        }
        return details(value)
    }

    private static func scrubText(_ text: String) -> String {
        // Bound work before regular expressions. This is display-only history, never execution.
        var result = bounded(text, bytes: 32_768)
        let patterns: [(String, String)] = [
            (#"(?is)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)"#, "[private key omitted]"),
            (#"(?i)data:image/[a-z0-9.+-]+(?:;[^,\s]*)?,[^\s\"'<>)]*"#, "[image omitted]"),
            (#"(?im)(\b(?:proxy-)?authorization[\"']?\s*[:=]\s*)[^\r\n]*"#, "$1[redacted]"),
            (#"(?im)(\b(?:set-)?cookie[\"']?\s*[:=]\s*)[^\r\n]*"#, "$1[redacted]"),
            (#"(?i)(\b(?:api[_-]?key|private[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|token|password|passwd|client[_-]?secret|secret)[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;}\])]+)"#, "$1[redacted]"),
            (#"(?i)(--(?:api-key|access-token|refresh-token|token|password|passwd|secret)(?:=|\s+))(?:\"[^\"]*\"|'[^']*'|\S+)"#, "$1[redacted]"),
            (#"(?i)\bBearer\s+[^\s\"'<>]+"#, "Bearer [redacted]"),
            (#"(?i)([a-z][a-z0-9+.-]*://)[^/@:\s]+:[^/@\s]+@"#, "$1[redacted]@"),
            (#"\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{12,}|eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b"#, "[redacted]"),
            (#"[A-Za-z0-9+/]{256,}={0,2}"#, "[encoded content omitted]")
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    /// Bounded structured details, never image payloads/trees or credential-shaped fields.
    static func details(_ value: Any?) -> String? {
        guard let value else { return nil }
        func clean(_ value: Any, depth: Int = 0) -> Any {
            guard depth < 8 else { return "[nested content omitted]" }
            if let map = value as? [String: Any] {
                if let type = map["type"] as? String,
                   type.lowercased().contains("image") || type.lowercased() == "base64" { return "[image omitted]" }
                if let mime = (map["mimeType"] ?? map["mime_type"]) as? String,
                   mime.lowercased().hasPrefix("image/") { return "[image omitted]" }
                if (map["role"] as? String)?.hasPrefix("AX") == true || map.keys.contains(where: { $0.hasPrefix("AX") }) {
                    return "[accessibility structure omitted]"
                }
                var result: [String: Any] = [:]
                for key in map.keys.sorted().prefix(64) {
                    let lower = key.lowercased().filter { $0.isLetter || $0.isNumber }
                    if ["password", "passwd", "secret", "token", "authorization", "cookie", "apikey", "privatekey", "credential"].contains(where: lower.contains) {
                        result[key] = "[redacted]"
                    } else if ["base64", "screenshot", "accessibility"].contains(where: lower.contains)
                                || ["image", "imageurl", "imagedata", "blob", "pixels", "pixeldata", "treemarkdown", "axtree", "axnodes", "axelements", "axhierarchy"].contains(lower) {
                        result[key] = "[omitted]"
                    } else if let child = map[key] { result[key] = clean(child, depth: depth + 1) }
                }
                return result
            }
            if let array = value as? [Any] { return array.prefix(32).map { clean($0, depth: depth + 1) } }
            if let text = value as? String {
                // MCP text often wraps another JSON document. Sanitize that structure too,
                // including text blocks nested in text blocks, before applying display bounds.
                if text.utf8.count <= 131_072, let data = text.data(using: .utf8),
                   let nested = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    return clean(nested, depth: depth + 1)
                }
                if text.range(of: #"(?i)(?:tree[_-]?markdown|accessibility[_-]?(?:tree|nodes)|ax[_-]?tree)\s*[\"']?\s*[:=]|(?m)^\s*(?:[-*]\s*)?(?:\[\d+\]\s*)?AX(?:Application|Window|Group|Button|StaticText|TextField)\b"#,
                              options: .regularExpression) != nil { return "[accessibility output omitted]" }
                return bounded(scrubText(text), bytes: 8_192)
            }
            return value
        }
        let sanitized = clean(value)
        if let text = sanitized as? String { return bounded(text, bytes: 8_192) }
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return bounded(text, bytes: 8_192)
    }
}
