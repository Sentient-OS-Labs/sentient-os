#if DEBUG
//
//  ConnectorReadPolicyTests.swift
//  Pure connector policy and denial-verification regression checks. `run()` exercises the
//  production argument builders with volatile fixtures, without model or connector calls.
//  Doc: Documentation - General - Self-Testing (Eval Harness).md
//

import Foundation

enum ConnectorReadPolicyTests {
    static func run() {
        ModelBackend.$runOverride.withValue(nil) { runChecks() }
    }

    private static func runChecks() {
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let driveID = "connector_5f3c8c41a1e54ad7a76272c89e2554fa"
        let otherID = "connector_00000000000000000000000000000001"
        let slackID = "asdk_app_00000000000000000000000000000002"
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            Log("\(condition ? "PASS" : "FAIL")  \(message)")
            if !condition { failures += 1 }
        }
        func install(_ id: String? = nil, backend: ModelBackend = .chatgpt) {
            var domain = saved
            domain["model.backend"] = backend.rawValue
            let connectors: [ConnectorCensus.DetectedConnector] = id.map {
                [.init(slug: "google-drive", displayName: "Google Drive", origin: .chatgpt,
                       serverURL: nil, catalogID: $0, iconPath: nil, healthy: true, lastSeen: Date()),
                 .init(slug: "unrelated", displayName: "Unrelated", origin: .chatgpt,
                       serverURL: nil, catalogID: otherID, iconPath: nil, healthy: true, lastSeen: Date()),
                 .init(slug: "slack", displayName: "Slack", origin: .chatgpt,
                       serverURL: nil, catalogID: slackID, iconPath: nil, healthy: true, lastSeen: Date())]
            } ?? []
            domain["mcp.connectors.chatgpt"] = try! JSONEncoder().encode(connectors)
            domain["mcp.connectors.claude"] = try! JSONEncoder().encode([
                ConnectorCensus.DetectedConnector(slug: "slack", displayName: "Slack", origin: .claude,
                    serverURL: "https://mcp.slack.com/mcp", catalogID: nil, iconPath: nil, healthy: true, lastSeen: Date())])
            let slackTools = SlackConnector.categories(backend: .claude).map {
                ConnectorRegistry.ClassifiedTool(name: SlackConnector.claudePrefix + $0.key, category: $0.value)
            }
            domain[ConnectorRegistry.classificationKey("slack")] = try! JSONEncoder().encode(
                ConnectorRegistry.Classification(tools: slackTools,
                    cliVersion: ConnectorClassifier.currentCLIVersion ?? "fixture", capturedAt: Date(),
                    verifiedInventory: slackTools.map(\.name)))
            defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        }
        func invocation(_ slugs: [String]) -> CodexCLI.Invocation {
            var inv = CodexCLI.Invocation(prompt: "Synthetic policy check")
            inv.mcpReadConnectors = slugs
            return inv
        }
        func args(_ inv: CodexCLI.Invocation) throws -> [String] {
            try CodexCLI.arguments(for: inv, modelID: "gpt-6-luna", effortArg: "medium", schemaFile: nil)
        }
        func refuses(_ inv: CodexCLI.Invocation) -> Bool {
            do { _ = try args(inv); return false } catch { return true }
        }
        func policy(_ args: [String]) -> String { args.last { $0.hasPrefix("apps = ") } ?? "" }

        install()
        check(refuses(invocation(["google-drive"])), "missing catalog identity refuses the read")
        install("connector_bad.id")
        check(refuses(invocation(["google-drive"])), "malformed catalog identity refuses the read")
        install(driveID + "\n")
        check(refuses(invocation(["google-drive"])), "catalog identity must match completely")
        install(driveID)
        check(refuses(invocation(["notion"])), "uncurated connector cannot borrow a read policy")
        check(refuses(invocation(["unknown"])), "unknown connector refuses the read")
        var bypass = invocation(["google-drive"]); bypass.bypassApprovals = true
        check(refuses(bypass), "read plus bypass is refused in production, before assertions")
        var writable = invocation(["google-drive"]); writable.sandbox = .workspaceWrite
        check(refuses(writable), "read plus writable sandbox is refused")
        var mixed = invocation(["google-drive"]); mixed.mcpActionServer = "google-drive"
        check(refuses(mixed), "mixed read/action recipe is refused")

