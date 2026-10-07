// Reads Codex computer-task events, detects native browser interruptions, and formats progress.
// Tool failures are inspected before model-specific narration can hide them.
// Doc: Documentation - Cloud - CodexCLI (the codex exec spine).md

import Foundation

nonisolated enum ComputerUseStream {
    enum Interruption: LocalizedError, Equatable {
        case browserChanged

        var errorDescription: String? {
            "Please use another browser so Sidekick can continue its task."
        }
    }

    enum NativeCall: Sendable, Equatable {
        case started(id: String, app: String, tool: String)
        case completed(id: String)
    }

    /// Race the real process against local input detection, since a paused native call may
    /// never return an error. Both paths stop through executeStreaming's owned-child cleanup.
    static func run(binary: String, args: [String], timeout: TimeInterval,
                    extraEnv: [String: String] = [:], narrate: Bool = true,
                    onLine: @escaping @Sendable (String) -> Void) async throws -> CodexCLI.ExecResult {
        let interaction = BrowserInteractionMonitor()
        return try await withThrowingTaskGroup(of: CodexCLI.ExecResult.self) { group in
            group.addTask {
                try await CodexCLI.executeStreaming(binary: binary, args: args, timeout: timeout, extraEnv: extraEnv) { line in
                    if interaction.isInterrupted { throw Interruption.browserChanged }
                    let progress = try progress(from: line, onNativeCall: { interaction.observe($0) })
                    if narrate { progress.forEach(onLine) }
                }
            }
            group.addTask {
                try await interaction.watch()
                throw CancellationError()
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            if interaction.isInterrupted { throw Interruption.browserChanged }
            return result
        }
    }

    /// Only structured native tool events can arm or interrupt a run. Agent prose, shell
    /// output, app snapshots and other MCP servers never control the interaction monitor.
    static func progress(from line: String,
                         onNativeCall: (NativeCall) -> Void = { _ in }) throws -> [String] {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = event["type"] as? String,
              let item = event["item"] as? [String: Any] else { return [] }

        if kind == "item.completed", isBrowserInterruption(item) {
            Log("computer use: browser interruption source=helper tool=\(item["tool"] as? String ?? "unknown")")
            throw Interruption.browserChanged
        }

        if item["type"] as? String == "mcp_tool_call",
           item["server"] as? String == "sentient_native", let id = item["id"] as? String {
            if kind == "item.completed" {
                onNativeCall(.completed(id: id))
            } else if kind == "item.started", let tool = item["tool"] as? String,
                      appTools.contains(tool), let arguments = item["arguments"] as? [String: Any],
                      let app = arguments["app"] as? String {
                onNativeCall(.started(id: id, app: app, tool: tool))
            }
        }

        switch (kind, item["type"] as? String) {
        case ("item.completed", "agent_message"):
            guard let text = item["text"] as? String else { return [] }
            return ["codex"] + text.components(separatedBy: .newlines)
        case ("item.started", "command_execution"):
            guard let command = item["command"] as? String else { return [] }
            // Preserve the existing knowledge-read bloom without displaying command output.
            return ["exec", command, "codex"]
        case ("item.started", "mcp_tool_call"):
            let label = [item["server"] as? String, item["tool"] as? String]
                .compactMap { $0 }.joined(separator: ".")
            return label.isEmpty ? [] : ["codex", "→ \(label)"]
        case ("item.started", "web_search"):
            return ["codex", (item["query"] as? String).map { "🔎 \($0)" } ?? "🔎 searching…"]
        default:
            return []
        }
    }

    private static let appTools: Set<String> = [
        "get_app_state",
        "click", "double_click", "right_click", "drag", "scroll", "press_key",
        "type_text", "set_value", "select_text", "perform_secondary_action"
    ]

    private static func isBrowserInterruption(_ item: [String: Any]) -> Bool {
        guard item["type"] as? String == "mcp_tool_call",
              item["server"] as? String == "sentient_native",
              let tool = item["tool"] as? String, appTools.contains(tool) else { return false }

        if let error = item["error"] as? [String: Any], let message = error["message"] as? String,
           changedBrowser(in: message, transportError: true) { return true }

        guard item["status"] as? String == "failed",
              let result = item["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]] else { return false }
        return content.contains { block in
            block["type"] as? String == "text"
                && (block["text"] as? String).map { changedBrowser(in: $0) } == true
        }
    }

    private static func changedBrowser(in message: String, transportError: Bool = false) -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // A transport error may wrap the helper diagnostic; failed-result content must be
        // the diagnostic itself. Never search arbitrary UI text for a matching substring.
        let prefix = transportError ? #"^(?:[^\n]*?\b)?"# : "^"
        let pattern = prefix + #"The user changed '([^'\n]+)'\.\s+Re-query the latest state with `get_app_state` before sending more actions\.$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return false }
        return BrowserInteractionMonitor.Browser(target: String(text[range])) != nil
    }
}
