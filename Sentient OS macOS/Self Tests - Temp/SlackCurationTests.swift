#if DEBUG
//
// SlackCurationTests.swift
// Isolated checks for hosted Slack curation: actual tool receipts and outcome verification.
// Uses synthetic events only. Live curation records stay outside the app repository.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
//

import Foundation

enum SlackCurationTests {
    static func router() async {
        let services = ["slack", "gmail", "notion"].compactMap { slug -> CommandRouter.Service? in
            guard let pack = ConnectorRegistry.pack(forSlug: slug) else { return nil }
            return .init(slug: slug, name: pack.displayName, description: pack.routerDescription ?? "")
        }
        let cases: [(String, String?, SlackConnector.Operation?)] = [
            ("Find the Slack thread about the release decision", "slack", .read),
            ("Send Jesai one Slack message saying the build is green", "slack", .send),
            ("Draft a Slack update without sending it", "slack", .draft),
            ("Save a draft reply in Slack; do not send it", "slack", .draft),
            ("Reply in Slack thread https://fixture.slack.com/archives/CFIXTURE/p1700000000000000 saying yes", "slack", .send),
            ("Resize the Slack window", nil, nil),
            ("Search Slack and create a Notion page about the decision", nil, nil),
            ("Send two separate Slack messages, one to each of two people", nil, nil),
            ("Send Jesai an email saying thanks for the Slack update", "gmail", nil)
        ]
        var failures = 0
        var connectorFallbacks = 0
        for (command, expected, operation) in cases {
            let route = await CommandRouter.route(command, services: services)
            let passed: Bool
            switch route {
            case .computer:
                if expected != nil { connectorFallbacks += 1 }
                passed = expected == nil || connectorFallbacks <= 2
            case .connector(let slug, _, let actual, _, _): passed = slug == expected && actual == operation
            }
            if !passed { failures += 1 }
            Log("\(passed ? "PASS" : "FAIL") Slack router: \(command)")
        }
        Log("Slack router checks: \(cases.count) cases, \(failures) failures, \(connectorFallbacks) connector-to-computer fallback(s), bar=2")
        if failures > 0 { exit(1) }
    }

