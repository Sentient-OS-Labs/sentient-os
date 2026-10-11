#if DEBUG
// Synthetic regressions for bounded connector reads and writing setup. No live accounts,
// credentials, preferences or vault writes. Exercises production readers and validators.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
import Foundation
import Synchronization

enum ConnectorReliabilityTests {
    private static func check(_ value: Bool, _ label: String) throws {
        try FullAcceptanceTests.require(value, label)
    }
    private static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try DirectMCPHTTP.json(value), as: UTF8.self)
    }
    private static func receipt(_ id: String, tool: String, args: [String: Any] = [:],
                                payload: [String: Any] = [:], failed: Bool = false) throws -> String {
        try json(["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": tool, "input": args]]]])
            + "\n" + json(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id,
                "is_error": failed, "content": [["type": "text", "text": try json(payload)]]]]]])
    }
    private static func modified(_ tool: DirectMCPTool, _ edit: (inout [String: Any]) -> Void) throws -> DirectMCPTool {
        var definition = try JSONSerialization.jsonObject(with: tool.definition) as! [String: Any]
        edit(&definition)
        return DirectMCPTool(name: tool.name, description: tool.description, definition: try DirectMCPHTTP.json(definition))
    }

    static func run() async {
        do {
            try await granola()
            try await classification()
            try await notion()
            try await ModelBackend.$runOverride.withValue(.claude) { try await modelReaders() }
            try await doubleTapSetup()
            try diagnostics()
            Log("CONNECTOR RELIABILITY: PASS")
        } catch { Log("CONNECTOR RELIABILITY: FAIL \(String(describing: error))"); exit(1) }
    }

    private static func granola() async throws {
        let tools = try GranolaCurationTests.fixtureTools()
        for limit in [1, 3, 6, 10] {
            let changed = try tools.map { tool in
                guard tool.name == "get_meetings" else { return tool }
                return try modified(tool) { definition in
                    definition["inputSchema"] = ["type": "object", "properties": ["meeting_ids": [
                        "type": "array", "maxItems": limit, "items": ["type": "string"]]]]
                }
            }
            try check(GranolaSource.supportsSurface(changed) && GranolaSource.contentBatchSize(changed) == min(limit, 6),
                      "Granola honors batch limit \(limit) with optional minItems")
        }
        let wrapped = try tools.map { tool in
            guard tool.name == "list_meetings" else { return tool }
            return try modified(tool) { definition in
                var schema = definition["inputSchema"] as! [String: Any]
                var properties = schema["properties"] as! [String: Any]
                schema["$defs"] = ["involvement": properties["involvement"]!]
                properties["involvement"] = ["anyOf": [["$ref": "#/$defs/involvement"], ["type": "null"]]]
                schema["properties"] = properties; definition["inputSchema"] = schema
            }
        }
        try check(GranolaSource.supportsSurface(wrapped), "Granola accepts nullable locally referenced involvement")
        for unsupported: [String: Any] in [
            ["anyOf": [["type": "object"], ["type": "string"]]],
            ["$ref": "https://example.test/schema"], ["$ref": "#/properties/involvement"]
        ] {
            let changed = try tools.map { tool in
                guard tool.name == "list_meetings" else { return tool }
                return try modified(tool) { definition in
                    var schema = definition["inputSchema"] as! [String: Any]
                    var properties = schema["properties"] as! [String: Any]
                    properties["involvement"] = unsupported
                    schema["properties"] = properties; definition["inputSchema"] = schema
                }
            }
            try check(!GranolaSource.supportsSurface(changed), "Granola refuses ambiguous, external or circular schemas")
        }
        let noReadHint = try tools.map { try modified($0) { $0["annotations"] = [:] } }
        try check(!GranolaSource.supportsSurface(noReadHint), "Granola still requires native read annotations")
        let account: [String: Any] = ["email": "fixture@example.test", "active_workspace": ["id": "fixture-workspace"]]
        let camel = DirectMCPIdentity.parse(try DirectMCPHTTP.json(["structuredContent": account]))
        let snake = DirectMCPIdentity.parse(try DirectMCPHTTP.json(["structured_content": account]))
        try check(camel != nil && camel?.fingerprint == snake?.fingerprint, "account identity matches across structured-content wrappers")
        try check(DirectMCPIdentity.parse(try DirectMCPHTTP.json(["isError": true, "structuredContent": account])) == nil,
                  "an errored account response cannot establish identity")
        let end = Date(timeIntervalSince1970: 1_789_430_400)
        let window = MCPSource.Window(lower: end.addingTimeInterval(-3_600), upper: end, label: "fixture")
        let candidates = (1...5).map { index in GranolaSource.Candidate(
            id: "00000000-0000-4000-8000-00000000000\(index)", title: "Synthetic \(index)",
            date: MCPSource.timestamp(window.lower), capturedByUser: true) }
        let identity = GranolaSource.Account(fingerprint: "fixture", email: "fixture@example.test", scopes: nil)
        var sizes: [Int] = []
        func response(_ batch: [GranolaSource.Candidate]) -> [String: Any] {
            ["structuredContent": ["meetings": batch.map { ["id": $0.id, "title": $0.title,
                "created_at": $0.date, "private_notes": "A synthetic decision."] }]]
        }
        let notes = try await GranolaSource.collectMeetings(candidates, batchSize: 2, account: identity, window: window) { batch in
            sizes.append(batch.count); return response(batch)
        }
        try check(sizes == [2, 2, 1] && notes.map(\.id) == candidates.map(\.id), "Granola fetches every selected meeting within the provider batch limit")
        var rejected = false
        sizes = []
        do {
            _ = try await GranolaSource.collectMeetings(candidates, batchSize: 2, account: identity, window: window) { batch in
                sizes.append(batch.count)
                return response(sizes.count == 2 ? [] : batch)
            }
        } catch DirectMCPError.invalidResponse { rejected = true }
        try check(rejected && sizes == [2, 2], "an incomplete later Granola batch cannot publish earlier batches")
    }

    private static func notion() async throws {
        let id = "0123456789abcdef0123456789abcdef"
        let row: [String: Any] = ["type": "page", "url": NotionSource.stableURL(id), "title": "Synthetic page"]
        let tools = try ["notion-search", "notion-ai-search", "notion-list-recent-pages"].map { name in
            DirectMCPTool(name: name, description: "Synthetic", definition: try DirectMCPHTTP.json([
                "inputSchema": ["type": "object", "properties": ["cursor": ["type": "string"]]]]))
        }
        let end = Date(timeIntervalSince1970: 1_789_430_400)
        let window = MCPSource.Window(lower: end.addingTimeInterval(-3_600), upper: end, label: "fixture")
        func result(_ rows: [[String: Any]], cursor: String? = nil, search: Bool = true) -> [String: Any] {
            var object: [String: Any] = ["results": rows]
            if search { object["type"] = "workspace_search" }
            if let cursor { object["nextCursor"] = cursor }
            return ["structuredContent": object]
        }
        var calls = 0
        let paged = try await NotionSource.discover(window: window, mode: .initial, aiAvailable: false, tools: tools) { name, args in
            calls += 1
            try check(name == "notion-search", "nonempty paginated search needs no fallback")
            if calls == 1 { return result([], cursor: "page-2") }
            try check(args["cursor"] as? String == "page-2", "Notion forwards the advertised cursor")
            return result([row])
        }
        try check(calls == 2 && paged.candidates.map(\.id) == [id], "empty first Notion page does not discard later results")
        calls = 0
        let fallback = try await NotionSource.discover(window: window, mode: .initial, aiAvailable: false, tools: tools) { name, _ in
            calls += 1
            return result(name == "notion-list-recent-pages" ? [row] : [], search: name != "notion-list-recent-pages")
        }
        try check(calls == 2 && fallback.candidates.count == 1 && fallback.coverage == .historicalSample,
                  "empty Notion search checks recent pages for initial backfill")
        calls = 0
        let empty = try await NotionSource.discover(window: window, mode: .iterative, aiAvailable: false, tools: tools) { name, _ in
            calls += 1; return result([], search: name != "notion-list-recent-pages")
        }
        try check(calls == 2 && empty.candidates.isEmpty, "two completed empty Notion lanes may remain quiet")
        for variant in ["cycle", "budget", "unadvertised", "missing_cursor"] {
            calls = 0
            var rejected = false
            do {
                _ = try await NotionSource.discover(window: window, mode: .initial, aiAvailable: false,
                    tools: variant == "unadvertised" ? [] : tools) { _, _ in
                    calls += 1
                    if variant == "missing_cursor" { return ["structuredContent": ["type": "workspace_search", "results": [], "has_more": true]] }
                    return result([], cursor: variant == "budget" ? "page-\(calls)" : "same")
                }
            } catch DirectMCPError.invalidResponse { rejected = true }
              catch DirectMCPError.tooLarge { rejected = true }
            try check(rejected && calls <= 6, "unfinished Notion \(variant) refuses a quiet checkpoint")
        }
        calls = 0
        let entitledFallback = try await NotionSource.discover(window: window, mode: .iterative, aiAvailable: true, tools: tools) { name, _ in
            calls += 1
            if name == "notion-ai-search" { return ["isError": true, "structuredContent": ["error": ["classification": "entitlement", "code": "entitlement_required"]]] }
            return result([row], search: false)
        }
        try check(calls == 3 && entitledFallback.candidates.count == 1, "Notion entitlement fallback still works")
    }

    private static func classification() async throws {
        let tools = try GranolaCurationTests.fixtureTools()
        let policy = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, "read") })
        let valid = FullAcceptanceTests.envelope(try json(["tools": policy]))
        let invalid = FullAcceptanceTests.envelope(#"{"tools":{}}"#)
        let attempts = Mutex(0)
        let classified = try await FrontierRun.$acceptanceRun.withValue({ invocation in
            guard invocation.toolsDisabled && invocation.mcpReadConnectors.isEmpty else {
                throw FullAcceptanceTests.Failure(message: "classification unexpectedly gained tools")
            }
            return attempts.withLock { $0 += 1; return $0 == 1 ? invalid : valid }
        }) { try await DirectMCPConnections.classify(tools, providerName: "Granola") }
        try check(classified.count == tools.count && attempts.withLock({ $0 }) == 2,
                  "missing classification keys get one tool-free repair attempt")
        attempts.withLock { $0 = 0 }
        var rejected = false
        do {
            _ = try await FrontierRun.$acceptanceRun.withValue({ _ in attempts.withLock { $0 += 1 }; return invalid }) {
                try await DirectMCPConnections.classify(tools, providerName: "Granola")
            }
        } catch DirectMCPError.policyUnavailable { rejected = true }
        try check(rejected && attempts.withLock({ $0 }) == 2, "unverified classifications remain blocked after two attempts")
        let blocked = FullAcceptanceTests.envelope(try json(["tools": Dictionary(uniqueKeysWithValues: tools.map { ($0.name, "destructive") })]))
        let preserved = try await FrontierRun.$acceptanceRun.withValue({ _ in blocked }) {
            try await DirectMCPConnections.classify(tools, providerName: "Granola")
        }
        try check(preserved.values.allSatisfy { $0 == .destructive }, "classification repair never changes a valid restrictive policy")
    }

    private static func modelReaders() async throws {
        let search = "mcp__claude_ai_Gmail__search_threads"
        let args: [String: Any] = ["query": "in:sent -in:drafts"]
        let discovered = try receipt("search", tool: search, args: args, payload: ["messages": []])
        let quiet = #"{"thread_count":0,"notable":false,"summary":"","has_action_items":false,"tool_failure":""}"#
        let formatter = try receipt("format", tool: "StructuredOutput", payload: ["message": "does not match required schema"], failed: true)
        let repaired = FullAcceptanceTests.envelope(quiet, raw: discovered + "\n" + formatter)
        try ConnectorReadFailure.validateTools(repaired, slug: "gmail")
        try check(true, "formatter failure does not imply provider failure")
        let failedRead = try receipt("failed", tool: search, args: args, payload: ["message": "timeout"], failed: true)
        var rejected = false
        do { try ConnectorReadFailure.validateTools(FullAcceptanceTests.envelope(quiet, raw: failedRead), slug: "gmail") }
        catch MCPSource.MCPError.toolFailure { rejected = true }
        try check(rejected, "unresolved provider read still fails")
        try ConnectorReadFailure.validateTools(FullAcceptanceTests.envelope(quiet, raw: failedRead + "\n" + discovered), slug: "gmail")
        try check(true, "identical successful provider retry repairs a read")
        let unrelated = try receipt("unrelated", tool: search, args: ["query": "different"])
        rejected = false
        do { try ConnectorReadFailure.validateTools(FullAcceptanceTests.envelope(quiet, raw: failedRead + "\n" + unrelated), slug: "gmail") }
        catch MCPSource.MCPError.toolFailure { rejected = true }
        try check(rejected, "a different query cannot repair a failed read")

        let attempts = Mutex(0)
        let conflict = FullAcceptanceTests.envelope(quiet.replacingOccurrences(of: #""tool_failure":"""#, with: #""tool_failure":"other""#), raw: repaired.raw)
        let summary = try await FrontierRun.$acceptanceRun.withValue({ _ in
            attempts.withLock { $0 += 1; return $0 == 1 ? conflict : repaired }
        }) { try await GoogleSourceRead.read(.init(prompt: "Synthetic bounded read"), slug: "gmail", countKey: "thread_count", cap: 300) }
        try check(summary == nil && attempts.withLock({ $0 }) == 2, "conflicting model failure gets one fresh Google read")
        attempts.withLock { $0 = 0 }
        rejected = false
        do {
            _ = try await FrontierRun.$acceptanceRun.withValue({ _ in attempts.withLock { $0 += 1 }; return conflict }) {
                try await GoogleSourceRead.read(.init(prompt: "Synthetic bounded read"), slug: "gmail", countKey: "thread_count", cap: 300)
            }
        } catch GoogleSourceRead.Failure.invalidResponse { rejected = true }
        try check(rejected && attempts.withLock({ $0 }) == 2, "persistent invalid output stops after two attempts")
        attempts.withLock { $0 = 0 }
        let auth = FullAcceptanceTests.envelope(#"{"tool_failure":"auth"}"#, raw: discovered)
        rejected = false
        do {
            _ = try await FrontierRun.$acceptanceRun.withValue({ _ in attempts.withLock { $0 += 1 }; return auth }) {
                try await GoogleSourceRead.read(.init(prompt: "Synthetic bounded read"), slug: "gmail", countKey: "thread_count", cap: 300)
            }
        } catch MCPSource.MCPError.connectorAuth { rejected = true }
        try check(rejected && attempts.withLock({ $0 }) == 1, "Google authentication failure does not retry")
        attempts.withLock { $0 = 0 }
        _ = try await FrontierRun.$acceptanceRun.withValue({ _ in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw CodexCLI.CLIError.exitFailure(code: 1, message: "StructuredOutput does not match required schema") }
            return repaired
        }) { try await GoogleSourceRead.read(.init(prompt: "Synthetic bounded read"), slug: "gmail", countKey: "thread_count", cap: 300) }
        try check(attempts.withLock({ $0 }) == 2, "Claude terminal formatting failure gets one bounded retry")
        attempts.withLock { $0 = 0 }
        rejected = false
        do {
            _ = try await FrontierRun.$acceptanceRun.withValue({ _ in attempts.withLock { $0 += 1 }; throw CancellationError() }) {
                try await GoogleSourceRead.read(.init(prompt: "Synthetic bounded read"), slug: "gmail", countKey: "thread_count", cap: 300)
            }
        } catch is CancellationError { rejected = true }
        try check(rejected && attempts.withLock({ $0 }) == 1, "Google cancellation is preserved without another model call")

        let record: [String: Any] = ["id": "m1", "date": "2026-09-01T12:00:00Z", "labelIds": ["SENT"],
                                   "toRecipients": ["fixture@example.test"], "plaintextBody": "I can review the draft tomorrow."]
        let listed = try receipt("list", tool: search, args: args, payload: ["messages": [record]])
        let read = try receipt("body", tool: "mcp__claude_ai_Gmail__get_message", args: ["id": "m1"], payload: record)
        let incomplete = FullAcceptanceTests.envelope(#"{"tool_failure":""}"#, raw: listed)
        let complete = FullAcceptanceTests.envelope(#"{"tool_failure":""}"#, raw: listed + "\n" + read)
        attempts.withLock { $0 = 0 }
        let samples = try await FrontierRun.$acceptanceRun.withValue({ _ in
            attempts.withLock { $0 += 1; return $0 == 1 ? incomplete : complete }
        }) { try await WritingStyleMail.read(slug: "gmail") }
        try check(samples.count == 1 && samples.first?.text == record["plaintextBody"] as? String && attempts.withLock({ $0 }) == 2,
                  "writing-style read retries missing content and copies only native body")
        attempts.withLock { $0 = 0 }
        rejected = false
        do {
            _ = try await FrontierRun.$acceptanceRun.withValue({ _ in attempts.withLock { $0 += 1 }; return incomplete }) {
                try await WritingStyleMail.read(slug: "gmail")
            }
        } catch WritingStyle.Failure.mail { rejected = true }
        try check(rejected && attempts.withLock({ $0 }) == 2, "unverifiable writing samples remain a bounded failure")
    }

    private static func diagnostics() throws {
        let granola = Diagnostics.repeatKey(event: "mcp.read_failed", fingerprint: ["mcp", "read"], tags: ["slug": "granola"])
        let notion = Diagnostics.repeatKey(event: "mcp.read_failed", fingerprint: ["mcp", "read"], tags: ["slug": "notion"])
        try check(granola != notion, "one connector's error cannot suppress another connector's error")
        let fingerprint = ["reliability-fixture", UUID().uuidString]
        try check(Diagnostics.claim(event: "fixture", fingerprint: fingerprint, tags: ["slug": "granola"], cooldown: 900) != nil
                  && Diagnostics.claim(event: "fixture", fingerprint: fingerprint, tags: ["slug": "notion"], cooldown: 900) != nil
                  && Diagnostics.claim(event: "fixture", fingerprint: fingerprint, tags: ["slug": "granola"], cooldown: 900) == nil,
                  "cooldown emits both providers while suppressing a duplicate from the same provider")
        try check(AgentRunDiagnostics.toolIdentity(server: "", tool: "StructuredOutput").family == "builtin",
                  "formatter telemetry remains distinguishable from connectors")
        try check(AgentRunDiagnostics.toolIdentity(server: "claude_ai_Gmail", tool: "search_threads").tool == "gmail.search_threads",
                  "known Gmail read has a content-free diagnostic identity")
        try check(AgentRunDiagnostics.toolIdentity(server: "private-account-name", tool: "private-tool-name").tool == "other",
                  "unreviewed tool names cannot leak into diagnostics")
        try check(AgentRunDiagnostics.Reason.classify("does not match required schema") == .outputSchema,
                  "output-schema errors get a distinct diagnostic reason")
    }

    private static func doubleTapSetup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doubletap-setup-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Synthetic knowledge\nA synthetic project.\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoNetwork.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        NoNetwork.requests.withLock { $0 = 0 }
        var missingSamples = false
        do { _ = try await DoubleTapInference.draft(screenshot: Data([0]), vault: root, session: session) }
        catch DoubleTapInference.Failure.noWritingStyle { missingSamples = true }
        try check(missingSamples && NoNetwork.requests.withLock({ $0 }) == 0,
                  "Double Tap with failed writing setup stops locally before any drafting request")
        try "# Writing samples\nSynthetic sample.\n".write(to: root.appendingPathComponent(WritingStyle.fileName), atomically: true, encoding: .utf8)
        let packed = try DoubleTapInference.packVault(root)
        try check(packed.notes == 1 && packed.text.contains("Synthetic sample."),
                  "publishing the writing snapshot removes the Double Tap context blocker")
    }

    nonisolated private final class NoNetwork: URLProtocol, @unchecked Sendable {
        static let requests = Mutex(0)
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.withLock { $0 += 1 }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }
}
#endif
