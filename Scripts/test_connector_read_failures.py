#!/usr/bin/env python3
"""Check hosted read failures using real production receipt/read validation code.

Only the reviewed source metadata and unrelated app dependencies are fixtures.
No models, network, preferences, credentials, or databases are accessed. The
real Google read validation also proves that missing/auth-failed reads cannot
be mistaken for a successful empty window.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"
FIXTURE = r'''
import Foundation
nonisolated enum ModelBackend { case claude, chatgpt, custom; nonisolated(unsafe) static var current: Self = .claude }
nonisolated enum MCPSource { enum MCPError: Error { case connectorAuth(slug: String), toolFailure(slug: String), clockMovedBackwards, connectionChanged } }
nonisolated enum DirectMCPError: Error { case reconnectRequired, registrationExpired, accountSetupRequired, authorizationDenied, noTools, http(Int) }
nonisolated enum CodexCLI {
    struct Envelope { let result: String; let raw: String; var jsonResult: String { result } }
    struct Invocation { var prompt: String; var connectorOnlyRead = false; var webSearch = false }
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
nonisolated enum PIIScan { static func containsHighRiskPII(_ value: String) -> Bool { false } }
nonisolated enum FrontierRun { static func run(_ invocation: CodexCLI.Invocation) async throws -> CodexCLI.Envelope { fatalError("No real frontier calls allowed") } }
nonisolated enum Diagnostics { enum Event { case modelOutputInvalid }; enum Phase { case parse, validate }; enum Count: Hashable { case bytes, retries }; enum Flag: Hashable { case previousStateRetained }; static func report(_ event: Event, phase: Phase, reason: String, source: String, counts: [Count: Int], flags: [Flag: Bool]) {} }
nonisolated struct NoteDraft {}
nonisolated struct ItemKey { let order: TimeInterval; let tiebreak: String }
actor CycleStore { static let shared = CycleStore(); enum Outcome { case saved, diskFull }; func commitMCPRead(bucketKey: String, notes: [NoteDraft], through: ItemKey, origin: String, replaceNotes: Bool) -> Outcome { fatalError("No actual storage writes allowed") } }
nonisolated func Log(_ message: String) {}

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
        let quiet = #"{"thread_count":0,"notable":false,"has_action_items":false,"summary":"","tool_failure":""}"#
        var failures = 0
        var checked = 1
        func check(_ name: String, _ raw: String, expectedAuth: Bool, backend: ModelBackend = .claude, slug: String = "gmail", result: String? = nil) {
            checked += 1
            ModelBackend.current = backend
            var auth = false
            do { try ConnectorReadFailure.validate(.init(result: result ?? quiet, raw: raw), slug: slug) }
            catch MCPSource.MCPError.connectorAuth { auth = true }
            catch { failures += 1; print("FAIL \(name): unexpected error"); return }
            if auth != expectedAuth { failures += 1; print("FAIL \(name): expected auth=\(expectedAuth), actual=\(auth)") }
            else { print("PASS \(name)") }
        }
        let authFailure = claude("failure", "mcp__claude_ai_Gmail__get_thread", failed: true, content: "Authentication required. Please reconnect.")
        check("failed-auth-alone", authFailure, expectedAuth: true)
        check("tool-search-must-not-mask-auth", claude("search", "ToolSearch") + "\n" + authFailure, expectedAuth: true)
        check("wait-must-not-mask-auth", claude("wait", "WaitForMcpServers") + "\n" + authFailure, expectedAuth: true)
        let searched = claude("discovery", "mcp__claude_ai_Gmail__search_threads") + "\n" + authFailure
        check("prior-discovery-must-not-mask-auth", searched, expectedAuth: true)
        check("other-source-failure-is-not-gmail", claude("other", "mcp__claude_ai_Google_Calendar__list_events", failed: true, content: "Authentication required"), expectedAuth: false)
        check("codex-native-error", codex("native", "gmail.batch_read_email", failed: true, nativeError: ["message":"Authentication required"]), expectedAuth: true, backend: .chatgpt)
        // The exact old failure: a successful search masks the failed fetch, allowing a quiet commit.
        ModelBackend.current = .claude
        do {
            let env = CodexCLI.Envelope(result: quiet, raw: searched)
            try ConnectorReadFailure.validate(env, slug: "gmail")
            _ = try GoogleSourceRead.parse(env.result, countKey: "thread_count", cap: 300)
            try GoogleSourceRead.validateDiscovery(env, slug: "gmail")
            failures += 1; print("FAIL google-quiet-auth-read-accepted")
        } catch MCPSource.MCPError.connectorAuth { print("PASS google-quiet-auth-read-rejected") }

        let matrix: [(String, String, String)] = [
            ("gmail", "mcp__claude_ai_Gmail__search_threads", "gmail.search_emails"),
            ("google-calendar", "mcp__claude_ai_Google_Calendar__list_events", "google_calendar.search_events"),
            ("google-drive", "mcp__claude_ai_Google_Drive__search_files", "gdrive.search"),
            ("slack", "mcp__claude_ai_Slack__slack_search_public", "slack.slack_search_public"),
            ("outlook-mail", "mcp__claude_ai_Microsoft_365__outlook_email_search", "microsoft_outlook_email.list_messages"),
            ("outlook-calendar", "mcp__claude_ai_Microsoft_365__outlook_calendar_search", "microsoft_outlook_calendar.list_events"),
        ]
        for (slug, claudeTool, codexTool) in matrix {
            let pack = ConnectorRegistry.pack(forSlug: slug)!
            let claudeFetch = pack.claudeToolPrefix! + pack.readTools!.last!
            let codexNamespace = codexTool.split(separator: ".").first!
            let codexFetch = String(codexNamespace) + "." + pack.codexReadTools!.last!
            check("claude-\(slug)-search-then-auth-fetch", claude("search", claudeTool, content: "[]") + "\n" + claude("fetch", claudeFetch, failed: true, content: "Authentication required"), expectedAuth: true, slug: slug)
            check("codex-\(slug)-search-then-auth-fetch", codex("search", codexTool, content: "[]") + "\n" + codex("fetch", codexFetch, failed: true, content: "Authentication required"), expectedAuth: true, backend: .chatgpt, slug: slug)
            check("claude-\(slug)-auth", claude("auth", claudeTool, failed: true, content: "Invalid_grant"), expectedAuth: true, slug: slug)
            check("codex-\(slug)-auth", codex("auth", codexTool, failed: true, content: "Invalid_token"), expectedAuth: true, backend: .chatgpt, slug: slug)
            check("claude-\(slug)-success-content", claude("content", claudeTool, content: "Authentication required. Please reconnect."), expectedAuth: false, slug: slug)
            check("codex-\(slug)-wrong-server", codex("auth", codexTool, failed: true, content: "Invalid_token", server: "unrelated"), expectedAuth: false, backend: .chatgpt, slug: slug)
        }
        check("explicit-auth-still-reported", searched, expectedAuth: true, result: #"{"tool_failure":"auth"}"#)
        check("claude-shared-suite-mail-is-not-calendar", claude("mail", "mcp__claude_ai_Microsoft_365__outlook_email_search", failed: true, content: "Unauthorized"), expectedAuth: false, slug: "outlook-calendar")
        check("codex-outlook-alias", codex("alias", "microsoft_outlook_email.fetch_message", failed: true, content: "Unauthorized"), expectedAuth: true, backend: .chatgpt, slug: "outlook-email")
        check("codex-calendar-alias", codex("alias", "gcal.search_events", failed: true, content: "Unauthorized"), expectedAuth: true, backend: .chatgpt, slug: "google-calendar")
        check("codex-qualified-tool", codex("qualified", "mcp__codex_apps__gmail__search_emails", failed: true, content: "Unauthorized"), expectedAuth: true, backend: .chatgpt)
        check("failed-unreviewed-tool", claude("unknown", "mcp__claude_ai_Gmail__unknown_tool", failed: true, content: "Unauthorized"), expectedAuth: false)
        check("failed-wait-is-not-source-auth", claude("wait", "WaitForMcpServers", failed: true, content: "Unauthorized"), expectedAuth: false)
        check("failed-tool-message-content-json", claude("content", "mcp__claude_ai_Gmail__get_thread", failed: true, content: #"{"messages":[{"body":"please reconnect"}],"subject":"invalid_grant"}"#), expectedAuth: false)
        check("failed-tool-quoted-subject", claude("content", "mcp__claude_ai_Gmail__get_thread", failed: true, content: #"Cannot parse message "please reconnect" because of a timeout"#), expectedAuth: false)
        check("failed-tool-single-quoted-content", claude("content", "mcp__claude_ai_Gmail__get_thread", failed: true, content: "Cannot parse message 'unauthenticated' because of a timeout"), expectedAuth: false)
        check("failed-tool-nested-auth-error", claude("auth", "mcp__claude_ai_Gmail__get_thread", failed: true, content: #"{"error":{"code":"invalid_grant"}}"#), expectedAuth: true)
        check("failed-tool-network-disconnected", claude("network", "mcp__claude_ai_Gmail__get_thread", failed: true, content: "Not connected to the internet"), expectedAuth: false)
        check("codex-native-numeric-auth", codex("status", "gmail.batch_read_email", failed: true, nativeError: ["code":401]), expectedAuth: true, backend: .chatgpt)
        check("codex-native-string-auth", codex("status", "gmail.batch_read_email", failed: true, nativeError: "Unauthenticated"), expectedAuth: true, backend: .chatgpt)
        check("codex-other-native-error", codex("status", "gmail.batch_read_email", failed: true, nativeError: ["message":"A timeout occurred"]), expectedAuth: false, backend: .chatgpt)
        check("custom-has-no-hosted-receipts", authFailure, expectedAuth: false, backend: .custom)
        // A complete successful empty discovery remains valid; missing discovery still fails.
        ModelBackend.current = .claude
        checked += 1
        let success = CodexCLI.Envelope(result: quiet, raw: claude("empty", "mcp__claude_ai_Gmail__search_threads", content: "[]"))
        try ConnectorReadFailure.validate(success, slug: "gmail")
        _ = try GoogleSourceRead.parse(success.result, countKey: "thread_count", cap: 300)
        try GoogleSourceRead.validateDiscovery(success, slug: "gmail")
        print("PASS actual-empty-discovery-stays-valid")
        checked += 1
        do {
            try GoogleSourceRead.validateDiscovery(.init(result: quiet, raw: ""), slug: "gmail")
            failures += 1; print("FAIL absent-discovery-accepted")
        } catch GoogleSourceRead.Failure.invalidResponse { print("PASS absent-discovery-rejected") }
        print("Checked \(checked) cases; failures=\(failures)")

        if failures != 0 { print("\(failures) regression checks failed"); exit(1) }
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
        str(APP / "Sources/GoogleSourceRead.swift"), str(fixture_file),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
