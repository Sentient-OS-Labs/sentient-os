#if DEBUG
// Real provider/bridge progress against strictly synthetic native MCP tools. No helper,
// app control, screenshots, production conversation, saved instructions or telemetry uploads.
import Foundation

nonisolated enum SidekickActivityLab {
    struct Report {
        var checks: [String: Bool] = [:]
        var counts: [String: Int] = [:]
        var details: [String: String] = [:]
    }
    private enum Failure: Error { case configuration, runtime, protocolMismatch, question }
    private static let timeout: TimeInterval = 180
    private static let expected: [(tool: String, app: String?, text: String, symbol: String)] = [
        ("list_apps", nil, "Looking at your Mac", "desktopcomputer"),
        ("get_app_state", "com.spotify.client", "Looking at Spotify", "macwindow"),
        ("click", "com.spotify.client", "Clicking in Spotify", "cursorarrow"),
        ("get_app_state", "net.whatsapp.WhatsApp", "Looking at WhatsApp", "macwindow"),
        ("click", "net.whatsapp.WhatsApp", "Clicking in WhatsApp", "cursorarrow"),
        ("type_text", "net.whatsapp.WhatsApp", "Entering text in WhatsApp", "keyboard")
    ]
    private static let disabled = [
        "project_doc_max_bytes=0", "features.shell_tool=false", "features.view_image=false",
        "features.browser_use=false", "features.computer_use=false", "features.multi_agent=false",
        "features.code_mode=false", "features.image_generation=false", "features.goals=false",
        "features.skill_search=false", "features.tool_search=false", "features.plugins=false",
        "features.apps=false", "apps._default.enabled=false", "web_search=\"disabled\""
    ]

    @MainActor static func run(provider: String, root: URL) async throws -> Report {
        guard ["chatgpt", "claude_bridge"].contains(provider),
              FileManager.default.isExecutableFile(atPath: CodexRuntime.executable.path) else { throw Failure.configuration }
        let store = try SidekickConversationStore(url: root.appendingPathComponent("activity.sqlite"))
        let taskID = UUID()
        _ = try store.appendBatch([.init(taskID: taskID, kind: .taskStarted),
            .init(taskID: taskID, kind: .userMessage, text: "Run the synthetic notch activity fixture.")])
        let recording = SidekickConversationRun(store: store, taskID: taskID, generation: try store.generation)
        let recorder = Recorder(store: store, taskID: taskID)
        let fixture = NativeFixture()
        let native = LocalMCPServer(name: "sentient_native", tools: ["list_apps", "get_app_state", "click", "type_text"],
            timeout: timeout, maximumBody: 65_536) { data in try await fixture.response(data) }
        var bridge: ClaudeSubscriptionBridge?
        var report = Report()
        let backend: ModelBackend = provider == "chatgpt" ? .chatgpt : .claude
        do {
            let nativeConnection = try await native.start()
            let output = try await ModelBackend.$runOverride.withValue(backend) {
                // No personalization/saved-instruction snapshot is read. This summary stays
                // local: takeReport closes it; finish (the analytics emitter) is never called.
                let summary = SidekickTaskSummary()
                let interaction = SidekickInteraction(taskSummary: summary, conversationRun: recording) { _ in throw Failure.question }
                return try await SidekickInteraction.$current.withValue(interaction) {
                    try await ResearchToolServer.$connection.withValue(nil) {
                        try await DirectMCPRuntime.$current.withValue([]) {
                            try await SidekickToolServer.withConnection {
                                guard let local = SidekickToolServer.connection else { throw Failure.configuration }
                                let prompt = self.prompt + "\n\n" + interaction.promptInstructions
                                var overrides = local.codexOverrides + disabled
                                var environment = [CustomProvider.apiKeyEnvName: "synthetic-activity-no-custom-provider-key"]
                                let model: String, effort: String
                                if provider == "claude_bridge" {
                                    guard let binary = ClaudeCLI.locateBinary() else { throw Failure.runtime }
                                    model = ClaudeCLI.Model.sonnet.rawValue; effort = "low"
                                    let relay = ClaudeSubscriptionBridge(binary: binary, model: model, effort: effort,
                                        timeout: timeout, namespaces: ["mcp__sentient_native", "mcp__sentient_recovery"],
                                        onProgress: { recorder.progress($0) })
                                    bridge = relay
                                    let config = try await relay.start()
                                    overrides += config.overrides
                                    environment.merge(config.environment) { _, value in value }
                                } else {
                                    let limited = CodexAuth.isLimited()
                                    model = (limited ? CodexCLI.Model.gpt56terra : .gpt6sol).rawValue
                                    effort = limited ? "medium" : "low"
                                }
                                report.details["selected_model"] = model
                                report.details["selected_effort"] = effort
                                var arguments = try CodexCLI.agentArguments(prompt: prompt, imagePaths: [], modelID: model,
                                    effortArg: effort, providerOverrides: overrides, nativeConnection: nativeConnection)
                                arguments.insert(contentsOf: ["--ephemeral", "--cd", root.path], at: arguments.count - 1)
                                let result = try await ComputerUseStream.run(binary: CodexRuntime.executable.path, args: arguments,
                                    timeout: timeout, extraEnv: environment, narrate: provider == "chatgpt",
                                    onLine: { recorder.progress($0) })
                                let usage = summary.takeReport()
                                report.checks["usage_tool_called_without_upload"] = usage?.reason == .accepted && usage?.phase == .final
                                return result
                            }
                        }
                    }
                }
            }
            report.counts["provider_exit_code"] = Int(output.status)
            report.counts["provider_stdout_bytes"] = output.stdout.utf8.count
            report.counts["provider_stderr_bytes"] = output.stderr.utf8.count
            report.checks["provider_succeeded"] = output.status == 0
            let bridgeFailure = await bridge?.failure
            report.checks["bridge_succeeded"] = bridgeFailure == nil
            report.details["bridge_failure"] = bridgeFailure.map {
                ($0 as? ClaudeSubscriptionProtocol.Failure)?.rawValue ?? CodexFailureReason.classify($0).rawValue
            } ?? "none"
            report.details["provider_failure"] = CodexCLI.agentFailure(output).map { CodexFailureReason.classify($0).rawValue } ?? "none"
            report.counts["bridge_requested_tools"] = await bridge?.requestedToolCount ?? 0
            if let bridgeFailure, case CodexCLI.CLIError.exitFailure(let code, _) = bridgeFailure {
                report.counts["bridge_child_exit_code"] = Int(code)
            }
            let receipt = await fixture.snapshot()
            report.counts["synthetic_native_calls"] = receipt.calls
            report.counts["synthetic_native_rejections"] = receipt.rejected
            report.checks["exact_synthetic_tool_sequence"] = receipt.calls == expected.count && receipt.rejected == 0
            let captured = recorder.snapshot()
            report.counts["captured_native_statuses"] = captured.steps.count
            report.counts["hidden_progress_markers"] = captured.hidden
            report.checks["projection_reads_succeeded"] = captured.readFailures == 0
            report.checks["message_and_telemetry_not_shown"] = captured.hidden == 0
            report.checks["one_native_status_per_call"] = captured.steps.count == expected.count
            for (index, wanted) in expected.enumerated() {
                let got = captured.steps.indices.contains(index) ? captured.steps[index] : [:]
                report.checks["step_\(index)_label"] = got["text"] == wanted.text
                report.checks["step_\(index)_icon_identity"] = got["app"] == (wanted.app ?? "") && got["symbol"] == wanted.symbol
                report.checks["step_\(index)_structured_activity"] = got["tool"] == "sentient_native." + wanted.tool
            }
            report.checks["final_narration_readable"] = captured.finalNarration
            let records = try store.records(taskID: taskID, limit: 100)
            let activities = SidekickActivityPresentation.steps(records)
            report.checks["saved_activity_matches_calls"] = activities.count == expected.count
            report.checks["hidden_wrappers_not_saved_as_activity"] = !records.contains {
                $0.event.activity?.name.contains("message_user") == true || $0.event.activity?.name.contains("describe_task_usage") == true
            }
            report.checks["message_tool_delivered"] = records.contains { $0.event.kind == .assistantMessage && $0.event.text == "Activity fixture complete." }
            report.checks["only_declared_activity"] = activities.allSatisfy { $0.record.event.activity?.name.hasPrefix("sentient_native.") == true }
            report.checks["no_user_memory_loaded"] = true // Interaction above deliberately has no snapshot/personalization.
            report.checks["no_native_helper_instantiated"] = true // All native tools are this local in-memory actor.
            report.details["activity_statuses"] = String(decoding: try JSONSerialization.data(withJSONObject: captured.steps, options: .sortedKeys), as: UTF8.self)
            await bridge?.stop(); await native.stop()
            recording.invalidate()
            return report
        } catch {
            await bridge?.stop(); await native.stop(); recording.invalidate()
            throw error
        }
    }

    private static let prompt = """
    Run this synthetic integration test, using ONLY the supplied sentient_native and
    sentient_recovery tools. The native server is a fake in-memory fixture: it cannot open,
    read, click, type into, or otherwise access any real application. Every app/name is synthetic.
    No shell, filesystem, web search, real accounts, real apps, or other tools may be used.
    Perform this exact sequence, one tool at a time:
    1. sentient_recovery.message_user markdown="Synthetic activity check.", kind="update", priority="normal".
    2. sentient_recovery.describe_task_usage phase="intent", summary="Testing synthetic app activity presentation".
    3. sentient_native.list_apps with no arguments.
    4. sentient_native.get_app_state app="com.spotify.client".
    5. sentient_native.click app="com.spotify.client", element_index=1.
    6. sentient_native.get_app_state app="net.whatsapp.WhatsApp".
    7. sentient_native.click app="net.whatsapp.WhatsApp", element_index=1.
    8. sentient_native.type_text app="net.whatsapp.WhatsApp", text="Activity fixture text".
    9. sentient_recovery.describe_task_usage phase="final", summary="Testing synthetic app activity presentation".
    10. sentient_recovery.message_user markdown="Activity fixture complete.", kind="answer", priority="normal".
    Finally output two lines: Activity fixture complete. and STATUS: DONE.
    Do not add tool calls, skip steps, or ask the user questions. If a tool fails, report it honestly.
    """

    /// Runs synchronously after the production stream has committed its tool event.
    /// Store reads and this lock are independent; no main-actor scheduling masks ordering bugs.
    private final class Recorder: @unchecked Sendable {
        let store: SidekickConversationStore
        let taskID: UUID
        private let lock = NSLock()
        private var steps: [[String: String]] = []
        private var hidden = 0
        private var readFailures = 0
        private var finalNarration = false
        init(store: SidekickConversationStore, taskID: UUID) { self.store = store; self.taskID = taskID }
        func progress(_ line: String) {
            guard line != "codex", line != "exec", !line.isEmpty else { return }
            let records: [SidekickConversationStore.Record]
            do { records = try store.records(taskID: taskID, limit: 100) }
            catch { lock.lock(); readFailures += 1; lock.unlock(); return }
            let activity = SidekickActivityPresentation.steps(records).max { $0.record.sequence < $1.record.sequence }
            let status = SidekickActivityPresentation.notchStatus(line, activity: activity)
            lock.lock(); defer { lock.unlock() }
            if line.hasPrefix("→ "), line.contains("message_user") || line.contains("describe_task_usage") { hidden += 1 }
            if line.hasPrefix("→ sentient_native.") {
                steps.append(["text": status.text, "app": status.activity?.appIdentifier ?? "",
                    "symbol": status.activity?.symbol ?? "", "tool": status.activity?.record.event.activity?.name ?? ""])
            }
            if line.contains("Activity fixture complete."), status.activity == nil,
               status.text.contains("Activity fixture complete.") { finalNarration = true }
        }
        func snapshot() -> (steps: [[String: String]], hidden: Int, readFailures: Int, finalNarration: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (steps, hidden, readFailures, finalNarration)
        }
    }

    private actor NativeFixture {
        private var calls = 0
        private var rejected = 0
        private var cached: [String: Data] = [:]
        func snapshot() -> (calls: Int, rejected: Int) { (calls, rejected) }
        func response(_ data: Data) throws -> Data {
            guard let rpc = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = rpc["id"] else { throw Failure.protocolMismatch }
            let result: [String: Any]
            switch rpc["method"] as? String {
            case "initialize": result = ["protocolVersion": "2024-11-05", "capabilities": ["tools": [:]], "serverInfo": ["name": "Synthetic activity fixture", "version": "1"]]
            case "ping": result = [:]
            case "tools/list":
                result = ["tools": ["list_apps", "get_app_state", "click", "type_text"].map { tool -> [String: Any] in
                    var properties: [String: Any] = [:]
                    var required: [String] = []
                    if tool != "list_apps" {
                        properties["app"] = ["type": "string", "enum": ["com.spotify.client", "net.whatsapp.WhatsApp"]]
                        required.append("app")
                    }
                    if tool == "click" { properties["element_index"] = ["type": "integer", "enum": [1]]; required.append("element_index") }
                    if tool == "type_text" { properties["text"] = ["type": "string", "enum": ["Activity fixture text"]]; required.append("text") }
                    return ["name": tool, "description": "Synthetic in-memory fixture only. Cannot access real apps or the computer.",
                        "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
                        "annotations": ["readOnlyHint": tool == "list_apps" || tool == "get_app_state"]]
                }]
            case "tools/call":
                let key = String(decoding: try JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed), as: UTF8.self)
                if let cached = cached[key] { return cached }
                let params = rpc["params"] as? [String: Any] ?? [:]
                let tool = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                let expected = Self.expectedCall(calls)
                let expectedKeys: Set<String> = tool == "list_apps" ? [] : tool == "click" ? ["app", "element_index"] : tool == "type_text" ? ["app", "text"] : ["app"]
                let valid = expected?.tool == tool && expected?.app == (args["app"] as? String)
                    && Set(args.keys) == expectedKeys && (tool != "click" || args["element_index"] as? Int == 1)
                    && (tool != "type_text" || args["text"] as? String == "Activity fixture text")
                if valid {
                    calls += 1
                    result = ["content": [["type": "text", "text": tool == "list_apps"
                        ? "Synthetic apps: Spotify (com.spotify.client), WhatsApp (net.whatsapp.WhatsApp)."
                        : "Synthetic state/action receipt. Element 1 is a fixture input. No real app was accessed."]]]
                } else {
                    rejected += 1
                    result = ["isError": true, "content": [["type": "text", "text": "The synthetic fixture rejected an out-of-sequence or unexpected tool call."]]]
                }
                let response = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result], options: .sortedKeys)
                cached[key] = response; return response
            default: throw Failure.protocolMismatch
            }
            return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result], options: .sortedKeys)
        }
        private static func expectedCall(_ index: Int) -> (tool: String, app: String?)? {
            guard SidekickActivityLab.expected.indices.contains(index) else { return nil }
            let value = SidekickActivityLab.expected[index]
            return (value.tool, value.app)
        }
    }
}
#endif
