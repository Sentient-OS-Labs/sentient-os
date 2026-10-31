#!/usr/bin/env python3
"""Exercise actual generic read/parser and native summary acceptance with synthetic transport.

Compiles the production read, invocation, parse and Granola summary functions unchanged,
plus complete production failure classification, MCP event parsing and PII filtering.
No network, credentials, preferences, provider sessions or user content are accessed.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"


def block(source: str, marker: str) -> str:
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


STUBS = r'''
import Foundation
import os
nonisolated enum ModelBackend: String, Sendable {
    case chatgpt, claude, custom, sentient
    @TaskLocal static var current: Self = .chatgpt
}
nonisolated enum ClaudeCLI { enum Model: Sendable { case sonnet, haiku } }
nonisolated enum DirectMCPError: Error { case reconnectRequired, registrationExpired, accountSetupRequired, authorizationDenied, noTools, http(Int) }
nonisolated struct DirectMCPConnection: Sendable { let providerSlug: String }
nonisolated enum DirectMCPStore { static func connection(_ slug: String) -> DirectMCPConnection? { nil } }
nonisolated enum CodexCLI {
    enum CLIError: Error { case usageLimit, notAvailable, timedOut(after: TimeInterval), exitFailure(Int32, String) }
    struct Envelope: Sendable {
        let result: String; let raw: String
        var jsonResult: String { result }
        let inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil
    }
    struct Invocation: Sendable {
        enum Model { case gpt6luna }; enum Effort { case medium }; enum Sandbox { case readOnly }
        var prompt: String; var feature = ""; var model: Model = .gpt6luna
        var effort: Effort = .medium; var sandbox: Sandbox = .readOnly; var webSearch = true
        var timeout: Double = 0; var mcpReadConnectors: [String] = []; var connectorOnlyRead = false
        var mcpReadToolNames: [String]?; var claudeModel: ClaudeCLI.Model?; var outputSchema: String?
        var outlookReadMode: MCPSource.ReadMode?; var outlookReadWindow: MCPSource.Window?
        var outlookCalendarReadPurpose: String?; var outlookCalendarReadWindow: MCPSource.Window?
        var outlookRunID: UUID?; var outlookKeepsReadBudget = false
    }
}
nonisolated enum ConnectorRegistry {
    struct Pack { var claudeToolPrefix: String?; var readTools: [String]?; var codexReadTools: [String]? }
    static func canonicalSlug(_ slug: String) -> String { slug }
    static func displayName(slug: String) -> String { slug }
    static func telemetrySlug(_ slug: String) -> String { slug }
    static func pack(forSlug slug: String) -> Pack? {
        .init(claudeToolPrefix: "mcp__fixture_" + slug + "__", readTools: ["search"], codexReadTools: ["search", "get_profile"])
    }
}
nonisolated struct Identity: Sendable { var backend: String { ModelBackend.current.rawValue }; var promptContext: String { "Synthetic account" } }
nonisolated enum SlackConnector { static var runIdentity: Identity? { Identity() }; static let knowledgeTools = ["slack_search_public_and_private"] }
nonisolated enum OutlookMailConnector { static let slug = "outlook-mail"; static var runIdentity: Identity? { Identity() }; static func knowledgeTools(_ backend: ModelBackend) -> [String] { ["list_messages"] } }
nonisolated enum OutlookCalendarConnector { static let slug = "outlook-calendar"; static var runIdentity: Identity? { Identity() }; static func knowledgeTools(_ backend: ModelBackend) -> [String] { ["search_events"] } }
nonisolated enum OutlookCalendarSource { static func purpose(_ mode: MCPSource.ReadMode) -> String { mode.rawValue } }
nonisolated enum OutlookToolPolicy { static func cleanup(runID: UUID) {} }
nonisolated enum NotionSource {
    static func read(connection: DirectMCPConnection, prompt: String, mode: MCPSource.ReadMode, window: MCPSource.Window, claudeModel: ClaudeCLI.Model?, onReceipt: MCPSource.ReceiptObserver?) async throws -> MCPSource.ReadOutcome { fatalError("Native IO must not execute") }
}
nonisolated enum CrashReporting { enum Level { case warning }; static func captureEvent(_ name: String, level: Level, tags: [String: String], extra: [String: String], fingerprint: [String], affectsOperation: Bool = true) { precondition(!affectsOperation, "Recoverable parse warning must not mark its parent failed") } }
nonisolated func Log(_ text: String) {}
nonisolated func ErrorLabel(_ error: Error) -> String { String(describing: error) }
actor Transport {
    enum Response: Sendable { case output(CodexCLI.Envelope), cancelled, quota, unavailable }
    static let shared = Transport()
    var replies: [Response] = []; var requests: [CodexCLI.Invocation] = []
    func reset(_ replies: [Response]) { self.replies = replies; requests = [] }
    func calls() -> Int { requests.count }
    func last() -> CodexCLI.Invocation? { requests.last }
    func run(_ request: CodexCLI.Invocation) throws -> CodexCLI.Envelope {
        requests.append(request); precondition(!replies.isEmpty, "Unexpected extra provider request")
        switch replies.removeFirst() {
        case .output(let envelope): return envelope
        case .cancelled: throw CancellationError()
        case .quota: throw CodexCLI.CLIError.usageLimit
        case .unavailable: throw CodexCLI.CLIError.notAvailable
        }
    }
}
nonisolated enum Diagnostics {
    @TaskLocal static var isolatedAttempt = false
    static func withOperation<T>(_ name: StaticString, propagatesFailure: Bool = true,
                                 isolation: isolated (any Actor)? = #isolation,
                                 _ body: () async throws -> T) async rethrows -> T {
        try await $isolatedAttempt.withValue(name.description == "mcp_read_attempt" && !propagatesFailure) { try await body() }
    }
}
nonisolated enum FrontierRun { static func run(_ invocation: CodexCLI.Invocation) async throws -> CodexCLI.Envelope {
    precondition(Diagnostics.isolatedAttempt, "A retry attempt must not mark its parent failed")
    return try await Transport.shared.run(invocation)
} }
'''

TESTS = r'''
@main struct Harness {
    static func json(_ object: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    static func reply(_ summary: String = "You have a $500 project to finish.", count: Int = 1, failure: String = "", actions: Bool = true) -> String {
        json(["item_count": count, "notable": !summary.isEmpty, "has_action_items": !summary.isEmpty && actions, "summary": summary, "tool_failure": failure])
    }
    static func main() async throws {
        var checks = 0
        func check(_ name: String, _ pass: Bool) { precondition(pass, name); checks += 1; print("PASS " + name) }
        let window = MCPSource.Window(lower: Date(timeIntervalSince1970: 100), upper: Date(timeIntervalSince1970: 200), label: "Synthetic")
        for backend: ModelBackend in [.chatgpt, .claude] {
            try await ModelBackend.$current.withValue(backend) {
                for slug in ["google-drive", "slack", "outlook-mail", "outlook-calendar", "fixture-generic"] {
                    for mode: MCPSource.ReadMode in [.initial, .iterative] {
                        for summary in ["", "You have a $500 project to finish."] {
                            await Transport.shared.reset([.output(.init(result: reply(summary), raw: ""))])
                            let result = try await MCPSource.read(slug: slug, prompt: "Synthetic only", mode: mode, window: window)
                            check("\(backend) \(slug) \(mode) \(summary.isEmpty ? "quiet" : "notable") needs no receipt or prose proof", result.itemCount == 1 && (result.result != nil) == !summary.isEmpty)
                            check("accepted output does not repeat the read", await Transport.shared.calls() == 1)
                            let inv = await Transport.shared.last()!
                            check("read restrictions remain scoped", inv.connectorOnlyRead && inv.sandbox == .readOnly && !inv.webSearch && inv.mcpReadConnectors == [slug])
                            check("KB calls do not install exact workflow proof gates", inv.outlookReadMode == nil && inv.outlookReadWindow == nil && inv.outlookCalendarReadPurpose == nil && inv.outlookCalendarReadWindow == nil && inv.outlookRunID == nil && !inv.outlookKeepsReadBudget)
                        }
                    }
                }
            }
        }
        var additive = try JSONSerialization.jsonObject(with: Data(reply().utf8)) as! [String: Any]
        additive["provider_metadata"] = ["cursor": "synthetic", "observed": true]
        await Transport.shared.reset([.output(.init(result: json(additive), raw: ""))])
        let extended = try await MCPSource.read(slug: "google-drive", prompt: "Synthetic")
        check("additive metadata preserves a usable summary", extended.result?.summary == "You have a $500 project to finish.")
        check("additive metadata does not repeat the read", await Transport.shared.calls() == 1)
        for field in ["item_count", "notable", "has_action_items", "summary", "tool_failure"] {
            var missing = additive; missing.removeValue(forKey: field)
            do { _ = try MCPSource.parse(json(missing), slug: "google-drive"); preconditionFailure("Missing required field accepted") }
            catch MCPSource.MCPError.invalidResponse { check("additive metadata cannot replace required \(field)", true) }
        }
        for (field, invalid): (String, Any) in [("item_count", -1), ("item_count", "1"), ("notable", 1), ("has_action_items", "true"), ("summary", ["text": "bad"]), ("tool_failure", "unknown")] {
            var malformed = additive; malformed[field] = invalid
            do { _ = try MCPSource.parse(json(malformed), slug: "google-drive"); preconditionFailure("Malformed field accepted") }
            catch MCPSource.MCPError.invalidResponse { check("additive metadata cannot hide malformed \(field)", true) }
        }
        await Transport.shared.reset([.output(.init(result: "not json", raw: "")), .output(.init(result: reply(), raw: ""))])
        let recovered = try await MCPSource.read(slug: "google-drive", prompt: "Synthetic")
        check("malformed JSON gets one recovery attempt", await Transport.shared.calls() == 2 && recovered.result != nil)
        let failedTrace = json(["type": "item.completed", "item": ["id": "earlier", "type": "mcp_tool_call", "server": "codex_apps", "tool": "google_drive.search", "arguments": [:], "status": "failed", "error": ["code": 401], "result": ["isError": true, "content": []]]])
        for mode: MCPSource.ReadMode in [.initial, .iterative] {
            await Transport.shared.reset([.output(.init(result: reply(), raw: failedTrace))])
            let accepted = try await MCPSource.read(slug: "google-drive", prompt: "Synthetic", mode: mode)
            check("\(mode) earlier native failure cannot veto final successful result", accepted.result != nil)
        }
        await Transport.shared.reset([.output(.init(result: reply("", failure: "other"), raw: failedTrace))])
        do { _ = try await MCPSource.read(slug: "google-drive", prompt: "Synthetic"); preconditionFailure("Reported native auth failure accepted") }
        catch MCPSource.MCPError.connectorAuth { check("native auth classifies an explicitly failed result", await Transport.shared.calls() == 1) }
        for failure in ["auth", "other"] {
            let envelope = CodexCLI.Envelope(result: reply("", failure: failure), raw: "")
            await Transport.shared.reset([.output(envelope), .output(envelope)])
            do { _ = try await MCPSource.read(slug: "google-drive", prompt: "Synthetic"); preconditionFailure("Explicit failure was accepted") }
            catch MCPSource.MCPError.connectorAuth { check("explicit auth remains failure", failure == "auth") }
            catch MCPSource.MCPError.toolFailure { check("explicit tool failure remains failure", failure == "other") }
        }
        for transport: Transport.Response in [.cancelled, .quota, .unavailable] {
            await Transport.shared.reset([transport])
            do { _ = try await MCPSource.read(slug: "google-drive", prompt: "Synthetic"); preconditionFailure("Transport error was accepted") }
            catch { check("terminal transport error does not repeat", await Transport.shared.calls() == 1) }
        }
        let sensitive = try MCPSource.parse(reply("Synthetic card 4111 1111 1111 1111"), slug: "google-drive")
        check("actual PII backstop remains effective", sensitive.result == nil && sensitive.itemCount == 1)
        let note = GranolaSource.Meeting(id: "fixture-id", title: "Synthetic", date: "2026-10-01", capturedByUser: true, privateNotes: "Synthetic notes", enhancedNotes: "", participants: [], url: "https://example.test/meeting")
        for mode: MCPSource.ReadMode in [.initial, .iterative] {
            let outcome = try GranolaSource.parseSummary(.init(result: reply("You noted a project without a source marker.", count: 9), raw: ""), meetings: [note], mode: mode, slug: "granola")
            check("Granola \(mode) accepts uncited summary and uses fetched count", outcome.result?.itemCount == 1)
            let cited = try GranolaSource.parseSummary(.init(result: reply("Synthetic project. [M1]", count: 9), raw: ""), meetings: [note], mode: mode, slug: "granola")
            check("Granola optional known marker still renders", cited.result?.summary.contains("https://example.test/meeting") == true)
        }
        let page = NotionSource.Page(id: "fixture", title: "Synthetic", url: "https://example.test/page", editedAt: "2026-10-01", partial: true, properties: "", content: "Useful context")
        let content = NotionSource.Content(pages: [page], inspectedCount: 1, skippedCount: 0)
        let notion = try NotionSource.parseSummary(reply("You have useful uncited context.", count: 9), content: content, slug: "notion")
        check("Notion accepts uncited prose and uses native fetched count", notion.result?.itemCount == 1)
        let partial = NotionSource.Content(pages: [page], inspectedCount: 2, skippedCount: 1)
        do { _ = try NotionSource.parseSummary(reply(""), content: partial, slug: "notion"); preconditionFailure("Skipped read became quiet") }
        catch MCPSource.MCPError.toolFailure { check("Notion native unread page still prevents quiet success", true) }
        print("PASS suite: \(checks) assertions")
    }
}
'''

source = (APP / "Sources/MCPSource.swift").read_text()
markers = ["enum MCPError:", "struct ReadResult:", "enum ReadOutcome:", "enum ReadMode:", "struct Window:",
           "static func read(slug:", "static func readInvocation(", "static func parse(",
           "private static func shapeMismatch(", "private static func jsonSpan("]
body = "\n".join(block(source, marker) for marker in markers)
body += "\n" + source[source.index("    typealias ReceiptObserver"):source.index("\n", source.index("    typealias ReceiptObserver"))]
body += '\nstatic let readSchema = "{}"\nstatic let meter = OSAllocatedUnfairLock(initialState: [String: (tokensIn: Int, tokensOut: Int)]())\n'
granola = (APP / "Sources/GranolaSource.swift").read_text()
granola_body = block(granola, "struct Meeting:") + "\n" + block(granola, "static func parseSummary(")
granola_body += "\n" + STUBS[STUBS.index("    static func read(connection:"):STUBS.index("\n}", STUBS.index("    static func read(connection:"))]
notion = (APP / "Sources/NotionSource.swift").read_text()
notion_body = "\n".join(block(notion, marker) for marker in ["struct Page:", "struct Content:", "static func parseSummary("])
with tempfile.TemporaryDirectory(prefix="sentient-mcp-acceptance-") as folder:
    folder = Path(folder)
    fixture = folder / "Fixture.swift"
    fixture.write_text(STUBS + "\nnonisolated enum MCPSource {\n" + body + "\n}\nnonisolated enum GranolaSource {\n" + granola_body + "\n}\nextension NotionSource {\n" + notion_body + "\n}\n" + TESTS)
    executable = folder / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(fixture),
                    str(APP / "Sources/ConnectorReadFailure.swift"), str(APP / "Cloud/MCPCallEvidence.swift"),
                    str(APP / "Engine/PIIScan.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
