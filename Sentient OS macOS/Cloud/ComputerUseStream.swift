// Reads Codex computer-task events for Sidekick recovery and formats progress.
// Tool failures remain in the provider stream so the agent can recover or explain the blocker.
// Recovery observes tool activity before model-specific narration filters the stream.
// Doc: Documentation - Cloud - CodexCLI (the codex exec spine).md

import Foundation

nonisolated enum ComputerUseStream {
    /// Keep recovery's tool tracking active even when Claude supplies its own narration.
    static func run(binary: String, args: [String], timeout: TimeInterval,
                    extraEnv: [String: String] = [:], narrate: Bool = true,
                    onLine: @escaping @Sendable (String) -> Void) async throws -> CodexCLI.ExecResult {
        let recovery = SidekickInteraction.current
        let diagnostics = AgentRunDiagnostics.current
        let streamID = UUID()
        defer { recovery?.endExecution(streamID: streamID) }
        let result = try await CodexCLI.executeStreaming(binary: binary, args: args, timeout: timeout, extraEnv: extraEnv) { line in
            diagnostics?.observe(line)
            try recovery?.observeToolEvent(line, streamID: streamID)
            // Both providers use this executor for tools. Claude supplies its own prose,
            // but activity must come from the same actual execution events for both.
            progress(from: line, includeNarration: narrate).forEach(onLine)
        }
        diagnostics?.recordProcess(status: result.status)
        return result
    }

    static func progress(from line: String, includeNarration: Bool = true) -> [String] {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = event["type"] as? String,
              let item = event["item"] as? [String: Any] else { return [] }

        switch (kind, item["type"] as? String) {
        case ("item.completed", "agent_message"):
            guard includeNarration else { return [] }
            guard let text = item["text"] as? String else { return [] }
            return ["codex"] + text.components(separatedBy: .newlines)
        case ("item.started", "command_execution"):
            guard let command = item["command"] as? String else { return [] }
            // Preserve the existing knowledge-read bloom without displaying command output.
            return ["exec", command, "codex", "→ command_execution"]
        case ("item.started", "mcp_tool_call"):
            if SidekickConversationRun.hidden(server: item["server"] as? String ?? "",
                                              tool: item["tool"] as? String ?? "") { return [] }
            let label = [item["server"] as? String, item["tool"] as? String]
                .compactMap { $0 }.joined(separator: ".")
            return label.isEmpty ? [] : ["codex", "→ \(label)"]
        case ("item.started", "web_search"):
            return ["codex", (item["query"] as? String).map { "🔎 \($0)" } ?? "🔎 searching…"]
        default:
            return []
        }
    }

}
