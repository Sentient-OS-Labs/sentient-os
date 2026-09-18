#if DEBUG
//
// SlackActionTests.swift
// Synthetic action receipts, prepared-message policy, and one-send lifecycle checks.
// No Slack account or message is touched by these tests.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
//

import Foundation

enum SlackActionTests {
    static func run() -> Int {
        var failures = 0, checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1 }
            Log("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let message = "Approved fixture"
        let defaults = UserDefaults.standard
        let savedDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(savedDomain, forName: UserDefaults.argumentDomain) }
        let timestamp = "1700000001.123456"
        let link = "https://fixture.slack.com/archives/DFIXTURE/p1700000001123456"
        func encode(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)! }
        for backend in [ModelBackend.claude, .chatgpt] {
            let identity = SlackConnector.Identity(userID: "UFIXTURE", workspaceName: "Fixture",
                workspaceID: backend == .chatgpt ? "TFIXTURE" : nil, backend: backend.rawValue)
            func call(_ name: String, id: String, arguments: [String: Any], result: [String: Any], failed: Bool = false) -> String {
                let content = [["type": "text", "text": encode(result)]]
                if backend == .claude {
                    return encode(["type": "assistant", "message": ["content": [["type": "tool_use", "id": id,
                        "name": SlackConnector.claudePrefix + name, "input": arguments]]]]) + "\n"
                    + encode(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id,
                        "content": content, "is_error": failed]]]])
                }
                return encode(["type": "item.completed", "item": ["id": id, "type": "mcp_tool_call", "server": "codex_apps",
                    "tool": "slack." + name, "arguments": arguments, "status": "completed",
                    "result": ["content": content, "isError": failed]]])
            }
            func send(id: String = "send", target: String = "DFIXTURE", body: String = message,
                      returnedChannel: String = "DFIXTURE", returnedLink: String = link, failed: Bool = false) -> String {
                call("slack_send_message", id: id, arguments: ["channel_id": target, "message": body],
                    result: ["message_link": returnedLink, "message_context": ["channel_id": returnedChannel, "message_ts": timestamp]], failed: failed)
            }
            func read(body: String = message, actor: String = "UFIXTURE", time: String = timestamp,
                      channel: String = "DFIXTURE", failed: Bool = false) -> String {
                call("slack_read_channel", id: "read", arguments: ["channel_id": channel, "limit": 10],
                    result: ["messages": "Channel: DM (\(channel))\n\n=== Message from Fixture (\(actor)) at 2026-09-14 12:00 PDT === \nMessage TS: \(time)\n\(body)\n*Sent using* <@BFIXTURE|Fixture>"], failed: failed)
            }
            func accepts(_ raw: String, operation: SlackConnector.Operation = .send, expected: String? = message) -> Bool {
                do {
                    try SlackActionEvidence.validate(raw: raw, backend: backend, operation: operation,
                        identity: identity, expectedMessage: expected)
                    return true
                } catch { return false }
            }
            check(accepts(send() + "\n" + read()), "\(backend.rawValue) matching send plus subsequent read confirms the result")
            check(accepts(send(target: "UFIXTURE") + "\n" + read()), "\(backend.rawValue) a user destination resolves to its returned DM")
            check(!accepts(read()), "\(backend.rawValue) a read cannot prove a send")
            check(!accepts(send()), "\(backend.rawValue) send confirmation also requires a matching read-back")
            check(!accepts(read() + "\n" + send()), "\(backend.rawValue) an earlier read cannot confirm a later send")
            check(!accepts(send() + "\n" + read(actor: "UOTHER")), "\(backend.rawValue) read-back must identify the authenticated sender")
            check(!accepts(send() + "\n" + read(time: "1700000002.123456")), "\(backend.rawValue) another message cannot confirm this send")
            check(!accepts(send() + "\n" + read(body: "Different content")), "\(backend.rawValue) changed message content is not confirmed")
            check(!accepts(send() + "\n" + read(channel: "DOTHER")), "\(backend.rawValue) a different conversation is not confirmation")
            check(!accepts(send(returnedChannel: "DOTHER") + "\n" + read()), "\(backend.rawValue) send link and returned IDs must agree")
            check(!accepts(send(returnedLink: link + "evil") + "\n" + read()), "\(backend.rawValue) malformed result links are refused")
            check(!accepts(send(failed: true) + "\n" + read()), "\(backend.rawValue) failed sends remain unconfirmed")
            check(!accepts(send() + "\n" + read(failed: true)), "\(backend.rawValue) failed reads cannot verify a send")
            check(!accepts(send() + "\n" + read(), expected: "The reviewed text"), "\(backend.rawValue) the approved artifact must match")
            check(!accepts(send() + "\n" + read() + "\n" + send(id: "second")), "\(backend.rawValue) a single-send task cannot report two sends as success")
            check(!accepts(send() + "\n" + read(), operation: .draft), "\(backend.rawValue) sending never counts as drafting")
            check(accepts(read(), operation: .read, expected: nil), "\(backend.rawValue) a read task can complete without a write")

            let name = backend == .claude ? SlackConnector.claudePrefix + "slack_send_message" : "mcp__codex_apps__slack__slack_send_message"
            let input: [String: Any] = ["channel_id": "DFIXTURE", "message": message]
            check(SlackToolPolicy.allowed(name: name, input: input, backend: backend, operation: .send,
                expectedMessageHash: SlackToolPolicy.messageHash(message)), "\(backend.rawValue) the reviewed message is permitted")
            check(!SlackToolPolicy.allowed(name: name, input: input, backend: backend, operation: .send,
                expectedMessageHash: SlackToolPolicy.messageHash("Changed")), "\(backend.rawValue) altered reviewed content is blocked before execution")
            check(!SlackToolPolicy.allowed(name: name, input: input, backend: backend, operation: .draft), "\(backend.rawValue) draft tasks have no send approval")
            check(!SlackToolPolicy.allowed(name: name, input: input.merging(["draft_id": "existing"]) { _, new in new },
                backend: backend, operation: .send), "\(backend.rawValue) existing drafts cannot be consumed")
            check(!SlackToolPolicy.allowed(name: name, input: input.merging(["reply_broadcast": true]) { _, new in new },
                backend: backend, operation: .send), "\(backend.rawValue) an extra broadcast is blocked")
            ModelBackend.$runOverride.withValue(backend) {
                var domain = savedDomain
                let origin = ConnectorRegistry.readOrigin(slug: "slack", backend: backend)
                func install(_ identity: SlackConnector.Identity) {
                    let object: [String: Any] = ["identity": ["userID": identity.userID, "workspaceName": identity.workspaceName,
                        "workspaceID": identity.workspaceID as Any? ?? NSNull(), "backend": identity.backend], "origin": origin]
                    domain["mcp.slack.identity.\(backend.rawValue)"] = try! JSONSerialization.data(withJSONObject: object)
                    defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
                }
                install(identity)
                let card = PreparedAction(title: "Fixture", method: .mcp, target: "Slack", methodTarget: "slack",
                    connectorIdentity: identity.fingerprint, urgency: .low, dueDate: nil, status: .confirmed,
                    verification: "Synthetic", cardSummary: "Fixture", preparedContent: message, executionRecipe: "Send fixture",
                    recipient: "Fixture", buttonText: "Send", detailLabel: "Thread", sources: [], reviewNote: "")
                check(ProactiveExecutor.isFireable(card), "\(backend.rawValue) a prepared card retains its verified account")
                let decoded = try! JSONDecoder().decode(PreparedAction.self, from: JSONEncoder().encode(card))
                check(decoded.connectorIdentity == identity.fingerprint, "\(backend.rawValue) card persistence retains account binding")
                var legacy = card; legacy.connectorIdentity = nil
                check(!ProactiveExecutor.isFireable(legacy), "\(backend.rawValue) an unbound legacy Slack card cannot fire")
                install(.init(userID: identity.userID, workspaceName: "Different", workspaceID: identity.workspaceID, backend: identity.backend))
                check(!ProactiveExecutor.isFireable(card), "\(backend.rawValue) workspace changes make the old card unavailable")
                var other = card; other.methodTarget = "google-drive"; other.connectorIdentity = nil
                check(ProactiveExecutor.isFireable(other), "\(backend.rawValue) other connector cards retain their behavior")
            }
        }
        let runID = UUID()
        check(SlackToolPolicy.claimSend(runID: runID), "a new send task reserves its one send")
        check(!SlackToolPolicy.claimSend(runID: runID), "a repeated send in the same task is refused")
        SlackToolPolicy.cleanup(runID: runID)
        var source = MCPSource.readInvocation(slug: "slack", prompt: "Fixture")
        check(ClaudeCLI.environment(for: source)["ENABLE_TOOL_SEARCH"] == "false", "Slack's small read surface is eager and visible")
        check(ClaudeCLI.environment(for: source)["MCP_CONNECTION_NONBLOCKING"] == "0", "source reads wait for MCP startup")
        check(ClaudeCLI.environment(for: source)["MCP_CONNECT_TIMEOUT_MS"] == "30000", "MCP startup wait has a finite deadline")
        source.mcpReadConnectors = []; source.mcpAttachServer = "slack"
        check(ClaudeCLI.environment(for: source)["ENABLE_TOOL_SEARCH"] == "false", "Slack inventory receives complete schemas")
        check(ClaudeCLI.environment(for: .init(prompt: "Fixture"))["ENABLE_TOOL_SEARCH"] == nil, "unrelated Claude invocations retain their environment")
        check(ClaudeCLI.environment(for: .init(prompt: "Fixture"))["MCP_CONNECTION_NONBLOCKING"] == nil, "unrelated runs retain startup behavior")
        source.mcpAttachServer = nil; source.mcpActionServer = "google-drive"
        check(ClaudeCLI.environment(for: source)["MCP_CONNECTION_NONBLOCKING"] == "0", "generic connector actions wait for their server")
        Log("Slack action checks: \(checks) checks, \(failures) failures")
        return failures
    }
}
#endif
