//
// HostedToolPolicy.swift
// Shared transport for the app's Slack and Outlook permission hooks. Providers own their
// decisions; this helper composes hooks, bounds input and atomically reserves operations.
// Doc: Documentation - Cloud - CodexCLI (the codex exec spine).md
//

import Foundation
import Darwin

nonisolated enum HostedToolPolicy {
    struct Rule { let matcher: String; let command: String }

    static func codexArguments(_ rules: [Rule]) -> [String] {
        guard !rules.isEmpty else { return [] }
        let hooks = rules.map {
            "{matcher=\(DirectMCPRuntime.quoted($0.matcher)),hooks=[{type=\"command\",command=\(DirectMCPRuntime.quoted($0.command)),timeout=10}]}"
        }.joined(separator: ",")
        return ["--dangerously-bypass-hook-trust", "-c", "features.hooks=true", "-c", "hooks.PreToolUse=[\(hooks)]"]
    }
    static func claudeSettings(_ base: String, adding rule: Rule, event: String = "PreToolUse") throws -> String {
        guard let data = base.data(using: .utf8),
              var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var pre = hooks[event] as? [[String: Any]] ?? []
        pre.append(["matcher": rule.matcher, "hooks": [["type": "command", "command": rule.command, "timeout": 10]]])
        hooks[event] = pre; settings["hooks"] = hooks
        return String(data: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), encoding: .utf8)!
    }
    static func readInput(limit: Int = 65_536) throws -> (name: String, input: [String: Any]) {
        let value = try readEnvelope(limit: limit)
        guard value["hook_event_name"] as? String == "PreToolUse",
              let name = value["tool_name"] as? String, let input = value["tool_input"] as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
        return (name, input)
    }
    static func readEnvelope(limit: Int = 65_536) throws -> [String: Any] {
        var data = Data()
        while data.count <= limit {
            let chunk = try FileHandle.standardInput.read(upToCount: min(4_096, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= limit, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
        return value
    }
    static func respond(allowed: Bool, service: String) throws -> Int32 {
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse",
            "permissionDecision": allowed ? "allow" : "deny",
            "permissionDecisionReason": allowed ? "Reviewed \(service) operation." : "This \(service) operation is outside the permitted task policy."]]
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: output))
        return 0
    }
    static func claim(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}
