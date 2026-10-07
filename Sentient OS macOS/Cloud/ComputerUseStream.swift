// Reads Codex computer-task events for Sidekick recovery and formats progress.
// Recovery observes tool activity before model-specific narration filters the stream.
// Doc: Documentation - Cloud - CodexCLI (the codex exec spine).md

import Foundation

nonisolated enum ComputerUseStream {
    /// Keep recovery's tool tracking active even when Claude supplies its own narration.
    static func run(binary: String, args: [String], timeout: TimeInterval,
                    extraEnv: [String: String] = [:], narrate: Bool = true,
                    onLine: @escaping @Sendable (String) -> Void) async throws -> CodexCLI.ExecResult {
        let recovery = SidekickInteraction.current
        return try await CodexCLI.executeStreaming(binary: binary, args: args, timeout: timeout, extraEnv: extraEnv) { line in
            try recovery?.observeToolEvent(line)
            if narrate { progress(from: line).forEach(onLine) }
        }
    }

    static func progress(from line: String) -> [String] {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = event["type"] as? String,
              let item = event["item"] as? [String: Any] else { return [] }

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

}
