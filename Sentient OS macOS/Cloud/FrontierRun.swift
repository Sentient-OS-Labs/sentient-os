//
//  FrontierRun.swift
//  Sentient OS macOS
//
//  The ONE dispatch seam between the two frontier engines. Every caller that used to talk to
//  CodexCLI.shared directly talks to this instead; the switch on ModelBackend picks the harness:
//   - .chatgpt / .custom → CodexCLI (`codex exec`; custom endpoints ride codex's provider overrides)
//   - .claude            → ClaudeCLI (`claude -p`)
//  Both engines speak the same types (CodexCLI.Invocation / Envelope / CLIError), so callers,
//  their catch blocks, and the diagnostics classifiers never care which harness ran. Deliberately
//  a dispatcher, not a protocol (decision 2026-08-21): two engines, one switch, zero ceremony.
//
//  Doc: Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md
//

import Foundation

enum FrontierRun {

    /// The structured spine — vault, judge, research, connectors, gift letter.
    static func run(_ invocation: CodexCLI.Invocation,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> CodexCLI.Envelope {
        var invocation = invocation
        let workspace = invocation.connectorOnlyRead || invocation.toolsDisabled
            ? FileManager.default.temporaryDirectory.appending(path: "sentient-connector-read-\(UUID().uuidString)") : nil
        if let workspace {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            invocation.cwd = workspace.path
        }
        defer { if let workspace { try? FileManager.default.removeItem(at: workspace) } }
        let prepared = invocation
        let backend = ModelBackend.current
        return try await ModelBackend.$runOverride.withValue(backend) {
            if backend == .claude { await ConnectorClassifier.refreshCLIVersion() }
            let slugs = prepared.mcpActionServer.map { [$0] } ?? prepared.mcpReadConnectors
            let direct = try await DirectMCPRuntime.prepare(slugs: slugs,
                mode: prepared.mcpActionServer == nil ? .read : .action,
                subset: prepared.mcpReadToolNames, timeout: prepared.timeout)
            return try await DirectMCPRuntime.execute(direct) {
                let result: CodexCLI.Envelope
                switch backend {
                case .claude: result = try await ClaudeCLI.shared.run(prepared, onLine: onLine)
                case .chatgpt, .custom: result = try await CodexCLI.shared.run(prepared, onLine: onLine)
                }
                if prepared.mcpActionServer?.hasPrefix("direct-") == true, let attachment = direct.first,
                   !DirectMCPRuntime.hasSuccessfulCall(raw: result.raw, backend: backend, attachment: attachment) {
                    throw DirectMCPError.unconfirmedAction
                }
                return result
            }
        }
    }

    /// The computer-use spine — Sidekick, the command bar, a card's fire.
    static func runAgentCommand(_ prompt: String, imagePaths: [String] = [],
                                timeout: TimeInterval = 1_800,
                                onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        let backend = ModelBackend.current
        return try await ModelBackend.$runOverride.withValue(backend) {
            if backend == .claude { await ConnectorClassifier.refreshCLIVersion() }
            var attachments: [DirectMCPRuntime.Attachment] = []
            for connection in DirectMCPStore.connections().filter(\.usable) {
                do {
                    attachments += try await DirectMCPRuntime.prepare(slugs: [connection.slug], mode: .action, timeout: timeout)
                } catch {
                    try Task.checkCancellation()
                    Log("Direct MCP: unavailable connection excluded from computer-use task")
                }
            }
            let services = attachments.map { "- \($0.connection.displayName): \($0.connection.serverName)" }.joined(separator: "\n")
            let fullPrompt = prompt + (services.isEmpty ? "" : "\n\nDIRECT CONNECTED ACCOUNTS (use these exact accounts):\n\(services)\nPrefer these tools when they fit the requested task. Never repeat an uncertain write without checking whether it already succeeded.")
            return try await DirectMCPRuntime.execute(attachments) {
                switch backend {
                case .claude:
                    return try await ClaudeCLI.shared.runAgentCommand(fullPrompt, imagePaths: imagePaths,
                                                                      timeout: timeout, onLine: onLine)
                case .chatgpt, .custom:
                    return try await CodexCLI.shared.runAgentCommand(fullPrompt, imagePaths: imagePaths,
                                                                     timeout: timeout, onLine: onLine)
                }
            }
        }
    }

    /// Is the ACTIVE engine usable right now? (The availability probe behind health surfaces.)
    static func validate(force: Bool = false) async -> CodexCLI.Availability {
        switch ModelBackend.current {
        case .claude:           return await ClaudeCLI.shared.validate(force: force)
        case .chatgpt, .custom: return await CodexCLI.shared.validate(force: force)
        }
    }
}
