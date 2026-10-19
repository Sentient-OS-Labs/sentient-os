#!/usr/bin/env python3
"""Run both production envelope parsers against clean, truncated and failed JSONL.

The parser methods are extracted verbatim from the app sources because their enclosing
CLI types depend on the whole application. Only process payload/error types and external
diagnostic sinks are fixtures. No process, provider, network, preferences or app is used.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"


def parser(name: str, start: str, end: str) -> str:
    source = (APP / "Cloud" / name).read_text()
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


CODEX = parser("CodexCLI.swift", "    private static func parseEnvelope(",
               "    /// Reduce one raw `--json`")
CLAUDE = parser("ClaudeCLI.swift", "    static func parseEnvelope(",
                "    /// Reduce one stream-json line")

SUPPORT = r'''
import Foundation
nonisolated enum CodexCLI {
    struct ExecResult { let status: Int32; let stdout: String; let stderr: String }
    struct Envelope {
        let result: String; let sessionID: String?; let numTurns: Int?; let durationMS: Int?
        let inputTokens: Int?; let cachedInputTokens: Int?; let outputTokens: Int?; let raw: String
    }
    enum CLIError: Error {
        case inputTooLarge(chars: Int), usageLimit(message: String, sessionID: String?)
        case exitFailure(code: Int32, message: String), badEnvelope(String)
    }
    static let usageLimitMarkers = ["usage limit", "rate limit"]
    static func noteStaleSignatureIfPresent(_ value: String) {}
    static func staleClientError(in values: String...) -> CLIError? { nil }
    static func failureDetail(_ out: ExecResult) -> String { out.stderr.isEmpty ? out.stdout : out.stderr }
    static func parse(_ out: ExecResult, completion: AgentStatus? = nil) throws -> Envelope {
        try parseEnvelope(out, durationMS: 123, completion: completion)
    }
__CODEX__
}
nonisolated enum ClaudeCLI {
    static let usageLimitMarkers = ["usage limit", "rate limit"]
    static func noteRateLimit(_ info: [String: Any]) {}
__CLAUDE__
}
'''

TESTS = r'''
import Foundation
@main struct EnvelopeTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        func json(_ value: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
        }
        func out(_ lines: [String], status: Int32 = 0) -> CodexCLI.ExecResult {
            .init(status: status, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
        }
        func rejects(_ label: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(label) } catch { checks += 1 }
        }
        let start = json(["type": "thread.started", "thread_id": "fixture"])
        let completed = json(["type": "turn.completed", "usage": ["input_tokens": 10, "output_tokens": 2]])
        let failed = json(["type": "turn.failed", "error": ["message": "Provider disconnected"]])
        let emptyFailed = json(["type": "turn.failed"])
        let message = json(["type": "item.completed", "item": ["type": "agent_message", "text": "Legacy answer\nSTATUS: DONE"]])
        let task = json(["type": "item.started", "item": ["type": "command_execution", "command": "fixture"]])
        let finished = out([start, completed])
        for claim: AgentStatus in [.done, .couldNot(reason: "Could not finish")] {
            let envelope = try CodexCLI.parse(finished, completion: claim)
            check(envelope.result.isEmpty && envelope.inputTokens == 10, "Codex tool-only answer accepts clean terminal receipt")
            check(AgentStatus.resolve(envelope.result, completion: claim, providerSucceeded: true) == claim,
                  "Codex empty envelope retains explicit done/refusal outcome without synthetic prose")
        }
        for claim: AgentStatus? in [nil, AgentStatus.none] {
            rejects("Codex background/unknown completion still requires payload") { _ = try CodexCLI.parse(finished, completion: claim) }
        }
        for lines in [[start], [start, task], [start, completed, task], [start, completed, "{truncated"],
                      [start, failed], [start, completed, failed], [start, failed, completed], [start, completed, emptyFailed]] {
            rejects("Codex receipt cannot bless incomplete or failed stream") { _ = try CodexCLI.parse(out(lines), completion: .done) }
        }
        rejects("Codex exit failure wins receipt") { _ = try CodexCLI.parse(out([start, completed], status: 1), completion: .done) }
        rejects("Codex terminal error wins earlier prose and receipt") { _ = try CodexCLI.parse(out([start, message, completed, failed]), completion: .done) }
        check(try CodexCLI.parse(out([start, message, completed])).result.contains("Legacy answer"), "Codex ordinary output unchanged")
        check(try CodexCLI.parse(out([start, json(["type":"error", "message":"Reconnecting"]), completed]), completion: .done).result.isEmpty,
              "Codex recovered intermediate error permits later clean completion")

        let initClaude = json(["type":"system", "subtype":"init", "session_id":"claude-fixture"])
        let result = json(["type":"result", "subtype":"success", "is_error":false,
                           "result":"", "usage":["input_tokens":10, "cache_creation_input_tokens":2, "cache_read_input_tokens":3]])
        let error = json(["type":"result", "subtype":"error_during_execution", "is_error":true, "errors":["Provider disconnected"]])
        let claudeFinished = out([initClaude, result])
        for claim: AgentStatus in [.done, .couldNot(reason: "Could not finish")] {
            let envelope = try ClaudeCLI.parseEnvelope(claudeFinished, durationMS: 123, completion: claim)
            check(envelope.result.isEmpty && envelope.inputTokens == 15, "Claude tool-only answer accepts clean terminal receipt")
            check(AgentStatus.resolve(envelope.result, completion: claim, providerSucceeded: true) == claim,
                  "Claude empty envelope retains actual structured outcome")
        }
        for claim: AgentStatus? in [nil, AgentStatus.none] {
            rejects("Claude background/unknown completion still requires payload") { _ = try ClaudeCLI.parseEnvelope(claudeFinished, durationMS: 1, completion: claim) }
        }
        for lines in [[initClaude], [initClaude, result, "{truncated"], [initClaude, result, initClaude],
                      [initClaude, error], [initClaude, result, error], [initClaude, error, result],
                      [initClaude, json(["type":"result", "is_error":false, "result":""])],
                      [initClaude, json(["type":"result", "subtype":"success", "result":""])],
                      [initClaude, json(["type":"result", "subtype":"error_max_turns", "is_error":false, "result":""])]] {
            rejects("Claude receipt cannot bless incomplete or failed stream") { _ = try ClaudeCLI.parseEnvelope(out(lines), durationMS: 1, completion: .done) }
        }
        rejects("Claude exit failure wins receipt") { _ = try ClaudeCLI.parseEnvelope(out([initClaude, result], status: 1), durationMS: 1, completion: .done) }
        let ordinary = json(["type":"result", "subtype":"success", "is_error":false, "result":"Ordinary answer"])
        check(try ClaudeCLI.parseEnvelope(out([initClaude, ordinary]), durationMS: 1).result == "Ordinary answer", "Claude ordinary output unchanged")
        rejects("Claude terminal failure wins existing text") { _ = try ClaudeCLI.parseEnvelope(out([initClaude, error, ordinary]), durationMS: 1, completion: .done) }
        let structured = json(["type":"result", "subtype":"success", "is_error":false, "structured_output":["answer":42]])
        check(try ClaudeCLI.parseEnvelope(out([initClaude, structured]), durationMS: 1).result.contains("42"), "Claude schema payload remains available without receipt")
        print("PASS \(checks) production envelope completion assertions")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-completion-envelopes-") as temporary:
    root = Path(temporary)
    support = root / "Parsers.swift"
    support.write_text(SUPPORT.replace("__CODEX__", CODEX).replace("__CLAUDE__", CLAUDE))
    tests = root / "Tests.swift"
    tests.write_text(TESTS)
    executable = root / "tests"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                    "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
                    str(APP / "Cloud/AgentStatus.swift"), str(support), str(tests), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
