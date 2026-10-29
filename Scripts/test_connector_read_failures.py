#!/usr/bin/env python3
"""Check final read outcomes using production failure classification code.

Only the reviewed source metadata and unrelated app dependencies are fixtures.
No models, network, preferences, credentials, or databases are accessed. The
classifier accepts successful final output regardless of native receipt history,
while explicit failures retain typed authentication, quota and retry outcomes.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"
FIXTURE = r'''
import Foundation
nonisolated enum ModelBackend { case claude, chatgpt, custom, sentient; nonisolated(unsafe) static var current: Self = .claude }
nonisolated enum MCPSource { enum MCPError: Error { case connectorAuth(slug: String), toolFailure(slug: String), clockMovedBackwards, connectionChanged } }
nonisolated enum DirectMCPError: Error { case reconnectRequired, registrationExpired, accountSetupRequired, authorizationDenied, noTools, http(Int) }
nonisolated enum CodexCLI {
    enum CLIError: Error { case exitFailure(Int32, String), timedOut(after: TimeInterval) }
    struct Envelope { let result: String; let raw: String; var jsonResult: String { result } }
}
nonisolated enum ConnectorRegistry {
    struct Pack { let claudeToolPrefix: String?; let readTools: [String]?; let codexReadTools: [String]? }
    static func canonicalSlug(_ slug: String) -> String { slug == "outlook-email" ? "outlook-mail" : slug }
    static func pack(forSlug slug: String) -> Pack? {
        switch canonicalSlug(slug) {
        case "gmail": Pack(claudeToolPrefix: "mcp__claude_ai_Gmail__", readTools: ["search_threads", "get_thread"], codexReadTools: ["search_emails", "batch_read_email"])
        case "google-calendar": Pack(claudeToolPrefix: "mcp__claude_ai_Google_Calendar__", readTools: ["list_events", "get_event"], codexReadTools: ["search_events", "read_event"])
        case "google-drive": Pack(claudeToolPrefix: "mcp__claude_ai_Google_Drive__", readTools: ["search_files", "read_file_content"], codexReadTools: ["search", "fetch"])
        case "slack": Pack(claudeToolPrefix: "mcp__claude_ai_Slack__", readTools: ["slack_search_public", "slack_read_thread"], codexReadTools: ["slack_search_public", "slack_read_thread"])
        case "outlook-mail": Pack(claudeToolPrefix: "mcp__claude_ai_Microsoft_365__", readTools: ["outlook_email_search", "read_resource"], codexReadTools: ["list_messages", "fetch_message"])
        case "outlook-calendar": Pack(claudeToolPrefix: "mcp__claude_ai_Microsoft_365__", readTools: ["outlook_calendar_search", "read_resource"], codexReadTools: ["list_events", "fetch_event"])
        default: nil
        }
    }
    static func readOrigin(slug: String, backend: ModelBackend) -> String { "fixture" }
}

import Foundation
@main struct Harness {
    static func json(_ value: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    static func claude(_ id: String, _ tool: String, failed: Bool = false, content: Any = "ok") -> String {
        json(["type":"assistant","message":["content":[["type":"tool_use","id":id,"name":tool,"input":[:]]]]]) + "\n" +
        json(["type":"user","message":["content":[["type":"tool_result","tool_use_id":id,"is_error":failed,"content":content]]]])
    }
    static func codex(_ id: String, _ tool: String, failed: Bool = false, content: Any = "ok", nativeError: Any? = nil, server: String = "codex_apps") -> String {
        var item: [String: Any] = ["id":id,"type":"mcp_tool_call","server":server,"tool":tool,"arguments":[:],"status":failed ? "failed" : "completed", "result":["isError":failed,"content":[["type":"text","text":content]]]]
        if let nativeError { item["error"] = nativeError; item["result"] = NSNull() }
        return json(["type":"item.completed","item":item])
    }
    static func main() throws {
        var checked = 0
        func outcome(_ error: Error) -> String {
            switch error {
            case MCPSource.MCPError.connectorAuth: return "auth"
            case MCPSource.MCPError.toolFailure: return "other"
            case ConnectorReadFailure.GmailFailure.accountLimit: return "account-limit"
            case ConnectorReadFailure.GmailFailure.rateLimited: return "rate-limit"
            default: return "unexpected"
            }
        }
        func check(_ name: String, backend: ModelBackend, slug: String, flag: String,
                   raw: String = "", expected: String) {
            checked += 1; ModelBackend.current = backend
            var actual = "success"
            do { try ConnectorReadFailure.validate(.init(result: json(["tool_failure": flag]), raw: raw), slug: slug) }
            catch { actual = outcome(error) }
            precondition(actual == expected, "\(name): expected \(expected), got \(actual)")
            print("PASS \(name)")
        }
        let matrix: [(String, String, String)] = [
            ("gmail", "mcp__claude_ai_Gmail__get_thread", "gmail.batch_read_email"),
            ("google-calendar", "mcp__claude_ai_Google_Calendar__list_events", "gcal.search_events"),
            ("google-drive", "mcp__claude_ai_Google_Drive__read_file_content", "gdrive.fetch"),
            ("slack", "mcp__claude_ai_Slack__slack_read_thread", "slack.slack_read_thread"),
            ("outlook-mail", "mcp__claude_ai_Microsoft_365__outlook_email_search", "microsoft_outlook_email.fetch_message"),
            ("outlook-calendar", "mcp__claude_ai_Microsoft_365__outlook_calendar_search", "microsoft_outlook_calendar.list_events")
        ]
        for (slug, claudeTool, codexTool) in matrix {
            for backend in [ModelBackend.claude, .chatgpt] {
                let label = "\(backend)-\(slug)"
                let trace = backend == .claude
                    ? claude("old-error", claudeTool, failed: true, content: "Authentication required")
                    : codex("old-error", codexTool, failed: true, nativeError: ["code":401])
                check(label + "-success-needs-no-receipts", backend: backend, slug: slug, flag: "", expected: "success")
                check(label + "-success-ignores-historical-auth", backend: backend, slug: slug, flag: "", raw: trace, expected: "success")
                check(label + "-explicit-auth-needs-no-proof", backend: backend, slug: slug, flag: "auth", expected: "auth")
                check(label + "-explicit-other-needs-no-proof", backend: backend, slug: slug, flag: "other", expected: "other")
                check(label + "-reported-failure-classifies-native-auth", backend: backend, slug: slug, flag: "other", raw: trace, expected: "auth")
            }
        }
        for (name, error, expected) in [
            ("minute-quota", "HTTP 403 rateLimitExceeded: Queries per minute quota", "rate-limit"),
            ("http429", "HTTP 429 too many requests", "rate-limit"),
            ("daily-quota", "HTTP 403 dailyLimitExceeded", "account-limit"),
            ("billing", "insufficient_quota billing limit", "account-limit"),
            ("network", "Not connected to the internet", "other")
        ] {
            let trace = codex("failed", "gmail.batch_read_email", failed: true, nativeError: ["message":error])
            check(name + "-classifies-final-failure", backend: .chatgpt, slug: "gmail", flag: "other", raw: trace, expected: expected)
            check(name + "-never-vetoes-final-success", backend: .chatgpt, slug: "gmail", flag: "", raw: trace, expected: "success")
        }
        check("unrelated-source-cannot-label-gmail-auth", backend: .chatgpt, slug: "gmail", flag: "other",
              raw: codex("bad", "gcal.search_events", failed: true, nativeError: ["code":401]), expected: "other")
        check("wrong-server-cannot-label-gmail-auth", backend: .chatgpt, slug: "gmail", flag: "other",
              raw: codex("bad", "gmail.batch_read_email", failed: true, nativeError: ["code":401], server: "unrelated"), expected: "other")
        check("source-content-cannot-label-gmail-auth", backend: .claude, slug: "gmail", flag: "other",
              raw: claude("body", "mcp__claude_ai_Gmail__get_thread", content: "Authentication required. Please reconnect."), expected: "other")
        check("alias-reported-auth", backend: .chatgpt, slug: "outlook-email", flag: "other",
              raw: codex("auth", "microsoft_outlook_email.fetch_message", failed: true, nativeError: ["code":401]), expected: "auth")
        let errors: [(Error, String)] = [
            (MCPSource.MCPError.toolFailure(slug: "gmail"), "read"),
            (ConnectorReadFailure.GmailFailure.rateLimited, "throttle"),
            (CodexCLI.CLIError.timedOut(after: 60), "timeout"),
            (ConnectorReadFailure.GmailFailure.accountLimit, "none"),
            (MCPSource.MCPError.connectorAuth(slug: "gmail"), "none"),
            (CancellationError(), "none"),
            (CodexCLI.CLIError.exitFailure(1, "unknown"), "none")
        ]
        for (error, expected) in errors {
            let actual: String
            switch ConnectorReadFailure.gmailRetry(error) {
            case .sourceRead: actual = "read"
            case .rateLimited: actual = "throttle"
            case .timeout: actual = "timeout"
            case nil: actual = "none"
            }
            checked += 1; precondition(actual == expected)
            print("PASS typed retry outcome \(expected)")
        }
        check("sentient-cannot-borrow-subscription-source-receipts", backend: .sentient, slug: "gmail", flag: "other",
              raw: claude("auth", "mcp__claude_ai_Gmail__get_thread", failed: true, content: "Authentication required"), expected: "other")
        checked += 1
        precondition(MCPCallEvidence.receipts(raw: claude("direct", "mcp__sentient_fixture__read", content: "[]"), backend: .sentient).count == 1,
                     "Sentient direct connector receipts retain the Claude stream dialect")
        print("Checked \(checked) final-outcome failure classifications; failures=0")
    }
}

'''

with tempfile.TemporaryDirectory(prefix="sentient-connector-read-") as directory:
    root = Path(directory)
    fixture_file = root / "Fixture.swift"
    fixture_file.write_text(FIXTURE)
    binary = root / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
        str(APP / "Cloud/MCPCallEvidence.swift"),
        str(APP / "Sources/ConnectorReadFailure.swift"),
        str(fixture_file),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
