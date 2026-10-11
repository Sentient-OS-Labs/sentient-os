// Reads Codex computer-task events for Sidekick recovery and formats progress.
// Stops on native window-access failures so the notch can offer an actionable retry.
// Recovery observes tool activity before model-specific narration filters the stream.
// Doc: Documentation - Cloud - CodexCLI (the codex exec spine).md

import Foundation
import AppKit

nonisolated enum ComputerUseStream {
    /// Keep recovery's tool tracking active even when Claude supplies its own narration.
    static func run(binary: String, args: [String], timeout: TimeInterval,
                    extraEnv: [String: String] = [:], narrate: Bool = true,
                    onLine: @escaping @Sendable (String) -> Void) async throws -> CodexCLI.ExecResult {
        let recovery = SidekickInteraction.current
        let diagnostics = AgentRunDiagnostics.current
        let result = try await CodexCLI.executeStreaming(binary: binary, args: args, timeout: timeout, extraEnv: extraEnv) { line in
            diagnostics?.observe(line)
            try recovery?.observeToolEvent(line)
            if let failure = windowUnavailable(from: line) { throw failure }
            if narrate { progress(from: line).forEach(onLine) }
        }
        diagnostics?.recordProcess(status: result.status)
        return result
    }

    struct WindowUnavailable: LocalizedError {
        let app: String?

        var errorDescription: String? {
            let name = app ?? "the app"
            return "Sidekick can’t reach \(name)’s window. Keep \(name) open on the same desktop you’re using, then try again."
        }
    }

    /// This error means no usable window, not proof of a Space change. Only inspect an
    /// explicitly failed native result; app contents and model narration are not signals.
    static func windowUnavailable(from line: String) -> WindowUnavailable? {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["type"] as? String == "item.completed",
              let item = event["item"] as? [String: Any],
              item["type"] as? String == "mcp_tool_call",
              item["server"] as? String == "sentient_native",
              let result = item["result"] as? [String: Any],
              item["status"] as? String == "failed" || result["isError"] as? Bool == true,
              let content = result["content"] as? [[String: Any]],
              content.contains(where: {
                  $0["type"] as? String == "text" &&
                  ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "Computer Use server error -10005: noWindowsAvailable"
              }) else { return nil }

        let arguments = item["arguments"] as? [String: Any]
        return WindowUnavailable(app: appName(arguments?["app"] as? String))
    }

    private static func appName(_ selector: String?) -> String? {
        guard let selector = selector?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selector.isEmpty, selector.count <= 1024,
              selector.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == selector || $0.bundleURL?.path == selector ||
            $0.localizedName?.caseInsensitiveCompare(selector) == .orderedSame
        }), let name = app.localizedName { return name }
        // Paths and bundle identifiers are valid selectors, but should not be notch copy.
        if selector.hasSuffix(".app") {
            return URL(fileURLWithPath: selector).deletingPathExtension().lastPathComponent
        }
        guard !selector.contains("/"), !selector.contains("."), selector.count <= 80 else { return nil }
        return selector
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
            if item["server"] as? String == SidekickToolServer.name,
               item["tool"] as? String == SidekickTaskSummary.toolName { return [] }
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
