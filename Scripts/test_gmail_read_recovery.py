#!/usr/bin/env python3
"""Run actual Google summary acceptance and Gmail retry code with synthetic replies.

No models, credentials, network, preferences, or real mailbox data are accessed.
The surrounding registry, frontier transport, privacy detector and storage are fixtures.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"
FIXTURE = r'''
import Foundation
nonisolated enum ModelBackend: Sendable { case claude, chatgpt, custom, sentient; static var current: Self { .chatgpt } }
nonisolated enum MCPSource { enum MCPError: Error { case connectorAuth(slug: String), toolFailure(slug: String), connectionChanged } }
nonisolated enum DirectMCPError: Error { case reconnectRequired, registrationExpired, accountSetupRequired, authorizationDenied, noTools, http(Int) }
nonisolated enum CodexCLI {
    enum CLIError: Error { case exitFailure(Int32, String), usageLimit, timedOut(after: TimeInterval) }
    struct Envelope: Sendable { let result: String; let raw: String; var jsonResult: String { result } }
    struct Invocation: Sendable { var prompt: String; var connectorOnlyRead = false; var webSearch = false; var mcpReadConnectors: [String] = [] }
}
nonisolated enum ConnectorRegistry {
    struct Pack { let claudeToolPrefix: String?; let readTools: [String]?; let codexReadTools: [String]? }
    static func canonicalSlug(_ slug: String) -> String { slug }
    static func pack(forSlug slug: String) -> Pack? {
        switch slug {
        case "gmail": Pack(claudeToolPrefix: "mcp__claude_ai_Gmail__", readTools: ["search_threads", "get_thread"], codexReadTools: ["search_emails", "read_email", "batch_read_email", "read_email_thread", "batch_read_email_threads"])
        case "google-calendar": Pack(claudeToolPrefix: "mcp__claude_ai_Google_Calendar__", readTools: ["list_events"], codexReadTools: ["search_events", "read_event"])
        default: nil
        }
    }
    static func readOrigin(slug: String, backend: ModelBackend) -> String { "fixture" }
}
nonisolated enum PIIScan { static func containsHighRiskPII(_ value: String) -> Bool { value.contains("SENSITIVE_FIXTURE") } }
nonisolated enum Diagnostics { enum Event { case modelOutputInvalid }; enum Phase { case parse, validate }; enum Count: Hashable { case bytes, retries }; enum Flag: Hashable { case previousStateRetained }; static func report(_ event: Event, phase: Phase, reason: String, source: String, counts: [Count: Int], flags: [Flag: Bool]) {} }
extension Diagnostics {
    @TaskLocal static var currentAttemptIsIsolated = false
    static func withOperation<T>(_ name: StaticString, propagatesFailure: Bool = true,
                                 isolation: isolated (any Actor)? = #isolation,
                                 _ body: () async throws -> T) async rethrows -> T {
        try await $currentAttemptIsIsolated.withValue(name.description == "google_read_attempt" && !propagatesFailure) { try await body() }
    }
}
nonisolated struct NoteDraft: Sendable {}
nonisolated struct ItemKey: Sendable { let order: TimeInterval; let tiebreak: String }
actor CycleStore { static let shared = CycleStore(); enum Outcome { case saved, diskFull }; func commitMCPRead(bucketKey: String, notes: [NoteDraft], through: ItemKey, origin: String, replaceNotes: Bool) -> Outcome { fatalError("No storage writes permitted") } }
nonisolated func Log(_ message: String) {}

actor Scenario {
    enum Reply: Sendable { case envelope(CodexCLI.Envelope), cancel, quota, cliFailure, schemaFailure, timeout, cancelledTimeout }
    static let shared = Scenario()
    var replies: [Reply] = []
    var requests: [CodexCLI.Invocation] = []
    var scopes: [Bool] = []
    func reset(_ replies: [Reply]) { self.replies = replies; requests = []; scopes = [] }
    func snapshot() -> [CodexCLI.Invocation] { requests }
    func scopeSnapshot() -> [Bool] { scopes }
    func reply(_ request: CodexCLI.Invocation) throws -> CodexCLI.Envelope {
        requests.append(request)
        scopes.append(Diagnostics.currentAttemptIsIsolated)
        precondition(!replies.isEmpty, "Unbounded retry")
        switch replies.removeFirst() {
        case .envelope(let value): return value
        case .cancel: throw CancellationError()
        case .quota: throw CodexCLI.CLIError.usageLimit
        case .cliFailure: throw CodexCLI.CLIError.exitFailure(1, "unknown terminal failure")
        case .schemaFailure: throw CodexCLI.CLIError.exitFailure(1, "StructuredOutput does not match required schema")
        case .timeout: throw CodexCLI.CLIError.timedOut(after: 60)
        case .cancelledTimeout:
            withUnsafeCurrentTask { $0?.cancel() }
            throw CodexCLI.CLIError.timedOut(after: 60)
        }
    }
}
nonisolated enum FrontierRun {
    static func run(_ invocation: CodexCLI.Invocation) async throws -> CodexCLI.Envelope {
        let response = try await Scenario.shared.reply(invocation)
        // Match the production transport boundary: a reported failure throws before
        // the Google reader receives the envelope, so retry classification must survive.
        if invocation.connectorOnlyRead, invocation.mcpReadConnectors.count == 1 {
            try ConnectorReadFailure.validate(response, slug: invocation.mcpReadConnectors[0])
        }
        return response
    }
}

@main struct Harness {
    static let query = "after:2026/10/01 before:2026/10/08"
    static let quiet = #"{"thread_count":0,"notable":false,"has_action_items":false,"summary":"","tool_failure":""}"#
    static let notable = #"{"thread_count":2,"notable":true,"has_action_items":false,"summary":"Useful synthetic context.","tool_failure":""}"#
    static func json(_ value: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    static func call(_ id: String, _ tool: String, _ args: [String: Any], failed: Bool = false,
                     payload: Any = ["messages": []], error: Any? = nil, server: String = "codex_apps", oversized: Bool = false) -> String {
        let result: [String: Any] = oversized
            ? ["content": [["type": "text", "text": "Error: result exceeds maximum allowed tokens. Output has been saved to a file."]]]
            : ["isError": failed, "content": [["type": "text", "text": json(payload)]]]
        var item: [String: Any] = ["id": id, "type": "mcp_tool_call", "server": server, "tool": tool,
            "arguments": args, "status": failed ? "failed" : "completed", "result": result]
        if let error { item["error"] = error }
        return json(["type": "item.completed", "item": item])
    }
    static func envelope(_ raw: [String], result: String = notable) -> CodexCLI.Envelope { .init(result: result, raw: raw.joined(separator: "\n")) }

    static func reportedFailure(_ raw: [String] = [], kind: String = "other") -> CodexCLI.Envelope {
        envelope(raw, result: quiet.replacingOccurrences(of: #""tool_failure":"""#, with: "\"tool_failure\":\"" + kind + "\""))
    }
    static func main() async throws {
        var checks = 0
        func check(_ name: String, _ condition: Bool) { precondition(condition, name); checks += 1; print("PASS " + name) }
        func run(_ replies: [Scenario.Reply], slug: String = "gmail") async -> (String, [CodexCLI.Invocation], GoogleSourceRead.Summary?) {
            let replies = replies.map { reply in
                if slug == "google-calendar", case .envelope(let response) = reply {
                    return Scenario.Reply.envelope(.init(result: response.result.replacingOccurrences(of: "thread_count", with: "event_count"), raw: response.raw))
                }
                return reply
            }
            await Scenario.shared.reset(replies)
            var result: GoogleSourceRead.Summary?
            let outcome: String
            do { result = try await GoogleSourceRead.read(.init(prompt: "Read EXACTLY " + query, mcpReadConnectors: [slug]), slug: slug, countKey: slug == "gmail" ? "thread_count" : "event_count"); outcome = "success" }
            catch MCPSource.MCPError.toolFailure { outcome = "tool" }
            catch MCPSource.MCPError.connectorAuth { outcome = "auth" }
            catch is CancellationError { outcome = "cancelled" }
            catch CodexCLI.CLIError.usageLimit { outcome = "quota" }
            catch ConnectorReadFailure.GmailFailure.accountLimit { outcome = "quota" }
            catch ConnectorReadFailure.GmailFailure.rateLimited { outcome = "rate" }
            catch CodexCLI.CLIError.exitFailure { outcome = "cli" }
            catch CodexCLI.CLIError.timedOut { outcome = "timeout" }
            catch GoogleSourceRead.Failure.invalidResponse { outcome = "invalid" }
            catch { outcome = "other" }
            return (outcome, await Scenario.shared.snapshot(), result)
        }
        let good = envelope([])
        let transient = call("failed", "gmail.batch_read_email", ["message_ids": ["m1", "m2"]], failed: true,
            error: ["message": "Transient service failure"])
        let auth = call("auth", "gmail.batch_read_email", ["message_ids": ["m1", "m2"]], failed: true, error: ["code": 401])
        let quota = call("quota", "gmail.batch_read_email", ["message_ids": ["m1", "m2"]], failed: true,
            error: ["code": "insufficient_quota"])
        let changedRead = call("different-read", "gmail.read_email", ["message_id": "different", "format": "metadata"], payload: [:])
        let histories: [(String, [String])] = [
            ("without any native receipts", []),
            ("with unrecognized native event shape", [#"{"event":"source completed in a different runtime"}"#]),
            ("with altered search query and arguments", [call("search", "gmail.search_emails", ["query": "different", "unknown_filter": true])]),
            ("with a different server or tool alias", [call("search", "future.search", [:], server: "different")]),
            ("with an oversized native result notice", [call("large", "gmail.search_emails", [:], oversized: true)]),
            ("with a historical failed batch and changed read", [transient, changedRead]),
            ("with historical authentication failure", [auth]),
            ("with historical account quota failure", [quota]),
        ]
        for slug in ["gmail", "google-calendar"] {
            for (name, raw) in histories {
                let result = await run([.envelope(envelope(raw))], slug: slug)
                check("\(slug) accepts completed summary \(name)", result.0 == "success" && result.1.count == 1 && result.2?.count == 2)
            }
            let quietResult = await run([.envelope(envelope([], result: quiet))], slug: slug)
            check("\(slug) accepts quiet result without native discovery", quietResult.0 == "success" && quietResult.1.count == 1 && quietResult.2 == nil)
            let abovePromptCap = notable.replacingOccurrences(of: "\"thread_count\":2", with: "\"thread_count\":301")
            let largerCount = await run([.envelope(envelope([], result: abovePromptCap))], slug: slug)
            check("\(slug) valid completed summary accepts reported count301", largerCount.0 == "success" && largerCount.1.count == 1 && largerCount.2?.count == 301)
            let missingFlag = notable.replacingOccurrences(of: ",\"tool_failure\":\"\"", with: "")
            let legacy = await run([.envelope(envelope([], result: missingFlag))], slug: slug)
            check("\(slug) accepts decoded summary with absent optional failure flag", legacy.0 == "success" && legacy.1.count == 1)
            let denied = await run([.envelope(reportedFailure(kind: "auth"))], slug: slug)
            check("\(slug) explicit auth stops without retry", denied.0 == "auth" && denied.1.count == 1)
        }
        let recovered = await run([.envelope(reportedFailure()), .envelope(good)])
        check("explicit source failure retries once without receipt evidence", recovered.0 == "success" && recovered.1.count == 2 && recovered.2?.count == 2)
        check("retry preserves requested date query and read-only request", recovered.1.allSatisfy { $0.prompt.contains(query) && $0.connectorOnlyRead && !$0.webSearch })
        let persistent = await run([.envelope(reportedFailure()), .envelope(reportedFailure())])
        check("two reported failures stop with original tool failure", persistent.0 == "tool" && persistent.1.count == 2)
        let nativeFailure = await run([.envelope(reportedFailure([transient])), .envelope(good)])
        check("explicit transient source failure with diagnostics retries once", nativeFailure.0 == "success" && nativeFailure.1.count == 2)
        let calendarFailure = await run([.envelope(reportedFailure())], slug: "google-calendar")
        check("Calendar reported tool failure stays terminal", calendarFailure.0 == "tool" && calendarFailure.1.count == 1)
        let nativeAuth = await run([.envelope(reportedFailure([auth]))])
        check("explicit other failure uses native401 to classify auth", nativeAuth.0 == "auth" && nativeAuth.1.count == 1)
        for payload in [["code": "insufficient_quota"], ["message": "Account usage limit reached"], ["code": "dailyLimitExceeded"],
                        ["code": 429, "message": "Quota exhausted"],
                        ["code": 403, "errors": [["reason": "dailyLimitExceeded"]], "message": "Quota exceeded"],
                        ["code": 429, "message": "Quota exceeded: Queries per day"],
                        ["code": 429, "errors": [["reason": "userRateLimitExceeded"]], "message": "Account usage limit reached"]] as [[String: Any]] {
            let failure = call("quota", "gmail.batch_read_email", [:], failed: true, error: payload)
            let outcome = await run([.envelope(reportedFailure([failure]))])
            check("reported account quota does not retry \(checks)", outcome.0 == "quota" && outcome.1.count == 1)
        }
        let provider429 = call("rate", "gmail.batch_read_email", [:], failed: true, error: ["code": 429])
        for payload in [["code": 429], ["code": 403, "errors": [["reason": "rateLimitExceeded"]]],
                        ["code": 403, "errors": [["reason": "userRateLimitExceeded"]], "message": "Quota exceeded"],
                        ["code": 403, "message": "Quota exceeded for quota metric 'Read requests' and limit 'Queries per minute'"],
                        ["code": 429, "message": "Quota exceeded for queries per second"]] as [[String: Any]] {
            let failure = call("transient-quota", "gmail.batch_read_email", [:], failed: true, error: payload)
            let began = Date()
            let outcome = await run([.envelope(reportedFailure([failure])), .envelope(good)])
            check("reported short provider limit retries with bounded backoff \(checks)", outcome.0 == "success" && outcome.1.count == 2 && Date().timeIntervalSince(began) >= 0.9)
        }
        let quota401 = call("quota401", "gmail.batch_read_email", [:], failed: true, error: ["code": 401, "message": "Quota exhausted"])
        let persistentRate = await run([.envelope(reportedFailure([provider429])), .envelope(reportedFailure([provider429]))])
        check("repeated provider rate limit stops after two attempts with typed error", persistentRate.0 == "rate" && persistentRate.1.count == 2)
        let deniedQuota = await run([.envelope(reportedFailure([quota401]))])
        check("native401 retains auth priority in reported failure", deniedQuota.0 == "auth" && deniedQuota.1.count == 1)
        let transportQuota = await run([.quota])
        check("CLI account quota is never retried", transportQuota.0 == "quota" && transportQuota.1.count == 1)
        let unknownCLI = await run([.cliFailure])
        check("unknown CLI failure is not blindly retried", unknownCLI.0 == "cli" && unknownCLI.1.count == 1)
        let timeout = await run([.timeout, .envelope(good)])
        check("typed runtime timeout retries the bounded Gmail window once", timeout.0 == "success" && timeout.1.count == 2 && timeout.1.allSatisfy { $0.prompt.contains(query) })
        let timeoutScopes = await Scenario.shared.scopeSnapshot()
        check("each retryable Gmail runtime call has isolated diagnostic propagation", timeoutScopes == [true, true])
        check("timeout retry prompt accurately describes deadline", timeout.1.last?.prompt.contains("previous window attempt timed out") == true)
        let persistentTimeout = await run([.timeout, .timeout])
        check("second runtime timeout preserves typed failure and stops", persistentTimeout.0 == "timeout" && persistentTimeout.1.count == 2)
        let cancelledTimeout = await Task { await run([.cancelledTimeout]) }.value
        check("cancellation wins over simultaneous timeout without retry", cancelledTimeout.0 == "cancelled" && cancelledTimeout.1.count == 1)
        let calendarTimeout = await run([.timeout], slug: "google-calendar")
        check("Calendar timeout policy remains unchanged", calendarTimeout.0 == "timeout" && calendarTimeout.1.count == 1)
        let calendarScopes = await Scenario.shared.scopeSnapshot()
        check("Calendar runtime attempt uses isolated diagnostic propagation", calendarScopes == [true])
        let cancelled = await run([.cancel])
        check("transport cancellation does not retry", cancelled.0 == "cancelled" && cancelled.1.count == 1)
        await Scenario.shared.reset([.envelope(reportedFailure([provider429]))])
        let task = Task { try await GoogleSourceRead.read(.init(prompt: "Read EXACTLY " + query, mcpReadConnectors: ["gmail"]), slug: "gmail", countKey: "thread_count") }
        while await Scenario.shared.snapshot().isEmpty { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled backoff completed") } catch is CancellationError {}
        let afterCancel = await Scenario.shared.snapshot()
        check("cancelling rate-limit backoff prevents another request", afterCancel.count == 1)
        for invalid in ["not JSON", #"{"thread_count":"two","notable":true,"has_action_items":false,"summary":"text"}"#,
                        #"{"thread_count":-1,"notable":true,"has_action_items":false,"summary":"text"}"#,
                        #"{"thread_count":1,"notable":true,"has_action_items":false,"summary":""}"#,
                        #"{"thread_count":0,"notable":false,"has_action_items":true,"summary":""}"#,
                        #"{"thread_count":1,"notable":true,"has_action_items":false,"summary":"text","tool_failure":"unexpected"}"#,
                        #"{"thread_count":1,"notable":true,"has_action_items":false,"summary":"text","tool_failure":42}"#] {
            let result = await run([.envelope(envelope([], result: invalid)), .envelope(envelope([], result: invalid))])
            check("invalid summary shape cannot be stored \(checks)", result.0 == "invalid" && result.1.count == 2)
        }
        let formatRepair = await run([.schemaFailure, .envelope(good)])
        check("structured-output formatting failure has one bounded retry", formatRepair.0 == "success" && formatRepair.1.count == 2)
        let calendarFormatRepair = await run([.schemaFailure, .envelope(good)], slug: "google-calendar")
        check("Calendar runtime formatting failure recovers on its one permitted retry", calendarFormatRepair.0 == "success" && calendarFormatRepair.1.count == 2 && calendarFormatRepair.2?.count == 2)
        let calendarFormatScopes = await Scenario.shared.scopeSnapshot()
        check("both Calendar formatting attempts isolate recoverable diagnostics", calendarFormatScopes == [true, true])
        let calendarFormatFailure = await run([.schemaFailure, .schemaFailure], slug: "google-calendar")
        check("exhausted Calendar formatting failure remains terminal", calendarFormatFailure.0 == "invalid" && calendarFormatFailure.1.count == 2)
        let sensitive = notable.replacingOccurrences(of: "Useful synthetic context.", with: "SENSITIVE_FIXTURE")
        let privacy = await run([.envelope(envelope([], result: sensitive))])
        check("high-risk privacy detector still omits sensitive summary", privacy.0 == "success" && privacy.2 == nil)
        print("Checked \(checks) Google acceptance and Gmail recovery cases; failures=0")
    }
}

'''

with tempfile.TemporaryDirectory(prefix="sentient-gmail-recovery-") as directory:
    root = Path(directory)
    fixture = root / "Fixture.swift"
    fixture.write_text(FIXTURE)
    binary = root / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
        str(APP / "Cloud/MCPCallEvidence.swift"),
        str(APP / "Sources/ConnectorReadFailure.swift"),
        str(APP / "Sources/GoogleSourceRead.swift"), str(fixture), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
