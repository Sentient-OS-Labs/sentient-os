//
// SlackToolPolicy.swift
// Per-run native checks before hosted Slack actions. Rejects unreviewed/destructive tools,
// draft consumption and reply broadcasts before execution, including computer-use runs.
// Doc: Documentation - Cloud - CodexCLI (the codex exec spine).md
//

import Foundation
import Darwin
import CryptoKit

nonisolated enum SlackToolPolicy {
    private static let matcher = ".*[Ss]lack.*"

    static func messageHash(_ message: String) -> String {
        SHA256.hash(data: Data(message.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func command(backend: ModelBackend, operation: SlackConnector.Operation, runID: UUID,
                        expectedMessage: String? = nil) -> String {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        return DirectMCPRuntime.shellQuote(executable) + " --slack-tool-policy " + backend.rawValue + " " + operation.rawValue + " " + runID.uuidString
            + " " + (expectedMessage.map(messageHash) ?? "-")
            + " || { echo 'Slack policy could not be verified.' >&2; exit 2; }"
    }

    static func codexArguments(operation: SlackConnector.Operation = .write, runID: UUID? = nil,
                               expectedMessage: String? = nil) -> [String] {
        let command = DirectMCPRuntime.quoted(Self.command(backend: .chatgpt, operation: operation,
                                                        runID: runID ?? UUID(), expectedMessage: expectedMessage))
        let hook = "hooks.PreToolUse=[{matcher=\"\(matcher)\",hooks=[{type=\"command\",command=\(command),timeout=10}]}]"
        // Only this signed app-authored hook is supplied in a hermetic invocation. Hook trust
        // is separate from tool approvals; remote approval and sandbox policy remain intact.
        return ["--dangerously-bypass-hook-trust", "-c", "features.hooks=true", "-c", hook]
    }

    static func claudeSettings(_ base: String, operation: SlackConnector.Operation = .write, runID: UUID? = nil,
                               expectedMessage: String? = nil) throws -> String {
        guard let data = base.data(using: .utf8),
              var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPSource.MCPError.noReadSurface(slug: "slack")
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var pre = hooks["PreToolUse"] as? [[String: Any]] ?? []
        pre.append(["matcher": matcher, "hooks": [["type": "command",
            "command": command(backend: .claude, operation: operation, runID: runID ?? UUID(), expectedMessage: expectedMessage), "timeout": 10]]])
        hooks["PreToolUse"] = pre
        settings["hooks"] = hooks
        return String(data: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), encoding: .utf8)!
    }

    static func allowed(name: String, input: [String: Any], backend: ModelBackend,
                        operation: SlackConnector.Operation, expectedMessageHash: String? = nil) -> Bool {
        let bare = SlackConnector.actionTools(backend: backend, operation: operation).first { tool in
            if backend == .claude { return name == SlackConnector.claudePrefix + tool }
            return ["slack." + tool, "mcp__codex_apps__slack_" + tool,
                    "mcp__codex_apps__slack." + tool, "mcp__codex_apps__slack__" + tool].contains(name)
        }
        guard let bare else { return false }
        if bare == "slack_send_message", let expectedMessageHash {
            guard let message = input["message"] as? String, messageHash(message) == expectedMessageHash else { return false }
        }
        if operation == .send, bare == "slack_create_conversation",
           input["channel_name"] != nil && !(input["channel_name"] is NSNull) { return false }
        if ["slack_send_message", "slack_send_message_draft", "slack_schedule_message"].contains(bare) {
            guard input["draft_id"] == nil || input["draft_id"] is NSNull,
                  input["reply_broadcast"] == nil || input["reply_broadcast"] is NSNull || input["reply_broadcast"] as? Bool == false else {
                return false
            }
        }
        return true
    }

    /// Runs before app initialization. Inputs are never printed, stored, or sent anywhere.
    static func runHelper(arguments: [String]) -> Int32 {
        guard arguments.count == 6, let backend = ModelBackend(rawValue: arguments[2]), backend != .custom,
              let operation = SlackConnector.Operation(rawValue: arguments[3]),
              let runID = UUID(uuidString: arguments[4]), arguments[5] == "-"
                || arguments[5].range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil else { return reject() }
        do {
            var data = Data()
            while data.count <= 65_536 {
                let chunk = try FileHandle.standardInput.read(upToCount: min(4_096, 65_537 - data.count)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            guard data.count <= 65_536, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["hook_event_name"] as? String == "PreToolUse",
                  let name = value["tool_name"] as? String, let input = value["tool_input"] as? [String: Any] else { return reject() }
            var allow = allowed(name: name, input: input, backend: backend, operation: operation,
                                expectedMessageHash: arguments[5] == "-" ? nil : arguments[5])
            if allow, operation == .send, name.hasSuffix("slack_send_message") {
                // Reserve before execution, including failures whose remote effects are unknown.
                // A single-send task cannot blindly send again in the same model run.
                allow = claimSend(runID: runID)
            }
            let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse",
                "permissionDecision": allow ? "allow" : "deny",
                "permissionDecisionReason": allow ? "Reviewed Slack operation." : "This Slack operation is outside the permitted task policy."]]
            try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: output))
            // A successful hook process returns its JSON decision. Exit 2 is the separate
            // stderr-based blocking protocol and must never discard the JSON deny decision.
            return 0
        } catch { return reject() }
    }
    private static func reject() -> Int32 {
        try? FileHandle.standardError.write(contentsOf: Data("Slack policy could not be verified.\n".utf8))
        return 2
    }
    private static func marker(_ runID: UUID) -> URL {
        URL(fileURLWithPath: "/private/tmp/sentient-slack-send-\(getuid())-\(runID.uuidString)")
    }
    static func claimSend(runID: UUID) -> Bool {
        let descriptor = open(marker(runID).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
    static func cleanup(runID: UUID) { try? FileManager.default.removeItem(at: marker(runID)) }
}