        do {
            let drive = try args(invocation(["google-drive"]))
            let gmail = try args(invocation(["gmail"]))
            let calendar = try args(invocation(["google-calendar"]))
            let research = try args(invocation(["gmail", "google-calendar", "google-drive"]))
            let sourceInvocation = MCPSource.readInvocation(slug: "google-drive", prompt: "Synthetic source check")
            let source = try args(sourceInvocation)
            check(source.contains("project_doc_max_bytes=0") && source.contains("features.shell_tool=false")
                  && source.contains("web_search=\"disabled\""), "source ingestion excludes project instructions, shell and web")
            check(!research.contains("features.shell_tool=false"), "research retains its local vault tools")
            let claudeSourceInvocation = ModelBackend.$runOverride.withValue(.claude) {
                MCPSource.readInvocation(slug: "google-drive", prompt: "Synthetic source check")
            }
            let sourceClaude = try ClaudeCLI.arguments(for: claudeSourceInvocation, modelID: "haiku", effortArg: "medium")
            let toolIndex = sourceClaude.firstIndex(of: "--tools")!
            let builtins = Set(sourceClaude[toolIndex + 1].split(separator: ",").map(String.init))
            check(builtins.isSubset(of: ["WaitForMcpServers"]), "Claude source ingestion permits readiness waiting but no filesystem builtins")
            var identity = sourceInvocation; identity.mcpReadToolNames = ["get_profile"]
            let identityArgs = try args(identity)
            check(policy(identityArgs).contains("get_profile") && !policy(identityArgs).contains("\"search\""), "identity read exposes only the verified profile tool")
            identity.mcpReadToolNames = ["create_file"]
            check(refuses(identity), "read-tool subset cannot enable a write")
            identity.mcpReadToolNames = []
            check(refuses(identity), "empty read-tool subset refuses the run")
            check(drive.contains("--ignore-user-config"), "read ignores inherited MCP servers and approvals")
            check(policy(drive).contains("_default = { enabled = false }"), "unrequested and unidentified apps default off")
            check(policy(drive).contains("default_tools_enabled = false"), "new tools default off")
            check(!policy(drive).contains("create_file") && !policy(drive).contains("share_file"), "writes are absent from the allowlist")
            check(!policy(drive).contains(otherID), "unrelated cached connector has no enabled entry")
            check(!policy(gmail).contains(driveID), "Drive is unavailable during a Gmail-only read")
            check(policy(drive).contains("approval_mode = \"writes\""), "allowed tools still require read-only metadata")
            check(try args(invocation(["google-drive", "google-drive"])) == drive, "duplicate slugs cannot widen the policy")
            check(try args(invocation(["google-drive", "gmail", "google-calendar"])) == research, "research attachment order is stable")

            var resumed = invocation(["google-drive"]); resumed.resumeSessionID = "fixture"
            let resumeArgs = try args(resumed)
            check(policy(resumeArgs) == policy(drive) && resumeArgs.contains("sandbox_mode=\"read-only\""), "resumed reads retain policy and sandbox")
            var inherited = invocation(["google-drive"])
            inherited.configOverrides = ["apps={_default={enabled=true,default_tools_approval_mode=\"approve\"},"
                + "\(driveID)={enabled=true,tools={create_file={enabled=true,approval_mode=\"approve\"}},"
                + "links={fixture={default_tools_approval_mode=\"approve\"}}}}"]
            let inheritedArgs = try args(inherited)
            check(policy(inheritedArgs) == policy(drive)
                  && inheritedArgs.firstIndex(of: inherited.configOverrides[0])! < inheritedArgs.firstIndex(of: policy(drive))!,
                  "complete read policy follows caller overrides")

            var fired = invocation([]); fired.mcpActionServer = "google-drive"
            let action = try args(fired)
            check(policy(action).isEmpty && action.contains("apps.\(driveID).default_tools_approval_mode=\"approve\""), "user-fired action retains its separate approval")
            check(!action.contains("--ignore-user-config"), "action configuration remains unchanged")
            let plain = try args(invocation([]))
            check(policy(plain).isEmpty && !plain.contains("--ignore-user-config"), "non-connector recipe remains unchanged")

            let claude = try ClaudeCLI.arguments(for: invocation(["google-drive"]), modelID: "sonnet", effortArg: "medium")
            check(claude.contains("dontAsk") && claude.joined(separator: " ").contains("mcp__claude_ai_Google_Drive__search_files"),
                  "Claude retains its existing curated reads")
            check(!claude.joined(separator: " ").contains("mcp__claude_ai_Google_Drive__create_file"), "Claude still omits create_file")

            if let path = ProcessInfo.processInfo.environment["LAB_POLICY_OUTPUT"] {
                var slackAction = invocation([]); slackAction.mcpActionServer = "slack"; slackAction.slackOperation = .send
                var slackDraft = slackAction; slackDraft.slackOperation = .draft
                var slackRead = slackAction; slackRead.slackOperation = .read
                var slackApproved = slackAction; slackApproved.slackExpectedMessage = "Approved fixture"
                let slackSource = MCPSource.readInvocation(slug: "slack", prompt: "Synthetic source check")
                var fixture = ["drive": drive, "gmail": gmail, "calendar": calendar,
                               "research": research, "action": action, "inherited": inheritedArgs,
                               "source": source, "identity": identityArgs,
                               "slack-source": try args(slackSource), "slack-action": try args(slackAction),
                               "slack-draft": try args(slackDraft), "slack-task-read": try args(slackRead),
                               "slack-approved": try args(slackApproved)]
                for (key, invocation) in [("slack-source", slackSource), ("slack-action", slackAction),
                                          ("slack-draft", slackDraft), ("slack-task-read", slackRead), ("slack-approved", slackApproved)] {
                    fixture["claude-" + key] = try ModelBackend.$runOverride.withValue(.claude) {
                        try ClaudeCLI.arguments(for: invocation, modelID: "haiku", effortArg: "low")
                    }
                }
                fixture["claude-slack-computer"] = try ModelBackend.$runOverride.withValue(.claude) {
                    try ClaudeCLI.agentArguments(prompt: "Synthetic fixture", modelID: "haiku", effortArg: "low", socketPath: "/tmp/fixture.sock")
                }
                // Exercise the production action and computer-use deny recipes for the new
                // reviewed mutation modes, using volatile synthetic inventories only.
                for (slug, name, endpoint, read, write) in [
                    ("asana", "Asana", "https://mcp.asana.com/v2/mcp", "get_me", "create_tasks"),
                    ("linear", "Linear", "https://mcp.linear.app/mcp", "get_workspace", "create_issue_label") ] {
                    let prefix = "mcp__claude_ai_" + name + "__"
                    let destructive = ConnectorClassifier.reviewedDestructiveTools(slug: slug)
                    let tools = destructive.sorted().map { ConnectorRegistry.ClassifiedTool(name: prefix + $0, category: .destructive) }
                        + [.init(name: prefix + read, category: .read), .init(name: prefix + write, category: .write)]
                    var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
                    domain["mcp.connectors.claude"] = try JSONEncoder().encode([
                        ConnectorCensus.DetectedConnector(slug: slug, displayName: name, origin: .claude,
                            serverURL: endpoint, catalogID: nil, iconPath: nil, healthy: true, lastSeen: Date())])
                    domain[ConnectorRegistry.classificationKey(slug)] = try JSONEncoder().encode(
                        ConnectorRegistry.Classification(tools: tools, cliVersion: ConnectorClassifier.currentCLIVersion ?? "fixture",
                            capturedAt: Date(), verifiedInventory: tools.map(\.name)))
                    defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
                    var action = CodexCLI.Invocation(prompt: "Synthetic mutation policy check")
                    action.mcpActionServer = slug
                    fixture["claude-" + slug + "-action"] = try ModelBackend.$runOverride.withValue(.claude) {
                        try ClaudeCLI.arguments(for: action, modelID: "haiku", effortArg: "low")
                    }
                    fixture["claude-" + slug + "-computer"] = try ModelBackend.$runOverride.withValue(.claude) {
                        try ClaudeCLI.agentArguments(prompt: "Synthetic fixture", modelID: "haiku", effortArg: "low", socketPath: "/tmp/fixture.sock")
                    }
                    for mode in ["action", "computer"] {
                        let args = fixture["claude-" + slug + "-" + mode]!
                        let index = args.firstIndex(of: "--disallowedTools")!
                        let denied = Set(args[index + 1].split(separator: ",").map(String.init))
                        check(Set(destructive.map { prefix + $0 }).isSubset(of: denied), "\(slug) \(mode) removes every reviewed destructive mode")
                    }
                }
                try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: path))
            }
            install(driveID, backend: .custom)
            check(policy(try args(invocation(["google-drive"]))).isEmpty, "hosted policy remains inert on custom providers")
        } catch {
            check(false, "unexpected argument-builder failure: \(ErrorLabel(error))")
        }

        func snapshot(_ name: String = "expected", exists: Bool = false, failure: String = "") -> ConnectorLab.DriveSnapshot {
            .init(artifact_name: name, exists: exists, file_ids: exists ? ["fixture-id"] : [], tool_failure: failure)
        }
        func envelope(_ raw: String, result: String = "NO") -> CodexCLI.Envelope {
            .init(result: result, sessionID: nil, numTurns: nil, durationMS: nil,
                  inputTokens: nil, cachedInputTokens: nil, outputTokens: nil, raw: raw)
        }
        let denied = envelope(#"{"type":"item.completed","item":{"type":"mcp_tool_call","tool":"gdrive.create_file","error":{"message":"user cancelled MCP tool call"}}}"#)
        let mimeError = envelope(#"{"type":"item.completed","item":{"type":"mcp_tool_call","tool":"gdrive.create_file","error":{"message":"unsupported MIME type text/plain"}}}"#)
        let prose = envelope(#"{"type":"item.completed","item":{"type":"agent_message","text":"permission denied create_file"}}"#)
        let good = snapshot()
        check(ConnectorLab.denycheckVerdict(before: good, after: good, attempt: denied).hasPrefix("PASS"), "exact absence plus runtime denial passes")
        check(ConnectorLab.denycheckVerdict(before: good, after: snapshot(exists: true), attempt: nil).hasPrefix("FAIL"), "created artifact fails even if the attempt errored")
        check(ConnectorLab.denycheckVerdict(before: good, after: snapshot("wrong-name"), attempt: denied).hasPrefix("INCONCLUSIVE"), "wrong verification filename never passes")
        check(ConnectorLab.denycheckVerdict(before: good, after: good, attempt: mimeError).hasPrefix("INCONCLUSIVE"), "unsupported MIME type is not permission evidence")
        check(ConnectorLab.denycheckVerdict(before: good, after: good, attempt: prose).hasPrefix("INCONCLUSIVE"), "model refusal text is not permission evidence")
        check(ConnectorLab.denycheckVerdict(before: good, after: snapshot(failure: "auth"), attempt: denied).hasPrefix("INCONCLUSIVE"), "failed account search never passes")
        check(ConnectorLab.denycheckVerdict(before: snapshot(exists: true), after: good, attempt: denied).hasPrefix("INCONCLUSIVE"), "preexisting artifact invalidates the test")
        check(ConnectorLab.hasCreateDenial(raw: #"{"type":"result","permission_denials":[{"tool_name":"mcp__claude_ai_Google_Drive__create_file"}]}"#), "Claude runtime denial is recognized")
        check(ConnectorLab.hasCreateDenial(raw: #"{"type":"item.completed","item":{"type":"mcp_tool_call","tool":"gdrive.create_file","error":{"message":"MCP tool call requires approval, but approval policy is never"}}}"#), "current Codex runtime denial is recognized")
        check(!ConnectorLab.hasSuccessfulDriveSearch(raw: prose.raw, artifact: "expected"), "search must execute; model claims do not count")
        let search = #"{"type":"item.completed","item":{"type":"mcp_tool_call","tool":"gdrive.search","arguments":{"query":"expected"},"status":"completed","error":null,"result":{"content":[],"isError":false}}}"#
        check(ConnectorLab.hasSuccessfulDriveSearch(raw: search, artifact: "expected"), "successful Codex search is recognized")
        check(!ConnectorLab.hasSuccessfulDriveSearch(raw: search, artifact: "different"), "actual search must name the attempted artifact")
        check(!ConnectorLab.hasSuccessfulDriveSearch(raw: search.replacingOccurrences(of: "\"isError\":false", with: "\"isError\":true"), artifact: "expected"), "failed search is not absence evidence")
        Log("Connector policy checks: \(failures) failures")
        if failures > 0 { exit(1) }
    }
}

#endif