    static func run() {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1 }
            Log("\(condition ? "PASS" : "FAIL") \(label)")
        }
        func stream(_ events: [[String: Any]]) -> String {
            events.map { String(data: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), encoding: .utf8)! }
                .joined(separator: "\n")
        }
        check(ConnectorRegistry.isValidCodexCatalogID("asdk_app_00000000000000000000000000000001"),
              "hosted Apps SDK identity is accepted")
        check(ConnectorRegistry.isValidCodexCatalogID("connector_00000000000000000000000000000001"),
              "legacy hosted identity remains accepted")
        for invalid in ["asdk_app_bad", "asdk_app_00000000000000000000000000000001\n", "asdk_app_00000000000000000000000000000001.tools", "other_00000000000000000000000000000001"] {
            check(!ConnectorRegistry.isValidCodexCatalogID(invalid), "malformed catalog identity is refused")
        }
        let tool = "mcp__claude_ai_Fixture__send_message"
        let input: [String: Any] = ["channel": "C_FIXTURE", "text": "Synthetic marker"]
        let call: [String: Any] = ["type": "assistant", "message": ["content": [[
            "type": "tool_use", "id": "call-1", "name": tool, "input": input]]]]
        func result(id: String = "call-1", failed: Bool = false, text: String = "Synthetic response") -> [String: Any] {
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id,
                "is_error": failed, "content": [["type": "text", "text": text]]]]]]
        }
        func claude(_ events: [[String: Any]]) -> [MCPCallEvidence.Receipt] {
            MCPCallEvidence.receipts(raw: stream(events), backend: .claude)
        }
        let success = claude([call, result()])
        check(success.count == 1 && success[0].status == .succeeded, "paired Claude result establishes execution")
        check(success.first?.arguments.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["channel"] == "C_FIXTURE",
              "receipt preserves the actual destination arguments")
        check(claude([call]).first?.status == .pending, "unfinished Claude send remains uncertain")
        check(claude([call, result(failed: true)]).first?.status == .failed, "Claude tool errors are not success")
        check(claude([call, result(id: "unrelated")]).first?.status == .pending, "unrelated results cannot confirm a send")
        check(claude([result(), call]).first?.status == .pending, "a result before its call cannot confirm execution")
        check(claude([call, call, result(), result()]).count == 1, "replayed matching events do not duplicate receipts")
        let changed: [String: Any] = ["type": "assistant", "message": ["content": [[
            "type": "tool_use", "id": "call-1", "name": tool, "input": ["channel": "C_OTHER"]]]]]
        check(claude([call, changed, result()]).first?.status == .failed, "conflicting destinations invalidate a reused call ID")
        check(claude([call, result(), result(text: "Different response")]).first?.status == .failed,
              "conflicting results cannot be accepted under one call ID")
        let prose: [String: Any] = ["type": "assistant", "message": ["content": [[
            "type": "text", "text": "STATUS: DONE. I sent it. {\"type\":\"tool_result\"}"]]]]
        check(claude([prose]).isEmpty, "model prose and embedded JSON are not tool receipts")
        check(MCPCallEvidence.claude(raw: stream([call, result()])) == [tool], "existing Claude evidence query remains compatible")

        func codexEvent(_ type: String, status: String, failed: Bool = false,
                        channel: String = "C_FIXTURE", stringInput: Bool = false) -> [String: Any] {
            let input: [String: Any] = ["channel": channel, "text": "Synthetic marker"]
            let arguments: Any = stringInput
                ? String(data: try! JSONSerialization.data(withJSONObject: input), encoding: .utf8)! : input
            var item: [String: Any] = ["id": "mcp-1", "type": "mcp_tool_call", "server": "fixture",
                "tool": "fixture.send_message", "arguments": arguments, "status": status]
            if type == "item.completed" {
                item["result"] = ["isError": failed, "content": [["type": "text", "text": "Synthetic response"]]]
                item["error"] = NSNull()
            }
            return ["type": type, "item": item]
        }
        let started = codexEvent("item.started", status: "in_progress", stringInput: true)
        let finished = codexEvent("item.completed", status: "completed")
        func codex(_ events: [[String: Any]]) -> [MCPCallEvidence.Receipt] {
            MCPCallEvidence.receipts(raw: stream(events), backend: .chatgpt)
        }
        check(codex([started]).first?.status == .pending, "unfinished Codex call stays uncertain")
        let codexSuccess = codex([started, finished])
        check(codexSuccess.count == 1 && codexSuccess[0].status == .succeeded,
              "Codex string and object arguments match semantically")
        check(codexSuccess.first?.server == "fixture", "Codex server identity is retained")
        check(codex([started, codexEvent("item.completed", status: "completed", failed: true)]).first?.status == .failed,
              "Codex MCP error results are not success")
        check(codex([started, codexEvent("item.completed", status: "failed")]).first?.status == .failed,
              "a failed Codex item cannot establish success")
        check(codex([started, codexEvent("item.completed", status: "completed", channel: "C_OTHER")]).first?.status == .failed,
              "a changed destination invalidates a Codex call")
        check(codex([finished, finished]).count == 1, "replayed Codex completion produces one receipt")
        check(MCPCallEvidence.codex(raw: stream([finished])).first?.tool == "fixture.send_message",
              "existing Codex evidence query remains compatible")
        check(MCPCallEvidence.receipts(raw: stream([finished]), backend: .custom).isEmpty,
              "custom model responses cannot establish hosted-account evidence")
        check(MCPCallEvidence.receipts(raw: "not json\n{}", backend: .chatgpt).isEmpty,
              "malformed streams contain no successful receipts")

        func profileTrace(backend: ModelBackend, userID: String = "UFIXTURE", workspace: String = "Fixture",
                          requestedUser: String? = nil, extra: String = "", teamCount: Int = 1) -> String {
            let body = "User ID: \(userID)\nOrganization Name: \(workspace)\n" + extra
            var args: [String: Any] = ["response_format": "detailed"]
            if let requestedUser { args["user_id"] = requestedUser }
            if backend == .claude {
                return stream([
                    ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "profile",
                        "name": SlackConnector.claudePrefix + SlackConnector.profileTool, "input": args]]]],
                    ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "profile",
                        "content": [["type": "text", "text": body]], "is_error": false]]]]
                ])
            }
            let wrapped = String(data: try! JSONSerialization.data(withJSONObject: ["result": body]), encoding: .utf8)!
            return stream([
                ["type": "item.completed", "item": ["type": "mcp_tool_call", "id": "profile", "server": "codex_apps",
                    "tool": "slack." + SlackConnector.profileTool, "status": "completed", "arguments": args,
                    "result": ["content": [["type": "text", "text": wrapped]], "isError": false]]],
                ["type": "item.completed", "item": ["type": "mcp_tool_call", "id": "workspace", "server": "codex_apps",
                    "tool": "slack." + SlackConnector.workspaceTool, "status": "completed", "arguments": ["limit": 50],
                    "result": ["content": [], "structuredContent": ["ok": true,
                        "teams": (0..<teamCount).map { ["id": "TFIXTURE\($0)", "name": workspace] },
                        "response_metadata": ["next_cursor": ""]], "isError": false]]]
            ])
        }
        for backend in [ModelBackend.claude, .chatgpt] {
            let trace = profileTrace(backend: backend)
            let identity = try? SlackConnector.identity(raw: trace, backend: backend)
            check(identity?.userID == "UFIXTURE" && identity?.workspaceName == "Fixture", "\(backend.rawValue) identity comes from a successful self-profile")
            check(identity?.fingerprint.count == 64, "\(backend.rawValue) identity uses a local stable fingerprint")
            check((try? SlackConnector.identity(raw: profileTrace(backend: backend, requestedUser: "UOTHER"), backend: backend)) == nil,
                  "\(backend.rawValue) another user's profile cannot identify the authenticated actor")
            check((try? SlackConnector.identity(raw: profileTrace(backend: backend, extra: "User ID: UOTHER\n"), backend: backend)) == nil,
                  "\(backend.rawValue) duplicate identity fields are refused")
            check((try? SlackConnector.identity(raw: profileTrace(backend: backend, workspace: ""), backend: backend)) == nil,
                  "\(backend.rawValue) a missing workspace cannot silently reuse old scope")
            check((try? SlackConnector.identity(raw: profileTrace(backend: backend, workspace: "Changed"), backend: backend))?.fingerprint != identity?.fingerprint,
                  "\(backend.rawValue) workspace changes invalidate prior identity")
        }
        check((try? SlackConnector.identity(raw: profileTrace(backend: .chatgpt, teamCount: 2), backend: .chatgpt)) == nil,
              "ambiguous multi-workspace installations do not inherit a single-workspace checkpoint")
        let reviewed = SlackConnector.categories(backend: .claude).map {
            ConnectorRegistry.ClassifiedTool(name: SlackConnector.claudePrefix + $0.key, category: $0.value)
        }
        check(reviewed.count == 27 && SlackConnector.categories(backend: .chatgpt).count == 36,
              "independent engine inventories preserve their different surfaces")
        do { try SlackConnector.validateClassification(reviewed); check(true, "complete reviewed Slack classification validates") }
        catch { check(false, "complete reviewed Slack classification validates") }
        for invalid in [Array(reviewed.dropLast()), reviewed + [reviewed[0]], reviewed.map {
            ConnectorRegistry.ClassifiedTool(name: $0.name,
                category: $0.category == .destructive ? .write : $0.category)
        }] {
            do { try SlackConnector.validateClassification(invalid); check(false, "incomplete or unsafe classification must fail") }
            catch { check(true, "incomplete or unsafe classification is refused") }
        }
        let window = MCPSource.Window(lower: Date(timeIntervalSince1970: 1_700_000_000),
                                      upper: Date(timeIntervalSince1970: 1_700_086_400), label: "Fixture")
        let bounds = SlackSource.searchBounds(window)
        check(bounds.after == "1700000000.000000" && bounds.before == "1700086399.999999",
              "inclusive Slack filters preserve the exact half-open window")
        let fixtureLink = "https://fixture.slack.com/archives/CFIXTURE/p1700000000000000"
        check(SlackSource.sourceLinks(fixtureLink) == [fixtureLink], "observed Slack message links are recognized")
        for invalid in [fixtureLink + "evil", "https://fixture.slack.com.evil.test/archives/CFIXTURE/p1700000000000000",
                        "https://app.slack.com/client/TFIXTURE/CFIXTURE"] {
            check(SlackSource.sourceLinks(invalid).isEmpty, "spoofed or channel-only links cannot ground a claim")
        }
        for backend in [ModelBackend.claude, .chatgpt] {
            let identity = SlackConnector.Identity(userID: "UFIXTURE", workspaceName: "Fixture",
                workspaceID: backend == .chatgpt ? "TFIXTURE" : nil, backend: backend.rawValue)
            SlackConnector.$runIdentity.withValue(identity) {
                func searchTrace(queries: [String] = ["to:me", "from:<@UFIXTURE>", SlackSource.broadQuery(window)],
                                 limit: Int = 10, before: String? = nil, bots: Bool = false,
                                 failed: Bool = false, body: String? = nil, extra: [String: Any] = [:]) -> String {
                    var events: [[String: Any]] = []
                    for (i, query) in queries.enumerated() {
                        var args: [String: Any] = ["query": query, "limit": limit, "after": bounds.after,
                            "before": before ?? bounds.before, "content_types": "messages",
                            "channel_types": "public_channel,private_channel,mpim,im", "include_bots": bots,
                            "include_context": false, "sort": "timestamp", "sort_dir": "desc", "response_format": "detailed"]
                        args.merge(extra) { _, replacement in replacement }
                        let text = body ?? "# Search Results for: \(query)\n\nNo results found.\n"
                        if backend == .claude {
                            events.append(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "search\(i)",
                                "name": SlackConnector.claudePrefix + "slack_search_public_and_private", "input": args]]]])
                            events.append(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "search\(i)",
                                "content": [["type": "text", "text": text]], "is_error": failed]]]])
                        } else {
                            let wrapped = String(data: try! JSONSerialization.data(withJSONObject: ["results": text,
                                "pagination_info": "End of results"]), encoding: .utf8)!
                            events.append(["type": "item.completed", "item": ["id": "search\(i)", "type": "mcp_tool_call",
                                "server": "codex_apps", "tool": "slack.slack_search_public_and_private", "arguments": args,
                                "status": "completed", "result": ["isError": failed, "content": [["type": "text", "text": wrapped]]]]])
                        }
                    }
                    return stream(events)
                }
                func accepts(_ raw: String, outcome: MCPSource.ReadOutcome = .quiet(itemCount: 0)) -> Bool {
                    do { try SlackSource.validate(raw: raw, backend: backend, mode: .iterative, window: window, outcome: outcome); return true }
                    catch { return false }
                }
                check(accepts(searchTrace()), "\(backend.rawValue) successful bounded searches establish a quiet window")
                check(accepts(searchTrace(extra: ["filters": "", "keywords": [], "natural_language_query": ""])), "\(backend.rawValue) empty optional search fields preserve coverage")
                check(!accepts(searchTrace(extra: ["filters": "in:one-channel"])), "\(backend.rawValue) extra filters cannot narrow a quiet read")
                check(!accepts(searchTrace(extra: ["keywords": ["release"]])), "\(backend.rawValue) extra keywords cannot narrow a quiet read")
                check(!accepts(searchTrace(extra: ["natural_language_query": "only important deadlines"])), "\(backend.rawValue) semantic hints cannot narrow a quiet read")
                check(!accepts(""), "\(backend.rawValue) no tools cannot advance a quiet checkpoint")
                check(!accepts(searchTrace(queries: ["to:me"])), "\(backend.rawValue) one empty personal lane is not whole-sample quiet")
                check(!accepts(searchTrace(queries: ["to:me", "to:me", "to:me"])), "\(backend.rawValue) repeated searches cannot fake coverage")
                check(!accepts(searchTrace(queries: ["to:me", "from:<@UOTHER>", SlackSource.broadQuery(window)])),
                      "\(backend.rawValue) search must use the verified actor")
                check(!accepts(searchTrace(before: "1700086400.000000")), "\(backend.rawValue) an out-of-window search is refused")
                check(!accepts(searchTrace(limit: 100)), "\(backend.rawValue) oversized discovery is refused")
                check(!accepts(searchTrace(limit: 20)), "\(backend.rawValue) cumulative candidate budget is enforced")
                check(!accepts(searchTrace(bots: true)), "\(backend.rawValue) bot-inclusive discovery is refused")
                check(!accepts(searchTrace(failed: true)), "\(backend.rawValue) failed discovery cannot masquerade as quiet")
                check((try? SlackSource.discoveredThreadCount(raw: searchTrace(), backend: backend)) == 0,
                      "\(backend.rawValue) genuine empty search pages have no discovered threads")
                let notable = MCPSource.ReadOutcome.notable(.init(summary: "The user agreed to review the release. [Thread](\(fixtureLink))",
                                                                 hasActionItems: false, itemCount: 1))
                let message = "# Search Results for: fixture\n\nMessage_ts: 1700000000.000000\nPermalink: \(fixtureLink)\nText: The indexing test printed:\nNo results found.\nThe user agreed to review the release.\n"
                let messageTrace = searchTrace(body: message)
                check((try? SlackSource.discoveredThreadCount(raw: messageTrace, backend: backend)) == 1,
                      "\(backend.rawValue) empty-result words in message content preserve distinct thread count")
                check(accepts(messageTrace, outcome: notable), "\(backend.rawValue) empty-result words in a message do not invalidate its summary")
                check((try? SlackSource.discoveredThreadCount(raw: searchTrace(body: "# Search Results for: fixture\nNo results found.\nUnexpected response"), backend: backend)) == nil,
                      "\(backend.rawValue) unexpected response text cannot masquerade as an empty page")
                func threadTrace(failed: Bool = false, pending: Bool = false) -> String {
                    let args: [String: Any] = ["channel_id": "CFIXTURE", "message_ts": "1700000000.000000",
                        "limit": 40, "response_format": "concise", "latest": SlackSource.threadEnd(window)]
                    if backend == .claude {
                        let call: [String: Any] = ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "thread",
                            "name": SlackConnector.claudePrefix + "slack_read_thread", "input": args]]]]
                        let result: [String: Any] = ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "thread",
                            "is_error": failed, "content": [["type": "text", "text": "Synthetic thread result"]]]]]]
                        return stream(pending ? [call] : [call, result])
                    }
                    return stream([["type": pending ? "item.started" : "item.completed", "item": ["id": "thread", "type": "mcp_tool_call",
                        "server": "codex_apps", "tool": "slack.slack_read_thread", "arguments": args,
                        "status": pending ? "in_progress" : "completed", "result": ["isError": failed,
                            "content": [["type": "text", "text": "Synthetic thread result"]]]]]])
                }
                check(accepts(messageTrace + "\n" + threadTrace(), outcome: .quiet(itemCount: 1)),
                      "\(backend.rawValue) successful selected thread can complete a quiet read")
                for tail in [threadTrace(failed: true), threadTrace(pending: true)] {
                    check(!accepts(messageTrace + "\n" + tail, outcome: .quiet(itemCount: 1)),
                          "\(backend.rawValue) failed or unfinished selected thread cannot advance as quiet")
                    check(!accepts(messageTrace + "\n" + tail, outcome: notable),
                          "\(backend.rawValue) partial success cannot hide a failed or unfinished selected thread")
                }
                check(accepts(searchTrace(queries: ["to:me"], body: "# Search Results for: to:me\n\n\(fixtureLink)\nA supported message."), outcome: notable),
                      "\(backend.rawValue) a notable result needs observed content references")
                check(!accepts(searchTrace(), outcome: notable), "\(backend.rawValue) invented source references are refused")
                let unsourced = MCPSource.ReadOutcome.notable(.init(summary: "The user has one fact. [Thread](\(fixtureLink))\n\nAnother unsupported claim.",
                                                                  hasActionItems: false, itemCount: 1))
                check(!accepts(searchTrace(body: "# Search Results for: fixture\n\n\(fixtureLink)"), outcome: unsourced),
                      "\(backend.rawValue) each retained paragraph needs a source")
            }
        }
        failures += SlackActionTests.run()
        Log("Slack curation checks: \(checks) source checks plus action checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#endif
