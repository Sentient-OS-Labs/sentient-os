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
        switch ModelBackend.current {
        case .claude:           return try await ClaudeCLI.shared.run(invocation, onLine: onLine)
        case .chatgpt, .custom: return try await CodexCLI.shared.run(invocation, onLine: onLine)
        }
    }

    /// The computer-use spine — Sidekick, the command bar, a card's fire.
    static func runAgentCommand(_ prompt: String, imagePaths: [String] = [],
                                timeout: TimeInterval = 1_800,
                                onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        switch ModelBackend.current {
        case .claude:
            return try await ClaudeCLI.shared.runAgentCommand(prompt, imagePaths: imagePaths,
                                                              timeout: timeout, onLine: onLine)
        case .chatgpt, .custom:
            return try await CodexCLI.shared.runAgentCommand(prompt, imagePaths: imagePaths,
                                                             timeout: timeout, onLine: onLine)
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
