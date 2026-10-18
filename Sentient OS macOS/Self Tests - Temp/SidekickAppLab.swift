#if DEBUG
// Actual signed-app prompt entry acceptance. The provider, gate, captures, native helper,
// coordinator and SQLite projection are production code; only app-owned test data/UI differ.
// prepare() MUST run before NSApplication/AppState or any application singleton is created.
import AppKit
import CryptoKit
import Darwin
import Foundation
import ObjectiveC
import SQLite3
import SwiftUI

private nonisolated final class SidekickFixtureDefaults: NSObject {
    nonisolated(unsafe) static var target: UserDefaults?
    @objc class func fixtureStandardDefaults() -> UserDefaults {
        guard let target else { preconditionFailure("Fixture defaults not installed") }
        return target
    }
}

@MainActor enum SidekickAppLab {
    private static let capability = "SENTIENT_SIDEKICK_APP_LAB_DEBUG_V1"
    private enum Failure: String, Error {
        case configuration, isolation, seed, migration, readiness, admission, taskTimeout
        case taskFailed, questionTimeout, questionContract, actionVerification, aborted, cleanup, receipt
        case compaction, contextVerification
    }
    private struct Configuration {
        let root: URL
        let suite: String
        let nonce: String
        let provider: ModelBackend
        let stage: String
        let defaults: UserDefaults
        let legacy: [[String: Any]]
        let memory: String
    }
    private static var configuration: Configuration?
    private static var originalDefaults: UserDefaults?
    private static var app: AppState?
    private static var fixture: ActionFixture?
    private static var checks: [String: Bool] = [:]
    private static var tasks: [[String: Any]] = []
    private static var evidence: [String: Any] = [:]
    private static let malformed = Data("SIDEKICK_MIGRATION_NOT_JSON\n".utf8)

