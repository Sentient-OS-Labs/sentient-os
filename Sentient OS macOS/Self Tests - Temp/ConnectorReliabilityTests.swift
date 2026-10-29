#if DEBUG
// Synthetic regressions for bounded connector reads and writing setup. No live accounts,
// credentials or user vault writes. Identity cases require the isolated acceptance bundle
// and restore their temporary cache preferences. Exercises production readers and validators.
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
            try await ModelBackend.$runOverride.withValue(.chatgpt) { try await identityRetries() }
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
        try ConnectorReadFailure.validate(repaired, slug: "gmail")
        try check(true, "formatter failure does not imply a final source failure")
        let failedRead = try receipt("failed", tool: search, args: args, payload: ["message": "timeout"], failed: true)
        try ConnectorReadFailure.validate(FullAcceptanceTests.envelope(quiet, raw: failedRead), slug: "gmail")
        try check(true, "successful final output is not vetoed by a historical failed receipt")
        let replacement = try receipt("replacement", tool: search, args: ["query": "different"])
        try ConnectorReadFailure.validate(FullAcceptanceTests.envelope(quiet, raw: failedRead + "\n" + replacement), slug: "gmail")
        try check(true, "successful final output accepts an adapted recovery query")
        var rejected = false
        let attempts = Mutex(0)
        let conflict = FullAcceptanceTests.envelope(quiet.replacingOccurrences(of: #""tool_failure":"""#, with: #""tool_failure":"other""#), raw: repaired.raw)
        let summary = try await FrontierRun.$acceptanceRun.withValue({ _ in
            attempts.withLock { $0 += 1; return $0 == 1 ? conflict : repaired }
        }) { try await GoogleSourceRead.read(.init(prompt: "Synthetic bounded read"), slug: "gmail", countKey: "thread_count") }
        try check(summary == nil && attempts.withLock({ $0 }) == 2, "explicit model read failure gets one fresh Google read")
        attempts.withLock { $0 = 0 }
        rejected = false
        do {
            _ = try await FrontierRun.$acceptanceRun.withValue({ _ in attempts.withLock { $0 += 1 }; return conflict }) {
                try await GoogleSourceRead.read(.init(prompt: "Synthetic bounded read"), slug: "gmail", countKey: "thread_count")
            }
        } catch MCPSource.MCPError.toolFailure { rejected = true }
        try check(rejected && attempts.withLock({ $0 }) == 2, "persistent explicit read failure remains typed after two attempts")
        attempts.withLock { $0 = 0 }
        let auth = FullAcceptanceTests.envelope(#"{"tool_failure":"auth"}"#, raw: discovered)
        rejected = false
        do {
            _ = try await FrontierRun.$acceptanceRun.withValue({ _ in attempts.withLock { $0 += 1 }; return auth }) {
                try await GoogleSourceRead.read(.init(prompt: "Synthetic bounded read"), slug: "gmail", countKey: "thread_count")
            }
        } catch MCPSource.MCPError.connectorAuth { rejected = true }
        try check(rejected && attempts.withLock({ $0 }) == 1, "Google authentication failure does not retry")
        for slug in ["gmail", "google-calendar"] {
            attempts.withLock { $0 = 0 }
            let key = slug == "gmail" ? "thread_count" : "event_count"
            let finalReply = quiet.replacingOccurrences(of: "thread_count", with: key)
            try await Diagnostics.withOperation("processing") {
                let processing = Diagnostics.current!
                _ = try await FrontierRun.$acceptanceRun.withValue({ _ in
                    try await Diagnostics.withOperation("frontier_run") {
                        try await Diagnostics.boundary(.connectorFailed, phase: .request, reason: "frontier_setup") {
                            if attempts.withLock({ $0 += 1; return $0 }) == 1 {
                                throw CodexCLI.CLIError.exitFailure(code: 1, message: "StructuredOutput does not match required schema")
                            }
                            return FullAcceptanceTests.envelope(finalReply)
                        }
                    }
                }) { try await GoogleSourceRead.read(.init(prompt: "Synthetic bounded read"), slug: slug, countKey: key) }
                try check(attempts.withLock({ $0 }) == 2, "\(slug) terminal formatting failure gets one bounded retry")
                try check(!processing.hasFailure, "\(slug) recovered formatting failure cannot mark its processing parent failed")
            }
        }
        attempts.withLock { $0 = 0 }
        rejected = false
        do {
            _ = try await FrontierRun.$acceptanceRun.withValue({ _ in attempts.withLock { $0 += 1 }; throw CancellationError() }) {
                try await GoogleSourceRead.read(.init(prompt: "Synthetic bounded read"), slug: "gmail", countKey: "thread_count")
            }
        } catch is CancellationError { rejected = true }
        try check(rejected && attempts.withLock({ $0 }) == 1, "Google cancellation is preserved without another model call")

        let genericGood = #"{"item_count":1,"notable":true,"summary":"A completed synthetic summary without citation receipts.","has_action_items":false,"tool_failure":""}"#
        let genericFailure = #"{"item_count":0,"notable":false,"summary":"","has_action_items":false,"tool_failure":"other"}"#
        for (firstReply, label) in [(genericFailure, "explicit failure"), ("{}", "malformed output")] {
            attempts.withLock { $0 = 0 }
            try await Diagnostics.withOperation("processing") {
                let processing = Diagnostics.current!
                let outcome = try await FrontierRun.$acceptanceRun.withValue({ _ in
                    try await Diagnostics.withOperation("frontier_run") {
                        try await Diagnostics.boundary(.connectorFailed, phase: .request, reason: "frontier_setup") {
                            let result = attempts.withLock { $0 += 1; return $0 == 1 ? firstReply : genericGood }
                            let response = FullAcceptanceTests.envelope(result)
                            try ConnectorReadFailure.validate(response, slug: "google-drive")
                            return response
                        }
                    }
                }) { try await MCPSource.read(slug: "google-drive", prompt: "Synthetic selected source", mode: .initial) }
                try check(outcome.itemCount == 1 && attempts.withLock({ $0 }) == 2,
                          "generic first analysis retries \(label) and accepts completed output without receipts")
                try check(!processing.hasFailure,
                          "recovered generic \(label) cannot mark its processing parent failed")
            }
        }

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

    private static func identityRetries() async throws {
        // Production identity readers cache verified native profiles. Keep these fixtures out
        // of the user's preference domain, including when reliabilitycheck is run manually.
        try check(Bundle.main.bundleIdentifier == "ai.sentientos.acceptance"
                  && (ProcessInfo.processInfo.environment["SENTIENT_VAULT_ROOT"] ?? "")
                    .hasPrefix("/private/tmp/sentient-acceptance/"),
                  "identity retry fixtures require the isolated acceptance app and vault")
        let defaults = UserDefaults.standard
        let slugs = ["google-drive", "slack", "outlook-mail", "outlook-calendar"]
        let keys = slugs.dropFirst().map { "mcp.\($0).identity.chatgpt" }
        let saved = defaults.persistentDomain(forName: "ai.sentientos.acceptance") ?? [:]
        let argumentDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = argumentDomain
        for slug in slugs {
            temporary[ConnectorRegistry.readGenerationKey(slug, "chatgpt")] = Int.random(in: 1_000_000...Int.max)
        }
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        defer {
            for key in keys {
                if let value = saved[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            // Cached in-memory Outlook identities now belong to the expired test generation.
            defaults.setVolatileDomain(argumentDomain, forName: UserDefaults.argumentDomain)
        }
        func codexReceipt(_ id: String, tool: String, args: [String: Any] = [:],
                          result: [String: Any]) throws -> String {
            try json(["type": "item.completed", "item": ["id": id, "type": "mcp_tool_call",
                "server": "codex_apps", "tool": tool, "arguments": args,
                "status": "completed", "result": result]])
        }
        let drive = try codexReceipt("drive-profile", tool: "google_drive.get_profile", result: [
            "content": [], "isError": false,
            "structured_content": ["id": "synthetic-drive-account", "email": "fixture@example.invalid"]])
        let slackProfile = try codexReceipt("slack-profile", tool: "slack." + SlackConnector.profileTool,
            args: ["response_format": "detailed", "include_locale": false], result: ["isError": false,
                "content": [["type": "text", "text": try json(["result": "User ID: UFIXTURE\nOrganization Name: Fixture\n"])]]])
        let slackWorkspace = try codexReceipt("slack-workspace", tool: "slack." + SlackConnector.workspaceTool,
            args: ["limit": 50, "include_icon": false], result: ["content": [], "isError": false,
                "structured_content": ["ok": true, "teams": [["id": "TFIXTURE", "name": "Fixture"]],
                                       "response_metadata": ["next_cursor": ""]]])
        let profile: [String: Any] = ["id": "11111111-1111-1111-1111-111111111111", "email": "fixture@example.invalid"]
        let outlookMail = try OutlookCurationTests.receipt(backend: .chatgpt,
            name: OutlookMailConnector.profileTool(.chatgpt), arguments: [:], payload: [profile])
        let outlookCalendar = try codexReceipt("calendar-profile",
            tool: "microsoft_outlook_calendar." + OutlookCalendarConnector.profileTool(.chatgpt),
            result: ["content": [], "isError": false, "structured_content": profile])
        for (slug, raw) in zip(slugs, [drive, slackProfile + "\n" + slackWorkspace, outlookMail, outlookCalendar]) {
            let attempts = Mutex(0)
            try await Diagnostics.withOperation("processing") {
                let processing = Diagnostics.current!
                let identity = try await FrontierRun.$acceptanceRun.withValue({ _ in
                    try await Diagnostics.withOperation("frontier_run") {
                        try await Diagnostics.boundary(.connectorFailed, phase: .request, reason: "frontier_setup") {
                            if attempts.withLock({ $0 += 1; return $0 }) == 1 { throw CodexCLI.CLIError.timedOut(after: 1) }
                            return FullAcceptanceTests.envelope(raw: raw)
                        }
                    }
                }) { try await MCPSource.readIdentity(slug: slug) }
                try check(identity?.count == 64 && attempts.withLock({ $0 }) == 2,
                          "\(slug) identity retry accepts a verified native profile after one timeout")
                try check(!processing.hasFailure,
                          "\(slug) recovered identity timeout cannot mark its processing parent failed")
            }
            attempts.withLock { $0 = 0 }
            try await Diagnostics.withOperation("processing") {
                let processing = Diagnostics.current!
                var terminalError: Error?
                do {
                    _ = try await FrontierRun.$acceptanceRun.withValue({ _ in
                        try await Diagnostics.withOperation("frontier_run") {
                            try await Diagnostics.boundary(.connectorFailed, phase: .request, reason: "frontier_setup") {
                                attempts.withLock { $0 += 1 }
                                throw CodexCLI.CLIError.timedOut(after: 1)
                            }
                        }
                    }) { try await MCPSource.readIdentity(slug: slug) }
                } catch { terminalError = error }
                guard let terminalError, case CodexCLI.CLIError.timedOut = terminalError else {
                    throw FullAcceptanceTests.Failure(message: "\(slug) exhausted identity timeout lost its typed failure")
                }
                try check(attempts.withLock({ $0 }) == 2 && !processing.hasFailure,
                          "\(slug) exhausted identity attempts remain bounded and await caller outcome reporting")
                Diagnostics.report(.sourceReadFailed, phase: .read, reason: "connector_read", error: terminalError, source: slug)
                try check(processing.hasFailure, "\(slug) final identity failure still marks processing failed when reported by its caller")
            }
        }
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
        let withoutSamples = try DoubleTapInference.packVault(root)
        try check(withoutSamples.notes == 1 && withoutSamples.text.contains("Synthetic knowledge"),
                  "Double Tap packs valid knowledge when optional writing examples are absent")
        try "# Writing samples\nSynthetic sample.\n".write(to: root.appendingPathComponent(WritingStyle.fileName), atomically: true, encoding: .utf8)
        let packed = try DoubleTapInference.packVault(root)
        try check(packed.notes == 1 && packed.text.contains("Synthetic sample."),
                  "optional writing samples join the existing knowledge context")
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
