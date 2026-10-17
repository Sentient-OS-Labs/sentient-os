#if DEBUG
// Signed-app integration lab, entered before diagnostics, AppState, or normal startup.
// Real providers receive a fixed synthetic task and only app-owned fixture MCP capabilities.
// Existing canonical provider authentication is used in place, never copied or printed.
// SENTIENT_SELFTEST=sidekickbackend LAB_SIDEKICK_PROVIDER=chatgpt|claude|claude_bridge|codex_fixture
// LAB_SIDEKICK_COMMAND=process_fixture runs only the local owned-child failure fixture.
// LAB_SIDEKICK_COMMAND=compaction uses the real default compactor on synthetic saved history.

import Darwin
import Foundation
import Network

nonisolated enum SidekickBackendLab {
    private enum Provider: String { case chatgpt, claude, claude_bridge, codex_fixture }
    private enum Failure: String, Error {
        case invalidConfiguration, unavailableRuntime, protocolMismatch, processFailed
        case unconfirmedStatus, wrongQuestion, verificationFailed, cleanupFailed
    }
    private static let memoryText = "- Fixture preference: concise updates.\n"
    private static let historyID = "sidekick-lab-seed-answer"
    private static let timeout: TimeInterval = 180

    @MainActor private final class Checks {
        var values: [String: Bool] = [:]
        var counts: [String: Int] = [:]
        var details: [String: String] = [:]
        func require(_ name: String, _ value: Bool) { values[name] = value }
        var passed: Bool { !values.isEmpty && values.values.allSatisfy { $0 } }
    }

    @MainActor static func run() async -> Int32 {
        let env = ProcessInfo.processInfo.environment
        let command = env["LAB_SIDEKICK_COMMAND"] ?? "provider"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentient-sidekick-backend-lab-" + UUID().uuidString, isDirectory: true)
        let checks = Checks()
        var result: [String: Any] = ["lab": "sidekick_backend", "command": command]
        var status: Int32 = 1
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            if command == "process_fixture" {
                try await processFixture(root, checks: checks)
            } else if command == "parser_fixture" {
                try parserFixture(checks: checks)
            } else if command == "compaction" {
                guard let selected = env["LAB_SIDEKICK_PROVIDER"], let provider = Provider(rawValue: selected),
                      [.chatgpt, .claude].contains(provider) else { throw Failure.invalidConfiguration }
                result["provider"] = provider.rawValue
                try await compactionFixture(provider, root: root, checks: checks)
            } else {
                guard command == "provider", let selected = env["LAB_SIDEKICK_PROVIDER"],
                      let provider = Provider(rawValue: selected) else { throw Failure.invalidConfiguration }
                result["provider"] = provider.rawValue
                try await providerFixture(provider, root: root, checks: checks)
            }
            status = checks.passed ? 0 : 1
        } catch {
            // Never print raw provider/transport errors, prompts, arguments, keys, or transcripts.
            result["failure"] = (error as? Failure)?.rawValue ?? "execution_failed"
            result["reason"] = AgentRunDiagnostics.Reason.classify(error.localizedDescription).rawValue
            result["provider_reason"] = CodexFailureReason.classify(error).rawValue
        }
        do { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
        catch { result["cleanup_failed"] = true; status = 1 }
        result["checks"] = checks.values
        result["counts"] = checks.counts
        result["details"] = checks.details
        result["passed"] = status == 0
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([0x0A]))
        }
        return status
    }

    @MainActor private static func compactionFixture(_ provider: Provider, root: URL, checks: Checks) async throws {
        let store = try SidekickConversationStore(url: root.appendingPathComponent("compaction.sqlite"))
        let suite = "ai.sentient.compaction-lab." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.invalidConfiguration }
        defer { defaults.removePersistentDomain(forName: suite) }
        let memoryURL = root.appendingPathComponent("SidekickMemory.md")
        let originalMemory = "- Fixture memory must stay unchanged.\n"
        let memorySnapshot = try SidekickInstructionStore.write(originalMemory, defaults: defaults, memoryURL: memoryURL)
        for index in 0..<18 {
            let taskID = UUID()
            let request: String, answer: String
            switch index {
            case 0:
                request = "Choose blue for the synthetic Quartz launch."
                answer = "Chose blue. Synthetic plan saved at fixture://quartz-plan."
            case 1:
                request = "Draft a synthetic launch note."
                answer = "Draft prepared at fixture://quartz-draft. Nothing was sent."
            case 2:
                request = "Send the synthetic launch note."
                answer = "A send was attempted, but delivery was not confirmed. The user stopped the task."
            default:
                request = "Synthetic recent task \(index)."
                answer = "TAIL_ONLY_SENTINEL_\(index): completed synthetic recent task."
            }
            var events: [SidekickConversationEvent] = [
                .init(id: "fixture-u-\(index)", taskID: taskID, kind: .userMessage, text: request),
                .init(id: "fixture-a-\(index)", taskID: taskID, kind: .assistantMessage, text: answer)
            ]
            if index == 2 {
                events.append(.init(id: "fixture-checkpoint-2", taskID: taskID, kind: .checkpoint,
                    text: "Send outcome remains unknown. Verify current state before attempting to send again."))
            }
            events.append(.init(id: "fixture-end-\(index)", taskID: taskID, kind: .taskFinished,
                text: index == 2 ? "Stopped by user" : "Synthetic task completed", outcome: index == 2 ? .stopped : .success))
            _ = try store.appendBatch(events)
        }
        let generation = try store.generation
        let original = try store.records(limit: 500)
        guard let boundary = try store.compactionBoundary(keepingRecentTasks: 15) else { throw Failure.invalidConfiguration }
        let expectedTail = original.filter { $0.sequence > boundary }
        let trapRun = SidekickConversationRun(store: store, taskID: UUID(), generation: generation)
        let memory = SidekickPersonalization(snapshot: memorySnapshot, taskID: trapRun.taskID,
            request: "Synthetic capability isolation trap", defaults: defaults, memoryURL: memoryURL, onChange: { _ in })
        defer { memory.finish(success: false) }
        let trap = SidekickInteraction(instructionsSnapshot: memorySnapshot, personalization: memory, conversationRun: trapRun) { _ in
            checks.counts["unexpected_compactor_questions", default: 0] += 1
            throw Failure.wrongQuestion
        }
        checks.details["evidence"] = "real_provider_default_compactor_synthetic_history"
        let backend: ModelBackend = provider == .chatgpt ? .chatgpt : .claude
        let began = ProcessInfo.processInfo.systemUptime
        try await ModelBackend.$runOverride.withValue(backend) {
            try await SidekickInteraction.$current.withValue(trap) {
                try await SidekickToolServer.withConnection {
                    // No injected summarizer: exercises the actual detached worker, FrontierRun,
                    // provider recipe, schema result parser, and transactional summary installation.
                    checks.counts["execution_started_unix_ms"] = Int(Date().timeIntervalSince1970 * 1000)
                    try await SidekickCompactor.compactIfNeeded(store: store)
                    checks.counts["execution_finished_unix_ms"] = Int(Date().timeIntervalSince1970 * 1000)
                }
            }
        }
        checks.counts["compaction_elapsed_ms"] = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
        guard let summary = try store.summary else { throw Failure.verificationFailed }
        checks.counts["summary_bytes"] = summary.text.utf8.count
        checks.counts["source_through_sequence"] = Int(summary.throughSequence)
        checks.counts["retained_tail_events"] = expectedTail.count
        checks.require("compaction_installed", try store.summaries().count == 1)
        checks.require("compaction_source_boundary", summary.fromSequence == 1 && summary.throughSequence == boundary)
        let currentGeneration = try store.generation
        checks.require("compaction_generation", summary.generation == generation && currentGeneration == generation)
        checks.require("compaction_history_unchanged", try store.records(limit: 500) == original)
        checks.require("compaction_tail_unchanged", try store.records(after: boundary, limit: 500) == expectedTail)
        checks.require("compaction_memory_unchanged", try String(contentsOf: memoryURL, encoding: .utf8) == originalMemory)
        checks.require("compaction_no_question_callback", checks.counts["unexpected_compactor_questions", default: 0] == 0)
        checks.require("compaction_contains_source_reference", summary.text.contains("fixture-u-") || summary.text.contains("fixture-a-") || summary.text.contains("fixture-checkpoint-2"))
        checks.require("compaction_excludes_recent_tail", !summary.text.contains("TAIL_ONLY_SENTINEL"))
        checks.require("compaction_preserves_uncertainty", ["unknown", "unconfirmed", "not confirmed", "uncertain", "not verified"].contains(where: summary.text.lowercased().contains))
        checks.require("compaction_preserves_artifact", summary.text.contains("fixture://quartz-plan") || summary.text.contains("fixture://quartz-draft"))
    }

    @MainActor private static func providerFixture(_ provider: Provider, root: URL, checks: Checks) async throws {
        let suite = "ai.sentient.sidekick-backend-lab." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.invalidConfiguration }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try SidekickConversationStore(url: root.appendingPathComponent("history.sqlite"))
        let seed = UUID(), taskID = UUID()
        _ = try store.appendBatch([
            .init(id: historyID, taskID: seed, kind: .assistantMessage,
                  text: "Fixture token: QUARTZ-42. Option two is cobalt."),
            .init(taskID: seed, kind: .taskFinished, text: "Synthetic history seed", outcome: .success),
            .init(taskID: taskID, kind: .taskStarted),
            .init(taskID: taskID, kind: .userMessage, text: "Run the controlled Sidekick backend fixture.")
        ])
        let run = SidekickConversationRun(store: store, taskID: taskID, generation: try store.generation)
        let memoryURL = root.appendingPathComponent("SidekickMemory.md")
        let snapshot = try SidekickInstructionStore.read(defaults: defaults, memoryURL: memoryURL)
        let memory = SidekickPersonalization(snapshot: snapshot, taskID: taskID,
            request: "Synthetic integration fixture", defaults: defaults, memoryURL: memoryURL, onChange: { _ in })
        defer { memory.finish(success: checks.passed) }
        let backend: ModelBackend = [.chatgpt, .codex_fixture].contains(provider) ? .chatgpt : .claude
        try await ModelBackend.$runOverride.withValue(backend) {
            let interaction = SidekickInteraction(instructionsSnapshot: snapshot, personalization: memory,
                conversationRun: run) { question in
                guard question.question == "Which fixture label should the final answer use?",
                      question.answers == ["fixture-blue", "fixture-green"] else { throw Failure.wrongQuestion }
                checks.counts["fixture_answers", default: 0] += 1
                checks.require("question_saved_before_answer", try store.record(id: "question:\(question.id)") != nil)
                return SidekickAnswer(text: "fixture-blue", selectedAnswer: 0)
            }
            let prompt = fixturePrompt(bridge: provider == .claude_bridge) + "\n\n" + interaction.promptInstructions
            checks.counts["execution_started_unix_ms"] = Int(Date().timeIntervalSince1970 * 1000)
            let output = try await SidekickInteraction.$current.withValue(interaction) {
                try await ResearchToolServer.$connection.withValue(nil) {
                    try await DirectMCPRuntime.$current.withValue([]) {
                        try await SidekickToolServer.withConnection {
                            guard let connection = SidekickToolServer.connection else { throw Failure.invalidConfiguration }
                            if provider == .claude_bridge {
                                return try await bridgeRun(prompt: prompt, connection: connection, root: root, checks: checks)
                            }
                            if provider == .codex_fixture {
                                return try await codexFixtureRun(prompt: prompt, connection: connection, root: root, checks: checks)
                            }
                            return try await directRun(provider, prompt: prompt, connection: connection, root: root, checks: checks)
                        }
                    }
                }
            }
            checks.counts["execution_finished_unix_ms"] = Int(Date().timeIntervalSince1970 * 1000)
            recordProcessOutput(output, checks: checks)
            guard output.status == 0 else { throw Failure.processFailed }
            let parsed = try parseOutput(output.stdout, claude: provider == .claude, allowNative: provider == .claude_bridge)
            checks.counts["provider_tool_calls"] = parsed.calls.values.reduce(0, +)
            checks.counts["provider_unexpected_tools"] = parsed.unexpected
            for (kind, count) in parsed.unexpectedKinds { checks.counts["unexpected_item_" + kind] = count }
            for name in ["message_user", "search_history", "read_history", "ask_user", SidekickPersonalization.toolName] {
                checks.require("called_" + name, (parsed.calls[name] ?? 0) >= (name == "message_user" || name == SidekickPersonalization.toolName ? 2 : 1))
            }
            checks.require("only_fixture_tools", parsed.unexpected == 0)
            let completed: Bool
            if case .done = AgentStatus.parseConnector(parsed.final) { completed = true } else { completed = false }
            checks.require("status_done", completed)
            if !completed {
                // This path only runs the fixed synthetic prompt above. Show a short scrubbed
                // final assistant answer, never stderr, authentication errors, or tool bodies.
                checks.details["fixture_final_excerpt"] = SidekickConversationRun.bounded(
                    SidekickConversationRun.details(parsed.final) ?? "[unavailable]", bytes: 500)
            }
            guard completed else { throw Failure.unconfirmedStatus }
            try run.finish(outcome: .success, status: "Fixture completed", finalText: parsed.final)
            let records = try store.records(taskID: taskID, limit: 500)
            let messages = records.filter { $0.event.kind == .assistantMessage }
            let answers = messages.filter { $0.event.messageKind == .answer }
            checks.counts["saved_events"] = records.count
            checks.counts["saved_messages"] = messages.count
            checks.counts["saved_questions"] = records.filter { $0.event.kind == .question }.count
            checks.counts["saved_answers"] = records.filter { $0.event.kind == .answer }.count
            checks.require("one_final_answer", answers.count == 1 && messages.count == 2)
            checks.require("update_retained", messages.contains { $0.event.messageKind == .update && $0.event.text == "Fixture update." })
            checks.require("history_and_answer_in_final", answers.first?.event.text == "Fixture result: QUARTZ-42; fixture-blue.")
            checks.require("final_priority_retained", answers.first?.event.priority == .high)
            checks.require("actual_question_answer_retained", records.filter { $0.event.kind == .answer }.map(\.event.text) == ["fixture-blue"])
            checks.require("question_once", checks.counts["fixture_answers"] == 1 && checks.counts["saved_questions"] == 1)
            checks.require("memory_saved", try String(contentsOf: memoryURL, encoding: .utf8) == memoryText)
            checks.require("one_terminal", records.filter { $0.event.kind == .taskFinished }.count == 1)
            checks.require("messaging_wrapper_hidden", !records.contains { record in
                guard let name = record.event.activity?.name else { return false }
                let local = name.hasPrefix("sentient_recovery.") || name.hasPrefix("mcp__sentient_recovery__")
                let leaf = name.components(separatedBy: "__").last?.components(separatedBy: ".").last ?? name
                return local && ["message_user", "search_history", "read_history", "describe_task_usage"].contains(leaf)
            })
            let reopened = try SidekickConversationStore(url: store.url)
            checks.require("history_reopens", try reopened.records(taskID: taskID, limit: 500).count == records.count)
            checks.require("completed_task_not_recovered", try reopened.recoverInterruptedTasks().isEmpty)
        }
    }

    private static func fixturePrompt(bridge: Bool) -> String {
        """
        Run this controlled integration fixture. Every item is synthetic. Only the supplied
        sentient_recovery tools\(bridge ? " and synthetic sentient_native.get_app_state" : "") are allowed.
        Do not access real files, apps, accounts, shells, web search, or other services.
        Perform these steps once each, in this exact order, with no additional prose messages:
        1. message_user markdown="Fixture update.", kind="update", priority="normal".
        2. search_history query="Fixture token".
        3. read_history message_id="\(historyID)". Remember the token returned by history.
        4. ask_user error=null, question="Which fixture label should the final answer use?",
           answers=["fixture-blue","fixture-green"]. Wait for the actual returned answer.
        5. update_sidekick_instructions operation="read", markdown=null, revision=null.
        6. update_sidekick_instructions operation="write", using the revision just returned and
           markdown exactly "- Fixture preference: concise updates.\\n" (a real final newline).
        \(bridge ? "7. Call synthetic sentient_native.get_app_state with app=\"SidekickBackendFixture\" exactly once. It is a fake fixture and cannot access the desktop." : "")
        Then message_user kind="answer", priority="high", markdown exactly:
        "Fixture result: <the token from history>; <the actual ask_user answer>."
        Replace the angle-bracket placeholders with the tool results; include no quotes.
        Finally output only STATUS: DONE. If a required operation fails, output STATUS: COULD_NOT
        and do not pretend the fixture passed. Never call message_user a third time.
        """
    }

    private static let disabledOverrides = [
        "project_doc_max_bytes=0", "features.shell_tool=false", "features.view_image=false",
        "features.browser_use=false", "features.computer_use=false", "features.multi_agent=false",
        "features.code_mode=false", "features.image_generation=false", "features.goals=false",
        "features.skill_search=false", "features.tool_search=false", "features.plugins=false",
        "features.apps=false", "apps._default.enabled=false", "web_search=\"disabled\""
    ]

    @MainActor private static func directRun(_ provider: Provider, prompt: String,
        connection: SidekickToolServer.Connection, root: URL, checks: Checks) async throws -> CodexCLI.ExecResult {
        var invocation = CodexCLI.Invocation(prompt: prompt)
        invocation.cwd = root.path; invocation.timeout = timeout; invocation.effort = .low
        invocation.model = .gpt6sol; invocation.webSearch = false
        invocation.includeUserConfig = false; invocation.toolsDisabled = true
        invocation.configOverrides = disabledOverrides + connection.codexOverrides
        let binary: String, arguments: [String], environment: [String: String]
        switch provider {
        case .chatgpt:
            binary = CodexRuntime.executable.path
            // Match the existing ChatGPT-only branch of CodexCLI.backendTuned. The lab calls
            // the real argument builder/process runner directly to keep sessions ephemeral.
            let limited = CodexAuth.isLimited()
            let model = limited ? CodexCLI.Model.gpt56terra : invocation.model
            let effort = limited ? CodexCLI.Effort.medium : invocation.effort
            checks.details["selected_model"] = model.rawValue
            checks.details["selected_effort"] = effort.rawValue
            checks.counts["production_plan_downshift"] = limited ? 1 : 0
            var args = try CodexCLI.arguments(for: invocation, modelID: model.rawValue,
                effortArg: effort.rawValue, schemaFile: nil)
            args.insert("--ephemeral", at: args.count - 1)
            arguments = args; environment = [:]
        case .claude:
            guard let located = ClaudeCLI.locateBinary() else { throw Failure.unavailableRuntime }
            binary = located
            let tuned = ClaudeCLI.tuned(for: invocation)
            checks.details["selected_model"] = tuned.modelID
            checks.details["selected_effort"] = tuned.effortArg
            var args = try ClaudeCLI.arguments(for: invocation, modelID: tuned.modelID, effortArg: tuned.effortArg)
            args += ["--no-session-persistence", "--settings",
                ClaudeCLI.mcpServerAllowSettings(serverURLs: [], serverNames: [SidekickToolServer.name])]
            arguments = args
            environment = ClaudeCLI.environment(for: invocation).merging([
                "ENABLE_TOOL_SEARCH": "false", "MCP_CONNECTION_NONBLOCKING": "0",
                "MCP_CONNECT_TIMEOUT_MS": "30000", "MCP_TOOL_TIMEOUT": "180000"
            ]) { _, new in new }
        case .claude_bridge, .codex_fixture: throw Failure.invalidConfiguration
        }
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw Failure.unavailableRuntime }
        return try await CodexCLI.executeAsync(binary: binary, args: arguments, stdinText: prompt,
            cwd: root.path, timeout: timeout, extraEnv: environment, includeCustomProviderKey: false,
            observeAgentTools: true, onStdoutLine: { _ in })
    }

    @MainActor private static func codexFixtureRun(prompt: String, connection: SidekickToolServer.Connection,
        root: URL, checks: Checks) async throws -> CodexCLI.ExecResult {
        guard FileManager.default.isExecutableFile(atPath: CodexRuntime.executable.path) else { throw Failure.unavailableRuntime }
        let provider = ResponsesFixture(root: root)
        checks.details["evidence"] = "local_deterministic_endpoint_not_real_chatgpt"
        checks.details["selected_model"] = ResponsesFixture.model
        checks.details["selected_effort"] = "low"
        do {
            let configuration = try await provider.start()
            var invocation = CodexCLI.Invocation(prompt: prompt)
            invocation.cwd = root.path; invocation.timeout = 30; invocation.effort = .low
            invocation.webSearch = false; invocation.includeUserConfig = false; invocation.toolsDisabled = true
            invocation.configOverrides = disabledOverrides + connection.codexOverrides + configuration.overrides
            var args = try CodexCLI.arguments(for: invocation, modelID: ResponsesFixture.model,
                effortArg: "low", schemaFile: nil)
            args.insert("--ephemeral", at: args.count - 1)
            let output = try await withTaskCancellationHandler {
                try await CodexCLI.executeAsync(binary: CodexRuntime.executable.path, args: args,
                    stdinText: prompt, cwd: root.path, timeout: 30, extraEnv: configuration.environment,
                    includeCustomProviderKey: false, observeAgentTools: true, onStdoutLine: { _ in })
            } onCancel: { Task { await provider.stop() } }
            recordProcessOutput(output, checks: checks)
            let snapshot = await provider.snapshot()
            checks.counts["fixture_provider_requests"] = snapshot.requests
            checks.counts["fixture_tools_exposed"] = snapshot.exposed
            checks.counts["fixture_tool_results_verified"] = snapshot.completed
            for (name, count) in snapshot.surface { checks.counts["fixture_surface_" + name] = count }
            checks.details["fixture_endpoint_failure"] = snapshot.failure
            checks.require("fixture_only_mcp_surface", snapshot.exposed == 5 && snapshot.failure == "none")
            checks.require("fixture_verified_all_receipts", snapshot.completed == 7)
            await provider.stop()
            if output.status == 0 { try await toolsDisabledProbe(root: root, checks: checks) }
            return output
        } catch { await provider.stop(); throw error }
    }

    @MainActor private static func toolsDisabledProbe(root: URL, checks: Checks) async throws {
        let answersBefore = checks.counts["fixture_answers"] ?? 0
        let directory = root.appendingPathComponent("tools-disabled-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let provider = ResponsesFixture(root: directory, probe: true)
        do {
            let configuration = try await provider.start()
            let prompt = "Run only the local tools-disabled enforcement fixture. No real inference or user accounts are involved."
            var invocation = CodexCLI.Invocation(prompt: prompt)
            invocation.cwd = directory.path; invocation.timeout = 20; invocation.effort = .low
            invocation.webSearch = false; invocation.includeUserConfig = false; invocation.toolsDisabled = true
            invocation.configOverrides = disabledOverrides + configuration.overrides
            let output = try await SidekickInteraction.$current.withValue(nil) {
                try await SidekickToolServer.$connection.withValue(nil) {
                    var args = try CodexCLI.arguments(for: invocation, modelID: ResponsesFixture.model, effortArg: "low", schemaFile: nil)
                    args.insert("--ephemeral", at: args.count - 1)
                    return try await CodexCLI.executeAsync(binary: CodexRuntime.executable.path, args: args,
                        stdinText: prompt, cwd: directory.path, timeout: 20, extraEnv: configuration.environment,
                        includeCustomProviderKey: false, onStdoutLine: { _ in })
                }
            }
            let snapshot = await provider.snapshot()
            checks.details["tools_disabled_probe_failure"] = snapshot.failure
            checks.counts["tools_disabled_probe_exit_code"] = Int(output.status)
            checks.counts["tools_disabled_probe_receipts"] = snapshot.completed
            checks.counts["tools_disabled_probe_expected"] = snapshot.expected
            for (name, count) in snapshot.surface { checks.counts["tools_disabled_surface_" + name] = count }
            checks.require("tools_disabled_no_foreground_mcp", snapshot.exposed == 0)
            checks.require("tools_disabled_no_question_callback", (checks.counts["fixture_answers"] ?? 0) == answersBefore)
            checks.require("tools_disabled_probe_completed", snapshot.completed == snapshot.expected && output.status == 0)
            for (name, value) in snapshot.probes { checks.require("tools_disabled_" + name, value) }
            checks.require("tools_disabled_patch_no_file", !FileManager.default.fileExists(atPath: directory.appendingPathComponent("sidekick-probe-created.txt").path))
            await provider.stop()
        } catch { await provider.stop(); throw error }
    }

    /// A deterministic Responses endpoint. It executes nothing itself: every requested MCP
    /// call travels through the real Codex process to the production Sidekick tool server.
    private actor ResponsesFixture {
        nonisolated static let model = "sentient-sidekick-local-fixture"
        private static let key = "SENTIENT_SIDEKICK_FIXTURE_TOKEN"
        struct Configuration: Sendable { let overrides: [String]; let environment: [String: String] }
        struct Snapshot: Sendable { let requests: Int; let exposed: Int; let completed: Int; let expected: Int; let failure: String; let surface: [String: Int]; let probes: [String: Bool] }
        private struct Tool { let namespace: String?; let name: String; let custom: Bool; let sidekick: Bool }
        private enum Problem: String, Error {
            case transport, badRequest, unexpectedTools, missingReceipt, badReceipt, incompleteHistory, memoryRevision
        }
        private let root: URL
        private let probe: Bool
        private let secret = "fixture-" + UUID().uuidString
        private var listener: NWListener?
        private var startup: CheckedContinuation<UInt16, Error>?
        private var connections: [UUID: NWConnection] = [:]
        private var closed = false
        private var requests = 0
        private var tools: [String: Tool] = [:]
        private var completed = 0
        private var pending: Int?
        private var revision: String?
        private var historyToken: String?
        private var answer: String?
        private var responses: [String: Data] = [:]
        private var failure = "none"
        private var surface: [String: Int] = [:]
        private var probeResults: [String: Bool] = [:]
        private static let sidekickNames: Set<String> = ["message_user", "search_history", "read_history", "ask_user", "update_sidekick_instructions"]
        private static let builtinNames: Set<String> = ["apply_patch", "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource", "request_user_input"]
        private var probeSequence = ["apply_patch", "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource", "request_user_input"]
        private var sequence: [String] {
            probe ? probeSequence
                : ["message_user", "search_history", "read_history", "ask_user", "update_sidekick_instructions", "update_sidekick_instructions", "message_user"]
        }

        init(root: URL, probe: Bool = false) { self.root = root; self.probe = probe }
        func snapshot() -> Snapshot { .init(requests: requests, exposed: tools.values.filter(\.sidekick).count, completed: completed, expected: sequence.count, failure: failure, surface: surface, probes: probeResults) }

        func start() async throws -> Configuration {
            let catalog = root.appendingPathComponent("fixture-models.json")
            try ClaudeSubscriptionProtocol.json(ClaudeSubscriptionProtocol.catalog(model: Self.model)).write(to: catalog, options: .atomic)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: parameters)
            listener = server
            server.newConnectionHandler = { [weak self] connection in Task { await self?.serve(connection) } }
            server.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state) } }
            let deadline = Task {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { self.failedStartup() }
            }
            defer { deadline.cancel() }
            let port = try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                server.start(queue: DispatchQueue(label: "sentient.sidekick-fixture.model"))
            }
            let table = "model_providers.sentient_sidekick_fixture={name=\"Local Sidekick fixture\",base_url=\"http://127.0.0.1:\(port)/v1\","
                + "wire_api=\"responses\",env_key=\"\(Self.key)\",requires_openai_auth=false,"
                + "supports_websockets=false,request_max_retries=0,stream_max_retries=0}"
            return .init(overrides: [table, "model_provider=\"sentient_sidekick_fixture\"",
                "model_catalog_json=\(OpenAIComputerUse.tomlString(catalog.path))", "features.enable_request_compression=false",
                "model_auto_compact_token_limit=9223372036854775807"], environment: [Self.key: secret])
        }
        private func changed(_ state: NWListener.State) {
            switch state {
            case .ready:
                if let port = listener?.port?.rawValue { startup?.resume(returning: port); startup = nil }
            case .failed: failedStartup()
            default: break
            }
        }
        private func failedStartup() {
            startup?.resume(throwing: Problem.transport); startup = nil
            listener?.cancel(); listener = nil
        }
        func stop() {
            closed = true; failedStartup()
            connections.values.forEach { $0.cancel() }; connections.removeAll()
        }
        private func serve(_ connection: NWConnection) async {
            guard !closed, connections.count < 16 else { connection.cancel(); return }
            let id = UUID()
            connections[id] = connection
            connection.start(queue: DispatchQueue(label: "sentient.sidekick-fixture.request"))
            defer { connection.cancel(); connections.removeValue(forKey: id) }
            do {
                let request = try await LoopbackHTTP.read(connection, maximumBody: 2_097_152,
                    authorize: { [secret] headers in headers["authorization"] == "Bearer " + secret && headers["origin"] == nil })
                let path = String(request.path.split(separator: "?", maxSplits: 1)[0])
                if request.method == "GET", path == "/v1/models" {
                    try await LoopbackHTTP.write(connection, LoopbackHTTP.response(status: 200,
                        body: ClaudeSubscriptionProtocol.json(["object": "list", "data": [["id": Self.model, "object": "model"]]])))
                } else {
                    guard request.method == "POST", path == "/v1/responses",
                          let payload = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { throw Problem.badRequest }
                    let response = try respond(payload)
                    try await LoopbackHTTP.write(connection, LoopbackHTTP.response(status: 200, contentType: "text/event-stream", body: response))
                }
            } catch {
                failure = (error as? Problem)?.rawValue ?? "transport"
                let body = try? ClaudeSubscriptionProtocol.json(["error": ["type": "fixture_error", "message": "The local synthetic fixture rejected the request."]])
                try? await LoopbackHTTP.write(connection, LoopbackHTTP.response(status: 400, body: body ?? Data()))
            }
        }
        private func respond(_ payload: [String: Any]) throws -> Data {
            guard !closed, payload["model"] as? String == Self.model,
                  let input = payload["input"] as? [[String: Any]] else { throw Problem.badRequest }
            let fingerprint = try ClaudeSubscriptionProtocol.fingerprint(payload)
            if let cached = responses[fingerprint] { return cached }
            requests += 1
            if tools.isEmpty { try inspectTools(payload["tools"]) }
            if let stage = pending {
                let id = "call_sidekick_fixture_\(stage)"
                guard let receipt = input.last(where: { ["function_call_output", "custom_tool_call_output"].contains($0["type"] as? String ?? "") && $0["call_id"] as? String == id }) else {
                    throw Problem.missingReceipt
                }
                if probe { try verifyProbe(receipt["output"] as Any, stage: stage) }
                else { try verifyReceipt(receipt["output"] as Any, stage: stage) }
                completed += 1; pending = nil
            }
            let item: [String: Any]
            if completed == sequence.count {
                item = ["id": "msg_sidekick_fixture_final", "type": "message", "role": "assistant", "status": "completed",
                    "phase": "final_answer", "content": [["type": "output_text", "text": "STATUS: DONE", "annotations": []]]]
            } else {
                let name = sequence[completed]
                guard let tool = tools[name] else { throw Problem.unexpectedTools }
                var call: [String: Any] = ["id": "fc_sidekick_fixture_\(completed)", "type": tool.custom ? "custom_tool_call" : "function_call", "status": "completed",
                    "call_id": "call_sidekick_fixture_\(completed)", "name": tool.name]
                if tool.custom { call["input"] = Self.patch }
                else {
                    let args = try probe ? probeArguments(stage: completed) : arguments(stage: completed)
                    call["arguments"] = String(decoding: try ClaudeSubscriptionProtocol.json(args), as: UTF8.self)
                }
                if let namespace = tool.namespace { call["namespace"] = namespace }
                item = call; pending = completed
            }
            let response = item["type"] as? String == "custom_tool_call"
                ? try Self.customResponse(item) : try ClaudeSubscriptionProtocol.response(item: item, model: Self.model)
            responses[fingerprint] = response
            return response
        }
        private func inspectTools(_ value: Any?) throws {
            guard let advertised = value as? [[String: Any]] else { throw Problem.unexpectedTools }
            let allowed = Self.sidekickNames.union(Self.builtinNames)
            // Only a fixed vocabulary reaches diagnostics; arbitrary tool/server names may
            // contain account labels and are counted as unknown rather than printed.
            let known = allowed.union(["update_plan", "exec_command", "shell_command", "write_stdin", "view_image",
                "apply_patch", "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource",
                "request_user_input", "tool_search", "web_search"])
            for entry in advertised {
                let candidates = entry["tools"] as? [[String: Any]] ?? [entry]
                for candidate in candidates {
                    let name = candidate["name"] as? String ?? ""
                    let leaf = name.components(separatedBy: "__").last ?? name
                    surface[known.contains(leaf) ? leaf : "unknown", default: 0] += 1
                }
            }
            func register(_ entry: [String: Any], namespace: String?) throws {
                guard let name = entry["name"] as? String,
                      ["function", "custom"].contains(entry["type"] as? String ?? "") else { throw Problem.unexpectedTools }
                let flatMCP = name.hasPrefix("mcp__sentient_recovery__")
                let sidekick = namespace == "mcp__sentient_recovery" || flatMCP
                let leaf = flatMCP ? String(name.dropFirst("mcp__sentient_recovery__".count)) : name
                guard tools[leaf] == nil, (sidekick ? (!probe && Self.sidekickNames.contains(leaf)) : Self.builtinNames.contains(leaf)) else {
                    throw Problem.unexpectedTools
                }
                tools[leaf] = Tool(namespace: namespace, name: name, custom: entry["type"] as? String == "custom", sidekick: sidekick)
                if leaf == "apply_patch" { surface[entry["type"] as? String == "custom" ? "apply_patch_custom_dialect" : "apply_patch_function_dialect"] = 1 }
            }
            for entry in advertised {
                if entry["type"] as? String == "namespace" {
                    guard let namespace = entry["name"] as? String, ["mcp__sentient_recovery", "functions"].contains(namespace),
                          let nested = entry["tools"] as? [[String: Any]] else { throw Problem.unexpectedTools }
                    for function in nested { try register(function, namespace: namespace) }
                } else { try register(entry, namespace: nil) }
            }
            if probe {
                for name in probeSequence where tools[name] == nil { probeResults[name + "_absent"] = true }
                probeSequence = probeSequence.filter { tools[$0] != nil }
            } else {
                guard Set(sequence).isSubset(of: Set(tools.keys)) else { throw Problem.unexpectedTools }
            }
        }
        private static let patch = "*** Begin Patch\n*** Add File: sidekick-probe-created.txt\n+synthetic forbidden write\n*** End Patch"
        private func probeArguments(stage: Int) throws -> [String: Any] {
            switch sequence[stage] {
            case "apply_patch": return ["input": Self.patch]
            case "list_mcp_resources", "list_mcp_resource_templates": return [:]
            case "read_mcp_resource": return ["server": "sentient_recovery", "uri": "fixture://unavailable"]
            case "request_user_input": return ["questions": [["header": "Fixture", "id": "fixture_only", "question": "Synthetic unavailable input probe?",
                "options": [["label": "First", "description": "Synthetic first choice."], ["label": "Second", "description": "Synthetic second choice."]]]]]
            default: throw Problem.badRequest
            }
        }
        private func verifyProbe(_ value: Any, stage: Int) throws {
            let objects = Self.objects(value)
            let text = String(decoding: try ClaudeSubscriptionProtocol.json(value), as: UTF8.self).lowercased()
            switch sequence[stage] {
            case "apply_patch":
                let malformed = ["unknown tool", "unknown function", "invalid function", "error parsing", "failed to parse", "invalid patch", "patch verification failed"].contains(where: text.contains)
                let policy = ["approval settings", "approval policy", "not permitted", "read-only", "read only", "permission denied"].contains(where: text.contains)
                probeResults["patch_policy_refusal"] = policy && !malformed
                probeResults["patch_denied"] = policy && !malformed
                    && !FileManager.default.fileExists(atPath: root.appendingPathComponent("sidekick-probe-created.txt").path)
            case "list_mcp_resources":
                probeResults["resources_empty"] = objects.contains { ($0["resources"] as? [Any])?.isEmpty == true }
            case "list_mcp_resource_templates":
                probeResults["resource_templates_empty"] = objects.contains { object in
                    ["resourceTemplates", "resource_templates", "templates"].contains { (object[$0] as? [Any])?.isEmpty == true }
                }
            case "read_mcp_resource":
                probeResults["foreground_resource_read_denied"] = ["unknown", "not found", "unavailable", "not configured"].contains(where: text.contains)
            case "request_user_input":
                probeResults["user_input_denied"] = text.contains("request_user_input") && ["unavailable", "unsupported", "not available", "not supported", "only available"].contains(where: text.contains)
            default: throw Problem.badReceipt
            }
        }
        private static func customResponse(_ item: [String: Any]) throws -> Data {
            let id = "resp_sidekick_custom_" + UUID().uuidString
            var response: [String: Any] = ["id": id, "object": "response", "created_at": Int(Date().timeIntervalSince1970),
                "status": "in_progress", "model": model, "output": []]
            var bytes = Data(), sequence = 0
            func emit(_ type: String, _ fields: [String: Any]) throws {
                var event = fields; event["type"] = type; event["sequence_number"] = sequence; sequence += 1
                bytes.append(Data("event: \(type)\ndata: ".utf8))
                bytes.append(try ClaudeSubscriptionProtocol.json(event)); bytes.append(Data("\n\n".utf8))
            }
            try emit("response.created", ["response": response])
            try emit("response.in_progress", ["response": response])
            var begun = item; begun["status"] = "in_progress"; begun["input"] = ""
            try emit("response.output_item.added", ["output_index": 0, "item": begun])
            try emit("response.custom_tool_call_input.delta", ["item_id": item["id"]!, "output_index": 0, "delta": item["input"]!])
            try emit("response.custom_tool_call_input.done", ["item_id": item["id"]!, "output_index": 0, "input": item["input"]!])
            try emit("response.output_item.done", ["output_index": 0, "item": item])
            response["status"] = "completed"; response["output"] = [item]
            try emit("response.completed", ["response": response])
            return bytes
        }
        private func arguments(stage: Int) throws -> [String: Any] {
            switch stage {
            case 0: return ["markdown": "Fixture update.", "kind": "update", "priority": "normal"]
            case 1: return ["query": "Fixture token"]
            case 2: return ["message_id": SidekickBackendLab.historyID]
            case 3: return ["error": NSNull(), "question": "Which fixture label should the final answer use?", "answers": ["fixture-blue", "fixture-green"]]
            case 4: return ["operation": "read", "markdown": NSNull(), "revision": NSNull()]
            case 5:
                guard let revision else { throw Problem.memoryRevision }
                return ["operation": "write", "markdown": SidekickBackendLab.memoryText, "revision": revision]
            case 6:
                guard let historyToken, let answer else { throw Problem.incompleteHistory }
                return ["markdown": "Fixture result: \(historyToken); \(answer).", "kind": "answer", "priority": "high"]
            default: throw Problem.badRequest
            }
        }
        private func verifyReceipt(_ value: Any, stage: Int) throws {
            let objects = Self.objects(value)
            guard !objects.contains(where: { $0["isError"] as? Bool == true }) else { throw Problem.badReceipt }
            switch stage {
            case 0, 6:
                guard objects.contains(where: { $0["saved"] as? Bool == true && $0["message_id"] is String }) else { throw Problem.badReceipt }
            case 1:
                guard objects.contains(where: { $0["message_id"] as? String == SidekickBackendLab.historyID }) else { throw Problem.incompleteHistory }
            case 2:
                guard let read = objects.first(where: { $0["message_id"] as? String == SidekickBackendLab.historyID && $0["text"] is String }),
                      let text = read["text"] as? String, let range = text.range(of: "Fixture token: "),
                      let end = text[range.upperBound...].firstIndex(of: ".") else { throw Problem.incompleteHistory }
                historyToken = String(text[range.upperBound..<end])
            case 3:
                guard let result = objects.first(where: { $0["selectedAnswer"] as? Int == 0 }),
                      let text = result["text"] as? String, text == "fixture-blue" else { throw Problem.badReceipt }
                answer = text
            case 4:
                guard let result = objects.first(where: { $0["revision"] is String && $0["markdown"] is String }),
                      let value = result["revision"] as? String, value.count == 64 else { throw Problem.memoryRevision }
                revision = value
            case 5:
                guard objects.contains(where: { $0["markdown"] as? String == SidekickBackendLab.memoryText && $0["revision"] is String }) else { throw Problem.badReceipt }
            default: throw Problem.badReceipt
            }
        }
        private static func objects(_ value: Any, depth: Int = 0) -> [[String: Any]] {
            guard depth < 10 else { return [] }
            if let object = value as? [String: Any] {
                return [object] + object.values.flatMap { objects($0, depth: depth + 1) }
            }
            if let array = value as? [Any] { return array.prefix(32).flatMap { objects($0, depth: depth + 1) } }
            if let text = value as? String {
                if let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
                    return objects(parsed, depth: depth + 1)
                }
                if text.hasPrefix("Current SidekickMemory.md:\n") || text.hasPrefix("Saved SidekickMemory.md.\n"),
                   let newline = text.firstIndex(of: "\n"),
                   let parsed = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) {
                    return objects(parsed, depth: depth + 1)
                }
            }
            return []
        }
    }

    @MainActor private static func bridgeRun(prompt: String, connection: SidekickToolServer.Connection,
        root: URL, checks: Checks) async throws -> CodexCLI.ExecResult {
        guard let claude = ClaudeCLI.locateBinary(), FileManager.default.isExecutableFile(atPath: CodexRuntime.executable.path) else {
            throw Failure.unavailableRuntime
        }
        let fixture = NativeFixture()
        checks.details["selected_model"] = ClaudeCLI.Model.sonnet.rawValue
        checks.details["selected_effort"] = "low"
        let native = LocalMCPServer(name: "sentient_native", tools: ["get_app_state"], timeout: timeout,
            maximumBody: 65_536) { data in try await fixture.response(data) }
        let bridge = ClaudeSubscriptionBridge(binary: claude, model: ClaudeCLI.Model.sonnet.rawValue,
            effort: "low", timeout: timeout, namespaces: ["mcp__sentient_native", "mcp__sentient_recovery"], onProgress: { _ in })
        do {
            let nativeConnection = try await native.start()
            let configuration = try await bridge.start()
            let overrides = configuration.overrides + connection.codexOverrides + disabledOverrides
            var args = try CodexCLI.agentArguments(prompt: prompt, imagePaths: [],
                modelID: ClaudeCLI.Model.sonnet.rawValue, effortArg: "low", providerOverrides: overrides,
                nativeConnection: nativeConnection)
            args.insert(contentsOf: ["--ephemeral", "--cd", root.path], at: args.count - 1)
            var environment = configuration.environment
            // Streaming uses the normal rich environment, but this fixture has no custom model.
            environment[CustomProvider.apiKeyEnvName] = "fixture-no-custom-provider-key"
            let output = try await withTaskCancellationHandler {
                try await ComputerUseStream.run(binary: CodexRuntime.executable.path, args: args,
                    timeout: timeout, extraEnv: environment, narrate: false, onLine: { _ in })
            } onCancel: {
                Task { await bridge.stop(); await native.stop() }
            }
            recordProcessOutput(output, checks: checks)
            if await bridge.failure != nil { throw Failure.processFailed }
            checks.counts["synthetic_native_calls"] = await fixture.calls
            checks.require("synthetic_native_once", await fixture.calls == 1)
            await bridge.stop(); await native.stop()
            return output
        } catch { await bridge.stop(); await native.stop(); throw error }
    }

    /// Fixed classifications only. The input may contain provider-account or authentication
    /// text even though the task is synthetic, so no excerpt or arbitrary error code escapes.
    @MainActor private static func recordProcessOutput(_ output: CodexCLI.ExecResult, checks: Checks) {
        checks.counts["provider_exit_code"] = Int(output.status)
        checks.counts["provider_stdout_bytes"] = output.stdout.utf8.count
        checks.counts["provider_stderr_bytes"] = output.stderr.utf8.count
        var errors = 0, tools = 0, assistantMessages = 0, turnStarts = 0, turnCompletions = 0
        var errorMessages: [String] = []
        var nonterminalErrors = 0
        var ready = 0, starting = 0, readinessFailures = 0
        func readiness(_ text: String) {
            let lower = text.lowercased()
            if ["fail", "error", "timeout", "timed out"].contains(where: lower.contains) { readinessFailures += 1 }
            else if ["ready", "connected", "initialized", "complete"].contains(where: lower.contains) { ready += 1 }
            else if ["start", "connecting", "initializ"].contains(where: lower.contains) { starting += 1 }
        }
        for line in output.stdout.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = event["type"] as? String ?? ""
            if type == "turn.started" { turnStarts += 1 }
            if type == "turn.completed" { turnCompletions += 1 }
            if type.lowercased().contains("mcp"), type.lowercased().contains("startup") || type.lowercased().contains("status") {
                let status = event["status"] as? String ?? event["state"] as? String ?? ""
                readiness(status)
            }
            if ["error", "turn.failed"].contains(type) || (type == "result" && event["is_error"] as? Bool == true) {
                errors += 1
                let error = event["error"] as? [String: Any] ?? [:]
                errorMessages += [error["message"], error["code"], event["message"], event["result"]].compactMap { $0 as? String }
            }
            if type == "item.started", let item = event["item"] as? [String: Any],
               ["mcp_tool_call", "command_execution", "web_search"].contains(item["type"] as? String ?? "") { tools += 1 }
            if type == "assistant", let message = event["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                tools += content.filter { $0["type"] as? String == "tool_use" }.count
            }
            if type == "item.completed", let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message" {
                assistantMessages += 1
            }
            if type == "item.completed", let item = event["item"] as? [String: Any], item["type"] as? String == "error" {
                nonterminalErrors += 1
                let message = (item["message"] as? String ?? item["text"] as? String ?? "").lowercased()
                let unsupported = ["not supported", "unsupported", "not available", "unavailable", "does not support", "doesn't support", "aren't supported"].contains(where: message.contains)
                if message.hasPrefix("configured service tier "),
                   message.contains("not advertised as supported for model"),
                   message.contains("will be omitted from requests") {
                    // Exact CLI configuration notice, not a provider/tool failure. Retain only
                    // this fixed category; never persist the message, model/account or stderr.
                    checks.details["provider_nonterminal_error_category"] = "service_tier_not_advertised"
                } else if message.contains("reasoning"), message.contains("summar"), unsupported {
                    checks.details["provider_nonterminal_error_category"] = "reasoning_summary_unsupported"
                } else if (message.contains("fast") || message.contains("service tier")) && unsupported {
                    checks.details["provider_nonterminal_error_category"] = "fast_service_tier_unsupported"
                } else { checks.details["provider_nonterminal_error_category"] = CodexFailureReason.classify(text: message).rawValue }
            }
        }
        for line in output.stderr.split(separator: "\n") {
            let text = line.lowercased()
            if text.contains("mcp"), text.contains("startup") || text.contains("initializ") { readiness(text) }
        }
        checks.counts["provider_error_events"] = errors
        checks.counts["provider_nonterminal_error_items"] = nonterminalErrors
        checks.counts["provider_observed_tool_starts"] = tools
        checks.counts["provider_agent_messages"] = assistantMessages
        checks.counts["provider_turn_starts"] = turnStarts
        checks.counts["provider_turn_completions"] = turnCompletions
        checks.counts["mcp_ready_events"] = ready
        checks.counts["mcp_starting_events"] = starting
        checks.counts["mcp_failed_events"] = readinessFailures
        checks.details["mcp_readiness_evidence"] = ready + starting + readinessFailures > 0 ? "reported" : "not_reported"
        if output.status == 0 && errors == 0 {
            checks.details["provider_output_reason"] = "none"
            checks.details["provider_failure_hint"] = "none"
        } else {
            // Do not classify successful transcripts/UUIDs as HTTP codes. Only actual error
            // messages and failure stderr enter the existing fixed-vocabulary classifier.
            let errorText = (errorMessages + (output.status == 0 ? [] : [output.stderr])).joined(separator: "\n")
            checks.details["provider_output_reason"] = CodexFailureReason.classify(text: errorText).rawValue
            let text = errorText.lowercased()
            let hint: String
            if text.contains("unexpected argument") || text.contains("unrecognized argument") { hint = "cli_argument_rejected" }
            else if text.contains("model"), ["not supported", "does not exist", "unknown model", "model_not_found", "not available"].contains(where: text.contains) { hint = "model_or_entitlement_rejected" }
            else if text.contains("mcp"), ["failed", "timed out", "refused", "startup"].contains(where: text.contains) { hint = "mcp_startup_or_call_failed" }
            else if text.contains("error loading config") || text.contains("unknown variant") || text.contains("invalid value") { hint = "configuration_rejected" }
            else { hint = "unclassified_failure" }
            checks.details["provider_failure_hint"] = hint
        }
    }

    private struct Parsed {
        var final = ""
        var calls: [String: Int] = [:]
        var unexpected = 0
        var unexpectedKinds: [String: Int] = [:]
    }
    private static func parseOutput(_ output: String, claude: Bool, allowNative: Bool = false) throws -> Parsed {
        var parsed = Parsed()
        var observedItems = Set<String>()
        let allowed = Set(SidekickConversationTools.names + ["ask_user", SidekickPersonalization.toolName])
        for line in output.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if claude {
                if type == "result" {
                    guard object["is_error"] as? Bool != true else { throw Failure.processFailed }
                    parsed.final = object["result"] as? String ?? ""
                }
                if type == "assistant", let message = object["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for block in content where block["type"] as? String == "tool_use" {
                        let name = block["name"] as? String ?? ""
                        let leaf = name.components(separatedBy: "__").last ?? name
                        if name.hasPrefix("mcp__sentient_recovery__"), allowed.contains(leaf) {
                            parsed.calls[leaf, default: 0] += 1
                        } else { parsed.unexpected += 1 }
                    }
                }
            } else if let item = object["item"] as? [String: Any] {
                if type == "item.completed", item["type"] as? String == "agent_message" {
                    parsed.final = item["text"] as? String ?? ""
                }
                let itemType = item["type"] as? String ?? ""
                guard ["item.started", "item.completed"].contains(type),
                      !["agent_message", "reasoning", "error"].contains(itemType) else { continue }
                // Every executable item counts, including a file_change that appears only at
                // completion. Duplicate start/complete notifications are one actual operation.
                if let id = item["id"] as? String, !observedItems.insert(id).inserted { continue }
                if itemType == "mcp_tool_call" {
                    let name = item["tool"] as? String ?? ""
                    let server = item["server"] as? String ?? ""
                    if (server == "sentient_recovery" && allowed.contains(name))
                        || (allowNative && server == "sentient_native" && name == "get_app_state") {
                        parsed.calls[name, default: 0] += 1
                    } else { parsed.unexpected += 1 }
                } else {
                    // file_change, command/web calls, plans, other executors, and future
                    // unknown action-item variants are forbidden in this exact fixture.
                    parsed.unexpected += 1
                    let kind = itemType.range(of: #"^[a-z_]{1,64}$"#, options: .regularExpression) == nil ? "unknown" : itemType
                    parsed.unexpectedKinds[kind, default: 0] += 1
                }
            }
        }
        guard !parsed.final.isEmpty else { throw Failure.protocolMismatch }
        return parsed
    }

    @MainActor private static func parserFixture(checks: Checks) throws {
        func stream(_ items: [[String: Any]]) throws -> String {
            let final: [String: Any] = ["type": "item.completed", "item": ["id": "final", "type": "agent_message", "text": "STATUS: DONE"]]
            return try (items + [final]).map { String(decoding: try ClaudeSubscriptionProtocol.json($0), as: UTF8.self) }.joined(separator: "\n")
        }
        func item(_ phase: String, _ type: String, id: String = "operation", server: String? = nil, tool: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["id": id, "type": type]
            if let server { value["server"] = server }
            if let tool { value["tool"] = tool }
            return ["type": phase, "item": value]
        }
        let allowed = try parseOutput(stream([
            item("item.started", "mcp_tool_call", server: "sentient_recovery", tool: "message_user"),
            item("item.completed", "mcp_tool_call", server: "sentient_recovery", tool: "message_user")
        ]), claude: false)
        checks.require("parser_one_operation_per_item", allowed.calls["message_user"] == 1 && allowed.unexpected == 0)
        for type in ["file_change", "command_execution", "web_search", "todo_list", "collab_agent_tool_call", "future_unknown_executor"] {
            let parsed = try parseOutput(stream([item("item.completed", type)]), claude: false)
            checks.require("parser_rejects_" + type, parsed.unexpected == 1)
        }
        let duplicate = try parseOutput(stream([item("item.started", "file_change"), item("item.completed", "file_change")]), claude: false)
        checks.require("parser_deduplicates_forbidden_operation", duplicate.unexpected == 1)
        let native = try stream([item("item.completed", "mcp_tool_call", server: "sentient_native", tool: "get_app_state")])
        checks.require("parser_direct_rejects_native", try parseOutput(native, claude: false).unexpected == 1)
        let bridge = try parseOutput(native, claude: false, allowNative: true)
        checks.require("parser_bridge_accepts_only_fixture_native", bridge.calls["get_app_state"] == 1 && bridge.unexpected == 0)
        let wrongServer = try parseOutput(stream([item("item.started", "mcp_tool_call", server: "sentient_native", tool: "message_user")]), claude: false, allowNative: true)
        checks.require("parser_tool_server_pair_enforced", wrongServer.unexpected == 1)
        let narration = try parseOutput(stream([item("item.completed", "reasoning")]), claude: false)
        checks.require("parser_narration_is_not_action", narration.unexpected == 0 && narration.final == "STATUS: DONE")
        let errorItem = try parseOutput(stream([item("item.completed", "error")]), claude: false)
        checks.require("parser_reports_error_separately_from_executor", errorItem.unexpected == 0)
        let claude: [[String: Any]] = [
            ["type": "assistant", "message": ["content": [
                ["type": "tool_use", "name": "mcp__sentient_recovery__message_user"],
                ["type": "tool_use", "name": "Bash"]]]],
            ["type": "result", "is_error": false, "result": "STATUS: DONE"]
        ]
        let claudeStream = try claude.map { String(decoding: try ClaudeSubscriptionProtocol.json($0), as: UTF8.self) }.joined(separator: "\n")
        let parsedClaude = try parseOutput(claudeStream, claude: true)
        checks.require("parser_claude_extra_tool_rejected", parsedClaude.calls["message_user"] == 1 && parsedClaude.unexpected == 1)

        func notice(_ message: String) throws -> Checks {
            let observed = Checks()
            let output = try stream([["type": "item.completed", "item": [
                "id": "fixture-notice", "type": "error", "message": message]]])
            recordProcessOutput(.init(status: 0, stdout: output, stderr: ""), checks: observed)
            return observed
        }
        let tierNotice = try notice("Configured service tier `fast` is not advertised as supported for model `sentient-sidekick-local-fixture` and will be omitted from requests.")
        checks.require("parser_service_tier_omission_classified", tierNotice.details["provider_nonterminal_error_category"] == "service_tier_not_advertised")
        checks.require("parser_service_tier_omission_stays_nonterminal", tierNotice.counts["provider_nonterminal_error_items"] == 1
            && tierNotice.counts["provider_error_events"] == 0 && tierNotice.details["provider_output_reason"] == "none")
        let incompleteNotices = [
            "Configured service tier `fast` is not advertised as supported for model `fixture`.",
            "Configured service tier `fast` will be omitted from requests.",
            "A setting is not advertised as supported for model `fixture` and will be omitted from requests."
        ]
        var incompleteAreUnknown = true
        for message in incompleteNotices {
            if try notice(message).details["provider_nonterminal_error_category"] != "unknown" { incompleteAreUnknown = false }
        }
        checks.require("parser_service_tier_notice_requires_complete_semantics", incompleteAreUnknown)
        checks.require("parser_other_notice_remains_unknown", try notice("Unidentified synthetic fixture notice.").details["provider_nonterminal_error_category"] == "unknown")
    }

    private actor NativeFixture {
        private(set) var calls = 0
        func response(_ data: Data) throws -> Data {
            guard let rpc = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = rpc["id"] else {
                throw Failure.protocolMismatch
            }
            let result: [String: Any]
            switch rpc["method"] as? String {
            case "initialize":
                result = ["protocolVersion": "2024-11-05", "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "Synthetic Sidekick fixture", "version": "1"]]
            case "ping": result = [:]
            case "tools/list":
                result = ["tools": [["name": "get_app_state", "description": "Read only a synthetic fixture. Does not inspect real apps, windows, pixels, files, or users.",
                    "inputSchema": ["type": "object", "properties": ["app": ["type": "string", "enum": ["SidekickBackendFixture"]]],
                        "required": ["app"], "additionalProperties": false],
                    "annotations": ["readOnlyHint": true]]]]
            case "tools/call":
                guard let params = rpc["params"] as? [String: Any], params["name"] as? String == "get_app_state",
                      let arguments = params["arguments"] as? [String: Any], Set(arguments.keys) == ["app"],
                      arguments["app"] as? String == "SidekickBackendFixture" else { throw Failure.protocolMismatch }
                calls += 1
                result = ["content": [["type": "text", "text": "Synthetic fixture ready. No real app state was accessed."]]]
            default: throw Failure.protocolMismatch
            }
            return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result], options: [.sortedKeys])
        }
    }

    @MainActor private static func processFixture(_ root: URL, checks: Checks) async throws {
        let store = try SidekickConversationStore(url: root.appendingPathComponent("process.sqlite"))
        let run = SidekickConversationRun(store: store, taskID: UUID(), generation: try store.generation)
        let interaction = SidekickInteraction(conversationRun: run) { _ in throw Failure.wrongQuestion }
        try store.reset()
        let pidFile = root.appendingPathComponent("fixture.pid")
        // Fixed synthetic output, no interpolated shell text, and exec keeps one owned PID.
        let script = #"""
        printf '%s\n' "$$" > "$1"
        printf '%s\n' '{"type":"item.started","item":{"id":"first","type":"mcp_tool_call","server":"fixture","tool":"read"}}' '{"type":"item.started","item":{"id":"second","type":"mcp_tool_call","server":"fixture","tool":"read"}}'
        exec /bin/sleep 30
        """#
        let began = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await SidekickInteraction.$current.withValue(interaction) {
                try await CodexCLI.executeAsync(binary: "/bin/sh", args: ["-c", script, "sidekick-fixture", pidFile.path],
                    stdinText: nil, cwd: root.path, timeout: 5, includeCustomProviderKey: false, onStdoutLine: { _ in })
            }
            checks.require("original_store_failure", false)
        } catch SidekickConversationStore.Failure.staleGeneration { checks.require("original_store_failure", true) }
        catch { checks.require("original_store_failure", false) }
        checks.require("bounded_child_cleanup", ProcessInfo.processInfo.systemUptime - began < 5)
        checks.require("drained_execution_guard", !interaction.hasActiveTools)
        checks.require("reset_history_not_recreated", try store.records().isEmpty)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(pidText), pid > 1 else { throw Failure.protocolMismatch }
        checks.require("owned_child_exited", kill(pid, 0) == -1 && errno == ESRCH)
        checks.counts["fixture_emitted_events"] = 2
    }
}
#endif