    /// No real preferences are copied. The only original-domain read is a fresh synthetic
    /// sentinel. The replacement stays installed until process exit, including late callbacks.
    static func prepare() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SENTIENT_SELFTEST"] == "sidekickapp", CommandLine.arguments.count == 1,
              let path = env["LAB_SIDEKICK_ROOT"], path.hasPrefix("/"),
              let stage = env["LAB_SIDEKICK_STAGE"], ["seed", "migration_failure", "repair", "exercise", "reopen", "compaction", "compaction_reopen", "ui", "ui-clear"].contains(stage),
              let selected = env["LAB_SIDEKICK_PROVIDER"], let provider = ModelBackend(rawValue: selected), provider != .custom else { throw Failure.configuration }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard root == root.resolvingSymlinksInPath(), root.lastPathComponent.hasPrefix("sentient-sidekick-app-"),
              try String(contentsOf: root.appendingPathComponent(".sidekick-app-fixture"), encoding: .utf8) == "1\n",
              let owner = try FileManager.default.attributesOfItem(atPath: root.path)[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as? [String: Any],
              manifest["schema"] as? Int == 1, let nonce = manifest["nonce"] as? String,
              UUID(uuidString: nonce)?.uuidString.lowercased() == nonce,
              let suite = manifest["suite"] as? String, suite == "ai.sentient.sidekick-app." + nonce,
              manifest["provider"] as? String == selected,
              let defaults = UserDefaults(suiteName: suite),
              let migration = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("migration-fixture.json"))) as? [String: Any],
              let legacy = migration["legacy_history"] as? [[String: Any]], legacy.count == 7,
              let memory = migration["memory_text"] as? String else { throw Failure.configuration }
        let canonical = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SentientOS/Private Codex", isDirectory: true).resolvingSymlinksInPath()
        guard let runtime = env["SENTIENT_CODEX_RUNTIME_ROOT"], URL(fileURLWithPath: runtime).resolvingSymlinksInPath() == canonical,
              let vault = env["SENTIENT_VAULT_ROOT"], URL(fileURLWithPath: vault).standardizedFileURL.path == root.appendingPathComponent("vault", isDirectory: true).path else { throw Failure.isolation }
        if stage == "seed" { defaults.set(nonce, forKey: "lab.fixture.nonce") }
        guard defaults.string(forKey: "lab.fixture.nonce") == nonce else { throw Failure.isolation }
        let sentinel = "lab.fixture.proof." + nonce
        let original = UserDefaults.standard
        guard original.object(forKey: sentinel) == nil,
              let getter = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)),
              let replacement = class_getClassMethod(SidekickFixtureDefaults.self, #selector(SidekickFixtureDefaults.fixtureStandardDefaults)) else { throw Failure.isolation }
        originalDefaults = original
        SidekickFixtureDefaults.target = defaults
        method_setImplementation(getter, method_getImplementation(replacement))
        guard UserDefaults.standard === defaults else { throw Failure.isolation }
        UserDefaults.standard.set(nonce, forKey: sentinel)
        guard UserDefaults.standard === defaults, UserDefaults.standard.string(forKey: sentinel) == nonce,
              original.object(forKey: sentinel) == nil else { throw Failure.isolation }
        configuration = Configuration(root: root, suite: suite, nonce: nonce, provider: provider,
            stage: stage, defaults: defaults, legacy: legacy, memory: memory)
        checks["process_local_defaults_isolated"] = true
        checks["canonical_runtime_in_place"] = CodexRuntime.root.resolvingSymlinksInPath() == canonical
        guard checks["canonical_runtime_in_place"] == true else { throw Failure.isolation }
    }

    nonisolated static func preparationFailed() {
        FileHandle.standardError.write(Data("Sidekick app fixture configuration or isolation failed.\n".utf8))
    }

    static func run() async -> Int32 {
        guard let c = configuration else { preparationFailed(); return 1 }
        var receipt: [String: Any] = ["schema_version": 1, "stage": c.stage, "provider": c.provider.rawValue,
            "suite": c.suite, "baseline_legacy_count": c.legacy.count, "lab_capability": capability]
        var failed = false
        do {
            switch c.stage {
            case "seed": try seed(c)
            case "repair": try repair(c)
            case "migration_failure": try await migrationFailure(c)
            case "exercise": try await exercise(c)
            case "reopen": try reopen(c)
            case "compaction": try await compaction(c)
            case "compaction_reopen": try compactionReopen(c)
            case "ui-clear":
                let state = AppState(); app = state
                checks.merge(try await SidekickUILab.runClearChat(app: state, root: c.root)) { _, new in new }
            case "ui":
                let state = AppState(); app = state
                checks.merge(try await SidekickUILab.run(app: state, root: c.root)) { _, new in new }
            default: throw Failure.configuration
            }
        } catch {
            failed = true
            receipt["failure"] = (error as? Failure)?.rawValue ?? "execution_failure"
            receipt["reason"] = CodexFailureReason.classify(error).rawValue
            if c.stage.hasPrefix("ui") {
                receipt["ui_failure"] = (error as? SidekickUILab.Failure)?.rawValue ?? "system_or_native_fixture"
                receipt["ui_error_domain"] = (error as NSError).domain
                receipt["ui_error_code"] = (error as NSError).code
                receipt["ui_screen_locked_at_failure"] = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
            }
        }
        if let app {
            checks["owned_work_drained"] = await app.commandCoordinator.run.stopAndDrain()
            app.commandCoordinator.run.conversation.beginMaintenance()
            await app.commandCoordinator.run.conversation.drainBackgroundWork()
            if let store = app.commandCoordinator.run.conversation.store {
                do {
                    receipt["generation"] = try store.generation.uuidString
                    receipt["event_count"] = try allRecords(store).count
                    receipt["latest_sequence"] = try store.latestSequence
                    if c.stage.hasPrefix("compaction") {
                        receipt["event_sha256"] = try recordDigest(allRecords(store))
                        receipt["final_summaries"] = try store.summaries(limit: 500).map(summaryReceipt)
                    }
                } catch { failed = true }
            }
        }
        if let fixture {
            checks["fixture_not_aborted"] = !fixture.aborted
            // The hidden nonce is first emitted to the receipt only after execution ends.
            receipt["observed_action"] = ["kind": "native_text_field_and_button", "expected_text": fixture.expectedText,
                "observed_text": fixture.input.stringValue, "action_count": fixture.actionCount,
                "revealed_token": fixture.actionCount > 0 ? fixture.revealedToken : ""]
            fixture.close()
        }
        let memoryURL = c.root.appendingPathComponent("support/Sidekick/SidekickMemory.md")
        if let data = try? Data(contentsOf: memoryURL) { receipt["memory_sha256"] = digest(data) }
        checks["fixture_defaults_synchronized"] = c.defaults.synchronize()
            && UserDefaults.standard === c.defaults
            && UserDefaults(suiteName: c.suite)?.string(forKey: "lab.fixture.nonce") == c.nonce
        checks["original_defaults_sentinel_untouched"] = originalDefaults?.object(forKey: "lab.fixture.proof." + c.nonce) == nil
        receipt.merge(evidence) { _, new in new }
        receipt["tasks"] = tasks
        receipt["checks"] = checks
        receipt["passed"] = !failed && !checks.isEmpty && checks.values.allSatisfy { $0 }
        do {
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: c.root.appendingPathComponent(c.stage + "-receipt.json"), options: .atomic)
            let summary: [String: Any] = ["lab": "sidekick_app", "stage": c.stage, "provider": c.provider.rawValue,
                "passed": receipt["passed"]!, "checks": checks.count, "tasks": tasks.count]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) + Data([10]))
        } catch { preparationFailed(); return 1 }
        return receipt["passed"] as? Bool == true ? 0 : 1
    }

    private static func seed(_ c: Configuration) throws {
        guard !FileManager.default.fileExists(atPath: c.root.appendingPathComponent("support/Sidekick/Conversation.sqlite").path),
              !FileManager.default.fileExists(atPath: c.root.appendingPathComponent("support/Sidekick/SidekickMemory.md").path) else { throw Failure.seed }
        c.defaults.set(try JSONSerialization.data(withJSONObject: c.legacy, options: [.sortedKeys]), forKey: SidekickHistory.key)
        c.defaults.set(c.memory, forKey: CustomInstructions.sidekickKey)
        c.defaults.set(true, forKey: AppState.onboardingKey)
        c.defaults.set(true, forKey: ComputerUseGate.micSpeechOfferedKey) // optional voice was already offered; required grants remain real
        c.defaults.set(c.provider.rawValue, forKey: ModelBackend.key)
        c.defaults.set(false, forKey: CodexAuth.kbOnlyKey)
        checks["legacy_source_seeded"] = c.defaults.data(forKey: SidekickHistory.key) != nil
        checks["memory_source_exact"] = c.defaults.string(forKey: CustomInstructions.sidekickKey)?.utf8.elementsEqual(c.memory.utf8) == true
        checks["new_store_not_created"] = !FileManager.default.fileExists(atPath: c.root.appendingPathComponent("support/Sidekick/Conversation.sqlite").path)
        checks["memory_file_not_created"] = !FileManager.default.fileExists(atPath: c.root.appendingPathComponent("support/Sidekick/SidekickMemory.md").path)
    }

    private static func repair(_ c: Configuration) throws {
        let db = c.root.appendingPathComponent("support/Sidekick/Conversation.sqlite")
        let before = try Data(contentsOf: db)
        guard c.defaults.data(forKey: SidekickHistory.key) == malformed else { throw Failure.migration }
        c.defaults.set(try JSONSerialization.data(withJSONObject: c.legacy, options: [.sortedKeys]), forKey: SidekickHistory.key)
        checks["only_legacy_source_repaired"] = try Data(contentsOf: db) == before
        checks["legacy_source_restored"] = c.defaults.data(forKey: SidekickHistory.key) != malformed
        checks["memory_source_untouched"] = c.defaults.string(forKey: CustomInstructions.sidekickKey)?.utf8.elementsEqual(c.memory.utf8) == true
    }

    private static func migrationFailure(_ c: Configuration) async throws {
        c.defaults.set(malformed, forKey: SidekickHistory.key)
        c.defaults.synchronize()
        let state = AppState(); app = state
        let coordinator = state.commandCoordinator
        checks["invalid_history_visible_error"] = coordinator.run.conversation.storageError != nil
        coordinator.submit("Synthetic migration failure must prevent this request from starting.", mode: .computer, source: .promptBar)
        await Task.yield()
        checks["invalid_history_blocks_run"] = !coordinator.run.isRunning && coordinator.run.interaction == nil
        checks["invalid_source_preserved"] = c.defaults.data(forKey: SidekickHistory.key) == malformed
        let db = c.root.appendingPathComponent("support/Sidekick/Conversation.sqlite")
        checks["invalid_migration_zero_events"] = try scalar(db, "SELECT COUNT(*) FROM events") == 0
        checks["invalid_migration_not_consumed"] = try scalar(db, "SELECT legacy_imported FROM state WHERE singleton=1") == 0
        checks["invalid_migration_memory_not_created"] = !FileManager.default.fileExists(atPath: c.root.appendingPathComponent("support/Sidekick/SidekickMemory.md").path)
    }

    private static func reopen(_ c: Configuration) throws {
        let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: c.root.appendingPathComponent("exercise-receipt.json"))) as? [String: Any] ?? [:]
        let state = AppState(); app = state
        guard let store = state.commandCoordinator.run.conversation.store else { throw Failure.migration }
        checks["reopen_generation_unchanged"] = try store.generation.uuidString == previous["generation"] as? String
        checks["reopen_sequence_unchanged"] = try store.latestSequence == (previous["latest_sequence"] as? NSNumber)?.int64Value
        checks["reopen_event_count_unchanged"] = try allRecords(store).count == previous["event_count"] as? Int
        checks["reopen_legacy_source_absent"] = c.defaults.data(forKey: SidekickHistory.key) == nil
        let memory = try SidekickInstructionStore.read()
        let editedExpectation = c.root.appendingPathComponent("reopen-memory-expected.txt")
        if FileManager.default.fileExists(atPath: editedExpectation.path) {
            checks["reopen_file_edit_authoritative"] = try Data(contentsOf: editedExpectation) == Data(memory.text.utf8)
        } else {
            checks["reopen_memory_unchanged"] = digest(Data(memory.text.utf8)) == previous["memory_sha256"] as? String
        }
        checks["reopen_no_active_task"] = !state.commandCoordinator.run.isRunning
    }

    private static func exercise(_ c: Configuration) async throws {
        let state = AppState(); app = state
        let coordinator = state.commandCoordinator
        guard let store = coordinator.run.conversation.store, coordinator.run.conversation.storageError == nil else { throw Failure.migration }
        let baseline = try allRecords(store)
        checks["seven_legacy_tasks_imported"] = Set(baseline.map(\.event.taskID)).count == c.legacy.count
        checks["legacy_source_removed_after_import"] = c.defaults.data(forKey: SidekickHistory.key) == nil
        checks["legacy_memory_migrated_exact"] = try SidekickInstructionStore.read().text.utf8.elementsEqual(c.memory.utf8)
        guard ModelBackend.current == c.provider else { throw Failure.isolation }
        let view = ActionFixture(provider: c.provider, nonce: c.nonce, coordinator: coordinator)
        fixture = view
        view.show()
        for _ in 0..<30 where !NSApp.isActive { try await Task.sleep(for: .milliseconds(100)); NSApp.activate(ignoringOtherApps: true) }
        checks["visible_native_fixture"] = NSApp.isActive && view.window.isVisible
        checks["privacy_covers_all_displays"] = view.covers.count == NSScreen.screens.count
            && zip(view.covers, NSScreen.screens).allSatisfy { $0.0.isVisible && $0.0.frame.contains($0.1.frame) }
        await CodexSetup.shared.refreshInstalled()
        ComputerUseGate.shared.refresh()
        await ComputerUseGate.shared.awaitAutomationRefresh()
        checks["real_required_permissions_ready"] = ComputerUseGate.shared.allRequiredGranted
        checks["real_runtime_ready"] = CodexSetup.shared.computerUseReady
        guard checks["visible_native_fixture"] == true, checks["privacy_covers_all_displays"] == true,
              checks["real_required_permissions_ready"] == true,
              checks["real_runtime_ready"] == true else { throw Failure.readiness }
        let selector = Bundle.main.bundleURL.path
        evidence["native_app_selector"] = selector
        let actionPrompt = """
        Work only in this Sentient app instance at '\(selector)', window '\(view.window.title)'.
        Pass that exact absolute path as the app argument on EVERY native tool call that takes
        an app argument. Other Sentient instances may be running: do not use the display name
        'Sentient OS' or the bundle ID to select an app.
        Using native computer-use tools only, inspect that window, enter '\(view.expectedText)' in
        the Verification text field, then click Reveal exactly once. Read the random token that
        appears after the click. Do not use shell, scripts, files or another app for the action.
        In one final message_user answer with priority=high, report the entered text, revealed
        token, project codename from my earlier fixture conversation, and saved memory token.
        Do not change memory. Verify the window's resulting state before completing.
        """
        let action = try startTask(role: "action", prompt: actionPrompt, coordinator: coordinator)
        let beforeDuplicate = try store.latestSequence
        view.submit("DUPLICATE-MUST-NOT-EXECUTE: do not run a second task.", .computer)
        checks["busy_submit_keeps_original_run"] = coordinator.run.runID == action && coordinator.run.isRunning
        checks["busy_submit_does_not_record_duplicate"] = try store.latestSequence == beforeDuplicate
        try await waitForEnd(coordinator)
        let actionEvents = try store.records(taskID: action, limit: 500)
        try verifySuccess(actionEvents)
        let actionAnswer = try explicitAnswer(actionEvents)
        checks["native_field_verified"] = view.input.stringValue == view.expectedText
        checks["native_button_once"] = view.actionCount == 1
        checks["native_token_revealed"] = view.actionCount == 1 && view.tokenLabel.stringValue == view.revealedToken
        checks["action_answer_grounded"] = [view.expectedText, view.revealedToken, "ORBIT-CEDAR", "LANTERN-MINT"].allSatisfy(actionAnswer.event.text.contains)
        checks["action_answer_priority"] = actionAnswer.event.priority == .high
        checks["completed_real_native_action"] = actionEvents.contains {
            guard let activity = $0.event.activity else { return false }
            return activity.status == .completed && ["sentient_native.click", "sentient_native.set_value", "sentient_native.type_text", "sentient_native.press_key"].contains(activity.name)
        }
        checks["native_not_script_substitute"] = !actionEvents.contains {
            guard let name = $0.event.activity?.name.lowercased() else { return false }
            return name.contains("command_execution") || name.contains("exec_command") || name.contains("shell") || name == "bash"
        }
        let nativeCalls = actionEvents.compactMap(\.event.activity).filter {
            $0.name.hasPrefix("sentient_native.") && $0.name != "sentient_native.list_apps"
        }
        checks["native_calls_target_exact_fixture"] = !nativeCalls.isEmpty && nativeCalls.allSatisfy {
            guard let raw = $0.arguments,
                  let arguments = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            else { return false }
            return arguments["app"] as? String == selector
        }
        guard checks["native_field_verified"] == true, checks["native_button_once"] == true,
              checks["action_answer_grounded"] == true, checks["completed_real_native_action"] == true,
              checks["native_not_script_substitute"] == true,
              checks["native_calls_target_exact_fixture"] == true else { throw Failure.actionVerification }
        view.hideResultForHistoryChecks()
        checks["action_values_hidden_before_followup"] = view.input.isHidden && view.tokenLabel.isHidden
        try await Task.sleep(for: .milliseconds(100)) // let the real window server present the redacted fixture
        let follow = try startTask(role: "followup", prompt: "Using only saved conversation/history and current memory, tell me the exact text you entered and the random token you just reported. Also recall the earlier fixture project codename and saved memory token. Do not use native computer tools, screenshots, shell, scripts, files, or any other app to answer. Reply through message_user; do not change memory.", coordinator: coordinator)
        try await waitForEnd(coordinator)
        let followEvents = try store.records(taskID: follow, limit: 500); try verifySuccess(followEvents)
        let followAnswer = try explicitAnswer(followEvents)
        checks["followup_remembers_prior_answer"] = [view.expectedText, view.revealedToken, "ORBIT-CEDAR", "LANTERN-MINT"].allSatisfy(followAnswer.event.text.contains)
        checks["followup_history_only_no_native_or_shell"] = !followEvents.contains { record in
            guard let name = record.event.activity?.name.lowercased() else { return false }
            return name.contains("sentient_native") || ["command_execution", "exec_command", "shell", "write_stdin", "node_repl", "bash"].contains(where: name.contains)
        }
        let question = try startTask(role: "question_answer", prompt: "For a synthetic choice, ask me through ask_user whether to choose Left or Right, with exactly those two answer choices. Wait for my actual answer. Then use message_user to tell me the selected choice. Do nothing in any app and do not change memory.", coordinator: coordinator)
        let pending = try await waitForQuestion(coordinator)
        checks["answered_question_exact_choices"] = Set(pending.answers) == Set(["Left", "Right"])
        guard checks["answered_question_exact_choices"] == true, let left = pending.answers.firstIndex(of: "Left") else { throw Failure.questionContract }
        coordinator.run.recovery.answer(id: pending.id, choice: left)
        tasks[tasks.count - 1]["expected_answer"] = "Left"
        try await waitForEnd(coordinator)
        let questionEvents = try store.records(taskID: question, limit: 500); try verifySuccess(questionEvents)
        checks["real_recovery_answer_persisted"] = questionEvents.contains { $0.event.kind == .answer && $0.event.text == "Left" }
        let stopped = try startTask(role: "stopped", prompt: "For the next synthetic choice, ask me through ask_user whether to choose Left or Right, with exactly those choices. You must wait for my answer before continuing. Do not act in any app, choose for me, or change memory.", coordinator: coordinator, expected: "stopped")
        let stoppedQuestion = try await waitForQuestion(coordinator)
        checks["stopped_question_exact_choices"] = Set(stoppedQuestion.answers) == Set(["Left", "Right"])
        guard checks["stopped_question_exact_choices"] == true else { throw Failure.questionContract }
        coordinator.stop()
        checks["stop_drained_actual_run"] = await coordinator.run.stopAndDrain()
        let stoppedEvents = try store.records(taskID: stopped, limit: 500)
        checks["stopped_terminal_saved"] = stoppedEvents.contains { $0.event.kind == .taskFinished && $0.event.outcome == .stopped }
        checks["stop_did_not_invent_answer"] = !stoppedEvents.contains { $0.event.kind == .answer }
        let after = try startTask(role: "after_stop", prompt: "Without acting in any app, recap which choice was pending when I stopped your last task and whether I answered that pending question. Do not confuse an answer to an earlier question with an answer to the stopped question. Include the exact plain-text marker ANSWER_STATE: UNANSWERED if that stopped question received no answer, or ANSWER_STATE: ANSWERED if it did. Do not resume it or ask again. Answer through message_user.", coordinator: coordinator)
        try await waitForEnd(coordinator)
        let afterEvents = try store.records(taskID: after, limit: 500); try verifySuccess(afterEvents)
        let afterAnswer = try explicitAnswer(afterEvents).event.text.lowercased()
        checks["stopped_question_context_retained"] = afterAnswer.contains("left") && afterAnswer.contains("right")
        checks["stopped_question_not_conflated_with_prior_answer"] = afterAnswer.contains("answer_state: unanswered") && !afterAnswer.contains("answer_state: answered")
        coordinator.run.conversation.replyReference = .init(messageID: actionAnswer.event.id, selectedText: view.revealedToken)
        let reply = try startTask(role: "reply", prompt: "Explain what this quoted token came from. Repeat the exact quoted token. Use the conversation only, do not act in any app, and answer through message_user.", coordinator: coordinator)
        tasks[tasks.count - 1]["expected_quote"] = view.revealedToken
        tasks[tasks.count - 1]["source_message_id"] = actionAnswer.event.id
        try await waitForEnd(coordinator)
        let replyEvents = try store.records(taskID: reply, limit: 500); try verifySuccess(replyEvents)
        checks["selected_quote_reference_saved"] = replyEvents.contains { $0.event.kind == .userMessage && $0.event.reply?.selectedText == view.revealedToken && $0.event.reply?.messageID == actionAnswer.event.id }
        checks["selected_quote_answer_grounded"] = try explicitAnswer(replyEvents).event.text.contains(view.revealedToken)
        checks["memory_unchanged_by_tasks"] = try SidekickInstructionStore.read().text.utf8.elementsEqual(c.memory.utf8)
        checks["single_native_action_across_followups"] = view.actionCount == 1 && view.input.stringValue == view.expectedText
        checks["all_requests_from_prompt_bar"] = try allRecords(store).filter { $0.event.id.hasPrefix("request:") }.allSatisfy { $0.event.source == "promptBar" }
    }

    /// Crosses the real automatic threshold exclusively through ordinary prompt-bar submissions.
    /// The pending-work getter observes scheduling; this stage never invokes or cancels compaction.
    private static func compaction(_ c: Configuration) async throws {
        let oracle = try JSONSerialization.jsonObject(with: Data(contentsOf: c.root.appendingPathComponent("source-exercise-receipt.json"))) as? [String: Any] ?? [:]
        guard oracle["passed"] as? Bool == true,
              let action = oracle["observed_action"] as? [String: Any],
              let originalToken = action["revealed_token"] as? String, originalToken.hasPrefix("REVEALED-"),
              originalToken.count > 16 else { throw Failure.configuration }
        let state = AppState(); app = state
        let coordinator = state.commandCoordinator
        let conversation = coordinator.run.conversation
        guard let store = conversation.store, conversation.storageError == nil,
              ModelBackend.current == c.provider else { throw Failure.migration }
        let baseline = try allRecords(store)
        let generation = try store.generation
        let memory = try SidekickInstructionStore.read().text
        checks["compaction_baseline_thirteen_tasks"] = Set(baseline.map(\.event.taskID)).count == 13
        checks["compaction_baseline_no_summary"] = try store.summary == nil
        checks["compaction_baseline_user_memory_edit"] = memory.contains("USER-EDIT-KEEP-519")
        checks["compaction_baseline_original_answer"] = baseline.contains { $0.event.kind == .assistantMessage && $0.event.text.contains(originalToken) }
        evidence["baseline_event_count"] = baseline.count
        evidence["baseline_latest_sequence"] = baseline.last?.sequence ?? 0
        evidence["baseline_generation"] = generation.uuidString
        guard checks["compaction_baseline_thirteen_tasks"] == true,
              checks["compaction_baseline_no_summary"] == true,
              checks["compaction_baseline_user_memory_edit"] == true,
              checks["compaction_baseline_original_answer"] == true else { throw Failure.compaction }

        let view = ActionFixture(provider: c.provider, nonce: c.nonce, coordinator: coordinator)
        fixture = view; view.show(); view.hideResultForHistoryChecks()
        for _ in 0..<30 where !NSApp.isActive { try await Task.sleep(for: .milliseconds(100)); NSApp.activate(ignoringOtherApps: true) }
        // These are history-only submissions; ordinary Sidekick may run while another app
        // is foreground. Visible covers remain mandatory for the real display captures.
        evidence["fixture_application_active"] = NSApp.isActive
        evidence["fixture_window_visible"] = view.window.isVisible
        checks["visible_native_fixture"] = view.window.isVisible
        checks["privacy_covers_all_displays"] = view.covers.count == NSScreen.screens.count
            && zip(view.covers, NSScreen.screens).allSatisfy { $0.0.isVisible && $0.0.frame.contains($0.1.frame) }
        await CodexSetup.shared.refreshInstalled()
        ComputerUseGate.shared.refresh()
        await ComputerUseGate.shared.awaitAutomationRefresh()
        checks["real_required_permissions_ready"] = ComputerUseGate.shared.allRequiredGranted
        checks["real_runtime_ready"] = CodexSetup.shared.computerUseReady
        guard checks["visible_native_fixture"] == true, checks["privacy_covers_all_displays"] == true,
              checks["real_required_permissions_ready"] == true, checks["real_runtime_ready"] == true else { throw Failure.readiness }

        var warmups: [[String: Any]] = []
        for number in 1...3 {
            let role = "warmup_\(number)"
            let prompt = "Give me a short acknowledgment for check \(number). Don’t open or change any apps or memory."
            let id = try startTask(role: role, prompt: prompt, coordinator: coordinator)
            try await waitForEnd(coordinator)
            let records = try store.records(taskID: id, limit: 500)
            try verifySuccess(records); _ = try explicitAnswer(records)
            if number < 3 { try await waitForCompactionQuiescence(conversation, maximumSeconds: 30) }
            let count = Set(try allRecords(store).map(\.event.taskID)).count
            let noSummary = try store.summary == nil
            warmups.append(["role": role, "task_count": count, "no_summary": noSummary,
                "pending_compaction": conversation.hasPendingCompactionWorkForTesting])
            checks["\(role)_task_count"] = count == 13 + number
            checks["\(role)_explicit_answer"] = true
            checks["\(role)_history_only"] = historyOnly(records)
            if number < 3 {
                checks["\(role)_below_threshold_quiescent"] = !conversation.hasPendingCompactionWorkForTesting && noSummary
                guard checks["\(role)_below_threshold_quiescent"] == true else { throw Failure.compaction }
            }
        }
        evidence["warmup_evidence"] = warmups
        checks["automatic_worker_pending_before_held_request"] = conversation.hasPendingCompactionWorkForTesting
        checks["summary_not_installed_before_held_request"] = try store.summary == nil
        guard checks["automatic_worker_pending_before_held_request"] == true,
              checks["summary_not_installed_before_held_request"] == true else { throw Failure.compaction }

        let heldPrompt = "Ask me whether to Continue or Pause, with exactly those two choices, and wait for my answer. Do not send any other message until I answer. Once I answer, briefly confirm my choice. Do not open or change apps or memory."
        let held = try startTask(role: "held_question", prompt: heldPrompt, coordinator: coordinator)
        tasks[tasks.count - 1]["expected_answer"] = "Continue"
        guard let heldStart = try store.record(id: "start:\(held.uuidString)") else { throw Failure.admission }
        evidence["held_started_at_unix"] = heldStart.event.createdAt.timeIntervalSince1970
        checks["held_request_admitted_while_worker_pending"] = conversation.hasPendingCompactionWorkForTesting && coordinator.run.runID == held
        let pending = try await waitForQuestion(coordinator)
        checks["held_question_exact_choices"] = pending.answers.count == 2 && Set(pending.answers) == Set(["Continue", "Pause"])
        guard checks["held_question_exact_choices"] == true,
              let choice = pending.answers.firstIndex(of: "Continue") else { throw Failure.questionContract }
        coordinator.run.recovery.setFocused(true)
        let waitingSequence = try store.latestSequence
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        var accepted: SidekickConversationStore.Summary?
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !view.aborted, coordinator.run.isRunning, coordinator.run.runID == held,
                  coordinator.run.recovery.content?.question?.id == pending.id else { throw Failure.compaction }
            coordinator.run.recovery.setFocused(true)
            if let summary = try store.summary { accepted = summary; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let accepted else { throw Failure.compaction }
        evidence["first_summary"] = summaryReceipt(accepted)
        evidence["first_summary_observed_at_unix"] = Date().timeIntervalSince1970
        evidence["summary_observed_while_running"] = coordinator.run.isRunning && coordinator.run.runID == held
        evidence["summary_observed_while_waiting"] = coordinator.run.interaction?.isWaiting == true
            && coordinator.run.recovery.content?.question?.id == pending.id
        checks["summary_installed_during_foreground"] = accepted.createdAt >= heldStart.event.createdAt
            && evidence["summary_observed_while_running"] as? Bool == true
            && evidence["summary_observed_while_waiting"] as? Bool == true
        let atSummary = try allRecords(store)
        let covered = atSummary.filter { $0.sequence >= accepted.fromSequence && $0.sequence <= accepted.throughSequence }
        let coveredTasks = Set(covered.map(\.event.taskID))
        checks["summary_generation_and_completed_prefix"] = accepted.generation == generation && accepted.fromSequence == 1
            && accepted.throughSequence < heldStart.sequence && !coveredTasks.isEmpty
            && coveredTasks.allSatisfy { id in
                let records = covered.filter { $0.event.taskID == id }
                return records.contains { $0.event.kind == .taskStarted } && records.contains { $0.event.kind == .taskFinished }
                    && !atSummary.contains { $0.event.taskID == id && $0.sequence > accepted.throughSequence }
            }
        checks["automatic_compactor_no_chat_messages_while_waiting"] = !atSummary.contains {
            $0.sequence > waitingSequence && [.userMessage, .assistantMessage, .question, .answer, .taskStarted, .taskFinished].contains($0.event.kind)
        }
        checks["first_summary_original_records_unchanged"] = Array(atSummary.prefix(baseline.count)) == baseline
        checks["first_summary_memory_unchanged"] = try SidekickInstructionStore.read().text == memory
        guard checks["summary_installed_during_foreground"] == true,
              checks["summary_generation_and_completed_prefix"] == true,
              checks["automatic_compactor_no_chat_messages_while_waiting"] == true else { throw Failure.compaction }
        coordinator.run.recovery.answer(id: pending.id, choice: choice)
        coordinator.run.recovery.setFocused(false)
        try await waitForEnd(coordinator)
        let heldRecords = try store.records(taskID: held, limit: 500)
        try verifySuccess(heldRecords); _ = try explicitAnswer(heldRecords)
        checks["held_answer_continue_saved_once"] = heldRecords.filter { $0.event.kind == .answer && $0.event.text == "Continue" }.count == 1
        evidence["held_finished_at_unix"] = heldRecords.last(where: { $0.event.kind == .taskFinished })!.event.createdAt.timeIntervalSince1970

        let followPrompt = "Using only our saved conversation and current memory, tell me the project codename from my earlier fixture conversation, the original random token revealed by the native verification button, and the marker I later added by editing memory myself. Do not open or change apps, use native computer tools, run shell or scripts, or edit memory."
        let followup = try startTask(role: "followup", prompt: followPrompt, coordinator: coordinator)
        guard let context = coordinator.run.interaction?.historyContext, let jsonStart = context.firstIndex(of: "{"),
              let body = try JSONSerialization.jsonObject(with: Data(context[jsonStart...].utf8)) as? [String: Any],
              let segments = body["olderSegments"] as? [[String: Any]],
              let exchanges = body["recentExchanges"] as? [[String: Any]] else { throw Failure.contextVerification }
        evidence["followup_context"] = context
        checks["actual_followup_context_admits_summary"] = segments.contains {
            ($0["fromSequence"] as? NSNumber)?.int64Value == accepted.fromSequence
                && ($0["throughSequence"] as? NSNumber)?.int64Value == accepted.throughSequence
                && $0["summary"] as? String == accepted.text && $0["truncated"] as? Bool == false
        }
        checks["actual_followup_context_excludes_activity"] = exchanges.allSatisfy { $0["kind"] as? String != "activity" }
        checks["followup_prompt_does_not_supply_answers"] = !["ORBIT-CEDAR", originalToken, "USER-EDIT-KEEP-519"].contains(where: followPrompt.contains)
        guard checks["actual_followup_context_admits_summary"] == true,
              checks["actual_followup_context_excludes_activity"] == true else { throw Failure.contextVerification }
        try await waitForEnd(coordinator)
        let followRecords = try store.records(taskID: followup, limit: 500)
        try verifySuccess(followRecords)
        let answer = try explicitAnswer(followRecords)
        checks["followup_recalls_history_and_edited_memory"] = ["ORBIT-CEDAR", originalToken, "USER-EDIT-KEEP-519"].allSatisfy(answer.event.text.contains)
        checks["followup_history_only"] = historyOnly(followRecords)
        // Let all finish-triggered work settle on its own. Cancelling here would conceal a lost
        // reschedule when a foreground task ends during an earlier background compaction.
        try await waitForCompactionQuiescence(conversation, maximumSeconds: 180)
        let boundary = try store.compactionBoundary(keepingRecentTasks: 15)
        let finalSummary = try store.summary
        evidence["final_completed_boundary"] = boundary as Any? ?? NSNull()
        evidence["final_worker_pending"] = conversation.hasPendingCompactionWorkForTesting
        checks["automatic_compactor_naturally_caught_up"] = boundary != nil && finalSummary?.throughSequence == boundary
            && !conversation.hasPendingCompactionWorkForTesting
        let final = try allRecords(store)
        checks["compaction_final_eighteen_tasks"] = Set(final.map(\.event.taskID)).count == 18
        checks["compaction_original_records_unchanged"] = Array(final.prefix(baseline.count)) == baseline
        checks["compaction_memory_unchanged"] = try SidekickInstructionStore.read().text == memory
        let submitted = Set(tasks.compactMap { ($0["task_id"] as? String).flatMap(UUID.init(uuidString:)) })
        let newRecords = final.filter { $0.sequence > (baseline.last?.sequence ?? 0) }
        checks["compactor_created_no_extra_tasks"] = Set(newRecords.map(\.event.taskID)) == submitted && submitted.count == 5
        checks["all_new_requests_from_prompt_bar"] = newRecords.filter { $0.event.kind == .userMessage }.allSatisfy { $0.event.source == "promptBar" }
        checks["no_native_fixture_actions_during_compaction"] = view.actionCount == 0
        guard checks["automatic_compactor_naturally_caught_up"] == true else { throw Failure.compaction }
    }

    private static func compactionReopen(_ c: Configuration) throws {
        let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: c.root.appendingPathComponent("compaction-receipt.json"))) as? [String: Any] ?? [:]
        guard previous["passed"] as? Bool == true else { throw Failure.receipt }
        let state = AppState(); app = state
        let conversation = state.commandCoordinator.run.conversation
        guard let store = conversation.store, conversation.storageError == nil else { throw Failure.migration }
        checks["reopen_generation_unchanged"] = try store.generation.uuidString == previous["generation"] as? String
        checks["reopen_sequence_unchanged"] = try store.latestSequence == (previous["latest_sequence"] as? NSNumber)?.int64Value
        checks["reopen_event_count_unchanged"] = try allRecords(store).count == previous["event_count"] as? Int
        checks["reopen_original_records_unchanged"] = try recordDigest(allRecords(store)) == previous["event_sha256"] as? String
        let summaries = try store.summaries(limit: 500).map(summaryReceipt)
        let priorSummaries = previous["final_summaries"] as? [[String: Any]] ?? []
        checks["reopen_summary_segments_unchanged"] = !summaries.isEmpty
            && NSDictionary(dictionary: ["segments": summaries]).isEqual(to: ["segments": priorSummaries])
        checks["reopen_memory_file_unchanged"] = try digest(Data(SidekickInstructionStore.read().text.utf8)) == previous["memory_sha256"] as? String
        checks["reopen_legacy_source_absent"] = c.defaults.data(forKey: SidekickHistory.key) == nil
        checks["reopen_no_active_task_or_worker"] = !state.commandCoordinator.run.isRunning && !conversation.hasPendingCompactionWorkForTesting
    }

    private static func waitForCompactionQuiescence(_ conversation: SidekickConversation, maximumSeconds: Double) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + maximumSeconds
        while conversation.hasPendingCompactionWorkForTesting, ProcessInfo.processInfo.systemUptime < deadline {
            if fixture?.aborted == true { throw Failure.aborted }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !conversation.hasPendingCompactionWorkForTesting else { throw Failure.compaction }
    }
    private static func summaryReceipt(_ summary: SidekickConversationStore.Summary) -> [String: Any] {
        ["from_sequence": summary.fromSequence, "through_sequence": summary.throughSequence,
         "text": summary.text, "created_at_unix": summary.createdAt.timeIntervalSince1970,
         "generation": summary.generation.uuidString]
    }
    private static func recordDigest(_ records: [SidekickConversationStore.Record]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try digest(encoder.encode(records))
    }
    private static func historyOnly(_ records: [SidekickConversationStore.Record]) -> Bool {
        !records.contains { record in
            guard let name = record.event.activity?.name.lowercased() else { return false }
            return name.contains("sentient_native") || ["command_execution", "exec_command", "shell", "write_stdin", "node_repl", "bash"].contains(where: name.contains)
        }
    }

    private static func startTask(role: String, prompt: String, coordinator: CommandCoordinator, expected: String = "success") throws -> UUID {
        guard !coordinator.run.isRunning, let fixture else { throw Failure.admission }
        guard !fixture.aborted else { throw Failure.aborted }
        fixture.submit(prompt, .computer) // same action called by the real SidekickComposer
        let id = coordinator.run.runID
        tasks.append(["role": role, "task_id": id.uuidString, "request": prompt, "expected_outcome": expected])
        guard coordinator.run.isRunning else { throw Failure.admission }
        return id
    }
    private static func waitForEnd(_ coordinator: CommandCoordinator) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while coordinator.run.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            guard fixture?.aborted != true else { throw Failure.aborted }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard fixture?.aborted != true else { throw Failure.aborted }
        if coordinator.run.isRunning { coordinator.stop(); _ = await coordinator.run.stopAndDrain(); throw Failure.taskTimeout }
    }
    private static func waitForQuestion(_ coordinator: CommandCoordinator) async throws -> SidekickQuestion {
        let deadline = ProcessInfo.processInfo.systemUptime + 150
        while coordinator.run.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            guard fixture?.aborted != true else { throw Failure.aborted }
            if let question = coordinator.run.recovery.content?.question { return question }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard fixture?.aborted != true else { throw Failure.aborted }
        throw Failure.questionTimeout
    }
    private static func verifySuccess(_ records: [SidekickConversationStore.Record]) throws {
        guard records.filter({ $0.event.kind == .taskFinished }).count == 1,
              records.last(where: { $0.event.kind == .taskFinished })?.event.outcome == .success else { throw Failure.taskFailed }
    }
    private static func explicitAnswer(_ records: [SidekickConversationStore.Record]) throws -> SidekickConversationStore.Record {
        guard let answer = records.last(where: { $0.event.kind == .assistantMessage && $0.event.messageKind == .answer }),
              !answer.event.id.hasPrefix("fallback:") else { throw Failure.taskFailed }
        return answer
    }
    private static func allRecords(_ store: SidekickConversationStore) throws -> [SidekickConversationStore.Record] {
        var result: [SidekickConversationStore.Record] = [], cursor: Int64 = 0
        while true {
            let page = try store.records(after: cursor, limit: 500)
            result += page
            guard let last = page.last else { return result }
            cursor = last.sequence
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func scalar(_ url: URL, _ sql: String) throws -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw Failure.migration }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.migration }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.migration }
        return sqlite3_column_int64(statement, 0)
    }

    private final class ActionFixture: NSObject, NSWindowDelegate {
        let window: NSWindow
        var covers: [NSWindow] = []
        let input = NSTextField(string: "")
        let tokenLabel = NSTextField(labelWithString: "Token is hidden until Reveal is clicked.")
        let expectedText: String
        private(set) var actionCount = 0
        private(set) var revealedToken = ""
        private(set) var aborted = false
        private let hiddenToken = "REVEALED-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        private let abortRun: () -> Void
        private var revealButton: NSButton?
        private var closingForCleanup = false
        private var escapeMonitor: Any?
        let submit: (String, AgentMode) -> Void
        private let presentation: SidekickPresentation
        init(provider: ModelBackend, nonce: String, coordinator: CommandCoordinator) {
            expectedText = "SIDEKICK-\(provider.rawValue)-VERIFIED"
            let presentation = SidekickPresentation()
            self.presentation = presentation
            submit = { text, _ in
                coordinator.run.conversation.draft = text
                SidekickComposer.sendDraft(coordinator: coordinator, presentation: presentation)
            }
            abortRun = { [weak coordinator] in coordinator?.stop() }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 470),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            super.init()
            window.title = "Sidekick native acceptance " + String(nonce.prefix(8))
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let title = NSTextField(labelWithString: "Synthetic native computer-use fixture")
            title.textColor = .white; title.font = .systemFont(ofSize: 22, weight: .semibold)
            title.frame = NSRect(x: 30, y: 365, width: 800, height: 36)
            let escape = NSTextField(labelWithString: "Esc or close to stop test")
            escape.textColor = .systemYellow; escape.font = .systemFont(ofSize: 15, weight: .medium)
            escape.frame = NSRect(x: 30, y: 415, width: 800, height: 25)
            let caption = NSTextField(labelWithString: "Verification")
            caption.textColor = .white; caption.frame = NSRect(x: 30, y: 315, width: 180, height: 24)
            input.frame = NSRect(x: 30, y: 270, width: 610, height: 36)
            input.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
            input.placeholderString = "Enter the requested verification text"
            input.setAccessibilityLabel("Verification")
            input.setAccessibilityIdentifier("sidekick-fixture-verification")
            let button = NSButton(title: "Reveal", target: self, action: #selector(reveal))
            revealButton = button
            button.frame = NSRect(x: 660, y: 270, width: 150, height: 36)
            button.bezelStyle = .rounded
            button.setAccessibilityIdentifier("sidekick-fixture-reveal")
            tokenLabel.frame = NSRect(x: 30, y: 190, width: 800, height: 58)
            tokenLabel.textColor = .white; tokenLabel.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
            tokenLabel.maximumNumberOfLines = 2
            tokenLabel.setAccessibilityLabel("Revealed token")
            let host = NSHostingView(rootView: PromptHost(coordinator: coordinator, presentation: presentation))
            host.frame = NSRect(x: 25, y: 24, width: 810, height: 144)
            for view in [title, escape, caption, input, button, tokenLabel, host] { window.contentView?.addSubview(view) }
        }
        @objc private func reveal() {
            actionCount += 1
            guard input.stringValue == expectedText else { tokenLabel.stringValue = "Verification text does not match; token remains hidden."; return }
            revealedToken = hiddenToken
            tokenLabel.stringValue = hiddenToken
        }
        func hideResultForHistoryChecks() {
            // End AppKit's shared field editor first; merely hiding NSTextField can leave its
            // editor's text exposed. Keep model-independent values intact for the final receipt.
            window.endEditing(for: nil)
            window.makeFirstResponder(nil)
            input.isHidden = true; input.setAccessibilityElement(false)
            tokenLabel.isHidden = true; tokenLabel.setAccessibilityElement(false)
            revealButton?.isHidden = true; revealButton?.setAccessibilityElement(false)
            let completed = NSTextField(labelWithString: "Native fixture complete; followups use saved conversation")
            completed.textColor = .white; completed.font = .systemFont(ofSize: 19, weight: .medium)
            completed.frame = NSRect(x: 30, y: 230, width: 800, height: 65)
            completed.maximumNumberOfLines = 2
            window.contentView?.addSubview(completed)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func show() {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard event.keyCode == 53 else { return event }
                    self?.abort(); return nil
                }
            }
            for screen in NSScreen.screens {
                let cover = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                cover.isReleasedWhenClosed = false; cover.backgroundColor = .black; cover.isOpaque = true
                cover.level = .screenSaver; cover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                cover.title = "Sidekick fixture privacy cover"
                cover.orderFrontRegardless(); covers.append(cover)
            }
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        private func abort() {
            guard !closingForCleanup else { return }
            aborted = true
            finishClose(closeWindow: true)
            abortRun()
        }
        func windowWillClose(_ notification: Notification) {
            guard !closingForCleanup else { return }
            aborted = true
            finishClose(closeWindow: false)
            abortRun()
        }
        private func finishClose(closeWindow: Bool) {
            guard !closingForCleanup else { return }
            closingForCleanup = true
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
            covers.forEach { $0.close() }; covers.removeAll()
            if closeWindow { window.close() }
        }
        func close() { finishClose(closeWindow: true) }
    }
    private struct PromptHost: View {
        @Bindable var coordinator: CommandCoordinator
        let presentation: SidekickPresentation
        var body: some View {
            SidekickComposer(coordinator: coordinator, presentation: presentation, isPresented: false, onAccepted: {})
                .padding(8).background(Color.black).preferredColorScheme(.dark)
        }
    }
}
#endif
