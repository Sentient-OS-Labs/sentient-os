#!/usr/bin/env python3
"""Exercise complete production Sidekick lifecycle types with inert providers/platforms.
Uses isolated SQLite/defaults, real Swift Tasks/recovery continuations and cancellation barriers.
No source extraction, app/UI launch, real provider, screen capture, credentials, or telemetry.
"""
from pathlib import Path
import subprocess
import tempfile
import os

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"
SUPPORT = r'''
import Foundation
import Observation
import Synchronization

nonisolated enum ModelBackend: String, Sendable {
    case chatgpt, claude, custom
    @TaskLocal static var runOverride: Self?
    static var current: Self { runOverride ?? .claude }
}
@MainActor enum PersonalSetupProgress { static func recordSuccessfulTask() {} }
nonisolated enum CodexAuth {
    struct Plan { let raw: String }
    static func currentPlan() -> Plan? { nil }
    static var assertedPlus: Bool { false }
}
nonisolated enum AgentMode: Sendable { case computer; var label: String { "computer" }; var promptPhrase: String { "computer tools" } }
nonisolated struct PreparedAction: Sendable { }
nonisolated enum SidekickCardContext { static func promptBlock(for cards: [PreparedAction]) -> String { "" } }
@MainActor enum Fixture {
    static var root = URL(fileURLWithPath: "/fixture-must-be-injected")
    static var gateCalls = 0, screenshots = 0, providerCalls = 0
    static var response = "Fixture answer\nSTATUS: DONE — fixture complete"
    static var provider: (@MainActor (String) async throws -> String)?
}
extension URL { nonisolated static var sentientSupport: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURE_PERMISSION_SUPPORT"]!) } }
@MainActor final class SafeAppRelaunch { static let shared = SafeAppRelaunch(); var isApplicationTerminating = false }
@MainActor final class ComputerUseGate {
    static let shared = ComputerUseGate()
    nonisolated struct SetupCancelled: Error { }
    func waitUntilReady() async throws { Fixture.gateCalls += 1; try Task.checkCancellation() }
}
@MainActor enum ScreenCapture {
    static func grab() async -> [URL] { Fixture.screenshots += 1; return [] }
    static func discard(_ shots: [URL]) { }
}
nonisolated enum SlackConnector { enum Operation: Sendable { case write } }
nonisolated enum OutlookMailConnector { static let slug = "outlook-mail"; enum Operation: Sendable { case write } }
nonisolated enum OutlookCalendarConnector { static let slug = "outlook-calendar"; enum Operation: Sendable { case write } }
@MainActor enum CommandRouter {
    enum Route { case computer, connector(String, String, SlackConnector.Operation?, OutlookMailConnector.Operation?, OutlookCalendarConnector.Operation?) }
    static var isActive = false
    static func route(_ task: String, cardContext: String, standingInstructions: String) async -> Route { .computer }
    static func recordOutcome(route: String, slug: String?, ms: Int, fellBack: Bool) { }
}
nonisolated enum CodexCLI {
    enum Effort: Sendable { case medium }
    struct Invocation: Sendable {
        let prompt: String
        var feature = "", effort: Effort = .medium, webSearch = false
        var timeout: TimeInterval = 600
        var mcpActionServer: String?
        var slackOperation: SlackConnector.Operation?
        var outlookOperation: OutlookMailConnector.Operation?
        var outlookCalendarOperation: OutlookCalendarConnector.Operation?
        var imagePaths: [String] = []
    }
    struct Envelope: Sendable { let result: String }
    enum Availability: Sendable { case notInstalled, notWorking(String) }
    enum CLIError: Error {
        case timedOut, usageLimit, launchFailed, staleClient, badEnvelope, inputTooLarge
        case notAvailable(Availability), exitFailure(Int, String)
    }
}
@MainActor enum FrontierRun {
    static func runAgentCommand(_ prompt: String, imagePaths: [String], onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        Fixture.providerCalls += 1
        if let provider = Fixture.provider { return try await provider(prompt) }
        return Fixture.response
    }
    static func run(_ invocation: CodexCLI.Invocation, onLine: @escaping @Sendable (String) -> Void) async throws -> CodexCLI.Envelope {
        .init(result: try await runAgentCommand(invocation.prompt, imagePaths: [], onLine: onLine))
    }
}
nonisolated enum ConnectorRegistry { static func connectedServicesBlock() -> String { "" } }
nonisolated enum ConnectorClassifier { static func ensureClassified(slug: String) async { } }
nonisolated enum CodexTrigger: Sendable { case sidekick; @TaskLocal static var current: Self = .sidekick }
nonisolated enum VaultGenerator { static var vaultRoot: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURE_EMPTY_VAULT"]!) } }
@MainActor final class NetworkSnapshot {
    nonisolated static let didChange = Notification.Name("FixtureNetworkChanged")
    struct State { var status = "satisfied" }
    static let shared = NetworkSnapshot()
    var current = State()
}
nonisolated enum SidekickInstructionStore { struct Snapshot: Sendable { let text = "Fixture memory"; let readError: String? = nil; var promptBlock: String { text } } }
nonisolated enum CustomInstructions {
    static var sidekick: String { "Fixture memory" }
    static func sidekickSnapshot() -> SidekickInstructionStore.Snapshot { .init() }
}
nonisolated final class SidekickPersonalization: Sendable {
    struct Review: Sendable { enum Operation: Sendable { case read, write }; let operation: Operation; let markdown: String? }
    enum Failure: Error { case unavailable }
    init(snapshot: SidekickInstructionStore.Snapshot, taskID: UUID, request: String, retryGuidance: String?, onChange: @escaping @MainActor @Sendable (Bool) -> Void) { }
    var promptInstructions: String { "Fixture memory instructions" }
    func recordScreenshots(count: Int) { }
    func recordAnswer(_ id: UUID, text: String) { }
    func discardProposal() { }
    func finish(success: Bool) { }
    func stage(_ review: Review) async throws -> String { "Saved" }
    static func rejectionCode(_ error: Error) async -> String { "fixture_error" }
    func presentStagedUpdate() async throws { }
}
nonisolated final class SidekickTaskSummary: Sendable {
    static let promptInstructions = "Fixture telemetry contract"
    func discard() { }
    func finish(end: SidekickTaskEnd, source: String, method: String) { }
}
nonisolated enum SidekickToolServer { static let name = "sentient_recovery" }
nonisolated enum SidekickHistory {
    static func legacyEvents(defaults: UserDefaults) throws -> [SidekickConversationEvent] { [] }
    static func reset(defaults: UserDefaults) { }
}
nonisolated enum SidekickCompactor { static func compactIfNeeded(store: SidekickConversationStore) async throws { } }
@MainActor enum HomeWindowOpening { static func open() { fatalError("No UI opening in lifecycle tests") } }
nonisolated enum Diagnostics {
    struct Payload: Sendable { let event: String; let tags: [String:String]; let extra: [String:String]; let fingerprint: [String] }
    struct Operation: Sendable { init(_ name: StaticString) { } }
    @TaskLocal static var current: Operation?
    static func isCancellation(_ error: Error) -> Bool { error is CancellationError }
}
nonisolated enum DiagnosticHistory { static func recordError(_ payload: Diagnostics.Payload) { } }
nonisolated enum CrashReporting {
    enum Level { case info, warning }
    static func captureEvent(_ event: String, level: Level, tags: [String:String], extra: [String:String], fingerprint: [String], cooldown: TimeInterval, includeInformational: Bool = false) { }
    static func diagnosticBreadcrumb(_ name: String, data: [String:String]) { }
}
nonisolated enum AgentRunDiagnostics {
    enum Reason: String {
        case appUnavailable, screenCapture, noWindows, staleTarget, permission, authentication, quota, timeout, connection
        case invalidArguments, unavailableTool, outputSchema, cancelled, unknown
        static func classify(_ value: String) -> Self { .unknown }
    }
}
nonisolated enum CodexFailureReason {
    case notLoggedIn, tokenExpired, refreshFailed, usageLimit, planDenied, modelNotFound, dns, tls, streamDisconnect
    case connectTimeout, http403, sandboxDenied, http5xx, timeoutOurs, staleClient, spawnFailed, screenCapture, noWindows, notInstalled, unknown
    static func classify(text: String) -> Self { .unknown }
}
nonisolated struct NativeComputerUseFailure: Error {
    enum Kind { case capture, noWindows, permission, connection, timeout, unknown }
    let kind: Kind
}
nonisolated enum ComputerUseStream { struct WindowUnavailable: Error { } }
nonisolated enum SlackActionEvidence { struct Failure: Error { } }
nonisolated enum OutlookActionEvidence { struct Failure: Error { } }
nonisolated enum OutlookCalendarActionEvidence { struct Failure: Error { } }
nonisolated enum CodexRuntime { struct Failure: Error { } }
nonisolated enum MCPSource { enum MCPError: Error { case noReadSurface, connectionChanged, invalidResponse, connectorAuth, toolFailure, other } }
nonisolated enum DirectMCPError: Error, LocalizedError {
    case timedOut, reconnectRequired, registrationExpired, accountSetupRequired, authorizationDenied, keychain, network
    case connectionChanged, noTools, policyUnavailable, invalidMetadata, invalidCallback, invalidResponse, tooLarge
    case unsupportedProvider, unsupportedRegistration, unconfirmedAction, http(Int), busy, duplicateLabel
    var errorDescription: String? { "Fixture direct connector error" }
}
nonisolated enum OpenAIComputerUse { enum RuntimeError: Error { case permissionRequired, launchFailed, incomplete } }
@MainActor enum ExecutorScoreboard {
    enum Outcome { case fired, failed, refused }
    static func record(method: String, source: String, outcome: Outcome, durationS: Double, statusPresent: Bool, errorClass: String?, error: Error?) { }
}
@MainActor enum Analytics {
    enum Tier { case extended }
    static func signal(_ name: String, parameters: [String:String], floatValue: Double?, tier: Tier = .extended) { }
}
nonisolated func Log(_ message: String) { }
nonisolated func ErrorLabel(_ error: Error) -> String { "Fixture error" }

actor Latch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signaled = true
        let waiting = waiters; waiters.removeAll(); waiting.forEach { $0.resume() }
    }
}
'''
TESTS = r'''
import Foundation
import SQLite3

@main @MainActor struct Tests {
    typealias Store = SidekickConversationStore
    typealias Event = SidekickConversationEvent
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { fatalError(label) }; checks += 1
    }
    static func raw(_ object: [String:Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    static func executeSQL(_ store: Store, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(store.url.path, &database) == SQLITE_OK, let database else { fatalError("fixture database open") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { fatalError("fixture database setup") }
    }
    static func eventually(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Lifecycle condition did not settle")
    }
    static func clearChat(root: URL, defaults: UserDefaults) async throws {
        let url = root.appendingPathComponent("clear-chat.sqlite")
        let conversation = SidekickConversation(url: url, defaults: defaults)
        let model = CommandRunModel(conversation: conversation)
        let store = conversation.store!
        model.adoptExternal(caption: "OLD_CHAT_REQUEST_SENTINEL", onStopRequest: {})
        let oldID = model.runID, oldInteraction = model.interaction!, oldGeneration = try store.generation
        let oldRecorder = oldInteraction.conversationRun!
        let messageID = try oldRecorder.message("OLD_CHAT_ANSWER_SENTINEL", kind: .answer, priority: .high)
        _ = try store.append(Event(taskID: oldID, kind: .activity, text: "OLD_CHAT_ACTIVITY_SENTINEL",
            activity: .init(toolID: "old-tool", name: "fixture", status: .completed)))
        model.completeExternal(.success, line: "Done", finalText: "OLD_CHAT_FINAL_SENTINEL", runID: oldID)
        try store.installSummary(generation: oldGeneration, throughSequence: store.latestSequence, text: "OLD_CHAT_SUMMARY_SENTINEL")
        try store.markRead(messageIDs: [messageID], expectedGeneration: oldGeneration)
        try store.markRead(throughSequence: store.latestSequence, expectedGeneration: oldGeneration)
        conversation.draft = "Old unsent draft"
        conversation.replyReference = .init(messageID: messageID)
        conversation.requestNavigation(messageID: messageID)
        try check(try !store.records().isEmpty && !store.summaries().isEmpty, "clear fixture includes durable history and summaries")
        try await model.clearChat(defaults: defaults)
        try check(try store.records().isEmpty && store.summaries().isEmpty && store.latestSequence == 0, "clear deletes messages, activities and every compacted segment")
        try check(try store.generation != oldGeneration && store.readThroughSequence == 0 && !store.needsLegacyImport, "clear rotates generation and resets receipts without reopening legacy import")
        try check(conversation.messages.isEmpty && conversation.unreadCount == 0 && conversation.attention == nil, "clear refreshes visible conversation and attention")
        try check(conversation.draft.isEmpty && conversation.replyReference == nil && conversation.destinationMessageID == nil && conversation.navigationRequest == nil, "clear drops unsent draft, quote and navigation references")
        try check(!model.isClearingChat && !model.isRunning && model.interaction == nil && model.runID != oldID, "clear releases run state and invalidates retained interaction")
        try check(model.statusLine.isEmpty && !model.recovery.isPending, "clear removes obsolete status and recovery UI")
        do { _ = try oldRecorder.message("Late old response", kind: .answer, priority: .high); fatalError("clear allowed old recorder") }
        catch { checks += 1 }
        do { try store.installSummary(generation: oldGeneration, throughSequence: 1, text: "Late old summary"); fatalError("clear allowed old summary") }
        catch Store.Failure.staleGeneration { checks += 1 }
        let reopened = SidekickConversation(url: url, defaults: defaults)
        try check(try reopened.store!.records().isEmpty && reopened.store!.summaries().isEmpty && reopened.generation == conversation.generation, "cleared conversation remains empty after reopen")
        reopened.beginMaintenance(); await reopened.drainBackgroundWork(); reopened.closeForUninstall()
        model.adoptExternal(caption: "New request after clearing", onStopRequest: {})
        let freshID = model.runID
        try check(model.isRunning && !(model.interaction?.historyContext.contains("OLD_CHAT_") ?? true), "next prompt contains no deleted history or compacted context")
        try check(model.interaction?.retryContext == "" && model.interaction?.instructionsSnapshot?.promptBlock == "Fixture memory", "next prompt keeps saved instructions and drops old retry guidance")
        try check(try store.records(taskID: freshID).allSatisfy { $0.event.reply == nil }, "next prompt does not link deleted messages")
        model.completeExternal(.success, line: "Done", runID: freshID)

        // Failed SQL deletion rolls back every table together and leaves the draft intact.
        try store.installSummary(generation: store.generation, throughSequence: store.latestSequence, text: "Summary to preserve on failure")
        conversation.draft = "Preserve failed-clear draft"
        let beforeFailure = try store.records(), summariesBeforeFailure = try store.summaries(), generationBeforeFailure = try store.generation
        try executeSQL(store, "CREATE TRIGGER fixture_reject_clear BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'fixture clear rejected'); END")
        do { try await model.clearChat(defaults: defaults); fatalError("failing reset reported success") }
        catch CommandRunModel.ClearChatFailure.storage { checks += 1 }
        try check(try store.records() == beforeFailure && store.summaries() == summariesBeforeFailure && store.generation == generationBeforeFailure, "failed clear rolls back messages and summary deletion without changing generation")
        try check(!model.isClearingChat && conversation.draft == "Preserve failed-clear draft", "failed clear releases its operation and keeps draft")
        try executeSQL(store, "DROP TRIGGER fixture_reject_clear")
        try check(conversation.beginMaintenance(), "failed clear releases maintenance")
        do { try await model.clearChat(defaults: defaults); fatalError("clear overlapped another teardown") }
        catch CommandRunModel.ClearChatFailure.busy { checks += 1 }
        try check(!model.isClearingChat && !conversation.beginMaintenance(), "rejected clear preserves another owner's maintenance")
        do { _ = try conversation.begin(request: "Still blocked", source: "fixture", taskID: UUID()); fatalError("rejected clear released maintenance") }
        catch { checks += 1 }
        conversation.endMaintenance()

        // A final failure retains an actionable retry closure until Clear consumes it.
        var retryCalls = 0
        model.adoptExternal(caption: "Failed prior task", onRetry: { _ in retryCalls += 1 }, onStopRequest: {})
        let failedID = model.runID
        model.completeExternal(.failed, line: "Choose another account", finalText: "OLD_RETRY_CONTEXT", runID: failedID)
        let retryPresentation = model.recovery.content!.id
        try await model.clearChat(defaults: defaults)
        model.recovery.answer(id: retryPresentation, text: "Retry old task")
        try check(retryCalls == 0 && !model.recovery.isPending && model.interaction == nil, "stale failure UI cannot retry a cleared request")
        try check(try store.latestSequence == 0, "stale retry does not recreate history")

        // Real recovery continuations and owned cleanup must finish before a clear commits.
        let cancelled = Latch(), cleanupAllowed = Latch()
        model.adoptExternal(caption: "Awaiting user before clear", onStopRequest: {})
        let activeID = model.runID, activeInteraction = model.interaction!
        let question = try SidekickQuestion(error: nil, question: "Should I continue?", answers: ["Continue", "Stop"])
        let work = Task { @MainActor in
            do { _ = try await activeInteraction.ask(question); fatalError("clear answered instead of cancelled") }
            catch { await cancelled.signal() }
            await cleanupAllowed.wait()
            model.completeExternal(.success, line: "Late done", finalText: "Late task result", runID: activeID)
        }
        model.ownExternalTask(work, cardID: "clear-fixture")
        try await eventually { model.recovery.isPending }
        let activeGeneration = try store.generation
        let clearing = Task { try await model.clearChat(defaults: defaults) }
        await cancelled.wait()
        try check(model.isClearingChat && model.isRunning && !model.recovery.isPending, "clear cancels question but retains task lock while cleanup drains")
        try check(try store.generation == activeGeneration && !store.records().isEmpty, "clear does not erase history before owned cleanup finishes")
        do { try await model.clearChat(defaults: defaults); fatalError("duplicate clear entered") }
        catch CommandRunModel.ClearChatFailure.busy { checks += 1 }
        do { _ = try conversation.begin(request: "No overlap", source: "fixture", taskID: UUID()); fatalError("clear allowed overlapping request") }
        catch { checks += 1 }
        let activeSequence = try store.latestSequence
        model.start("Blocked during clear", mode: .computer)
        model.adoptExternal(caption: "Blocked card", onStopRequest: {})
        model.startOnboardingDemo()
        try check(try model.runID == activeID && store.latestSequence == activeSequence, "all run front doors stay locked while clearing")
        await cleanupAllowed.signal(); await work.value; try await clearing.value
        try check(try store.records().isEmpty && store.generation != activeGeneration && !model.isClearingChat && !model.isRunning, "clear commits only after real owned cleanup finishes")
        model.recovery.answer(id: question.id, choice: 0)
        model.completeExternal(.failed, line: "Old completion", runID: activeID)
        model.externalPush("Old stream", runID: activeID)
        try check(try model.statusLine.isEmpty && !model.recovery.isPending && store.latestSequence == 0, "old answers, streams and terminal callbacks cannot revive cleared chat")
        #if DEBUG
        let calls = Fixture.providerCalls
        model.preventsTaskExecutionForUIFixture = true
        model.start("Preview must not launch", mode: .computer)
        model.adoptExternal(caption: "Preview card must not launch", onStopRequest: {})
        model.startOnboardingDemo()
        try check(try !model.isRunning && store.latestSequence == 0 && Fixture.providerCalls == calls, "UI fixture gate prevents provider and demo work without maintenance")
        try await model.clearChat(defaults: defaults)
        try check(try !model.isClearingChat && store.latestSequence == 0, "UI fixture can clear chat while execution remains blocked")
        model.preventsTaskExecutionForUIFixture = false
        #endif
        let beforeDemo = try store.latestSequence
        model.startOnboardingDemo()
        try check(model.isRunning && model.isDemo && model.onboardingDemoBeat == .read, "film demo starts without a provider or conversation task")
        model.advanceOnboardingDemo(.remember)
        try check(model.remembering == "Weekend plan", "real notch shows the remembered plan")
        model.advanceOnboardingDemo(.open)
        model.advanceOnboardingDemo(.remember)
        try check(model.remembering == nil && model.onboardingDemoBeat == .open, "late or reversed frame cannot rewind native narration")
        model.advanceOnboardingDemo(.confirmed)
        model.advanceOnboardingDemo(.reply)
        model.advanceOnboardingDemo(.done)
        try check(!model.isRunning && model.statusLine == "✓ done" && model.remembering == nil, "confirmed film completion ends and clears the memory bloom")
        model.advanceOnboardingDemo(.read)
        try check(try !model.isRunning && store.latestSequence == beforeDemo, "late film events never restart a run or enter chat history")
        try check(OnboardingRestaurantStory.beat(from: ["story": "restaurant-v2", "beat": "remember"]) == .remember, "known versioned film beat decodes")
        for body: Any in [["story": "recipe", "beat": "done"], ["story": "restaurant-v2", "beat": "execute"], ["story": "restaurant-v2", "beat": 4], "done"] {
            try check(OnboardingRestaurantStory.beat(from: body) == nil, "unrecognized film payload is inert")
        }
        model.startOnboardingDemo(); model.advanceOnboardingDemo(.remember); model.stop()
        try await eventually { !model.isRunning }
        model.advanceOnboardingDemo(.done)
        try check(model.onboardingDemoBeat == .remember && model.remembering == nil, "cancelled film cannot become a success")
        conversation.beginMaintenance(); await conversation.drainBackgroundWork(); conversation.closeForUninstall()
    }
    static func stoppedRunReadReceipts(root: URL, defaults: UserDefaults) async throws {
        for fullReset in [false, true] {
            let conversation = SidekickConversation(url: root.appendingPathComponent("stopped-receipts-\(fullReset).sqlite"), defaults: defaults)
            let model = CommandRunModel(conversation: conversation)
            let store = conversation.store!
            model.adoptExternal(caption: "A task stopped midway", onStopRequest: {
                model.completeExternal(.stopped, line: "Stopped", runID: model.runID)
            })
            let oldGeneration = try store.generation
            let visibleMessage = try model.interaction!.conversationRun!.message("Synthetic in-progress update", kind: .update, priority: .normal)
            conversation.refresh()
            try check(conversation.replyReference == nil, "stopped-receipt fixture never selects text or starts a reply")
            model.stop()
            let stopped = await model.stopAndDrain()
            try check(stopped, "stopped-receipt task drains before reset")
            if fullReset {
                // FactoryReset uses this production history reset under maintenance. Its
                // unrelated destructive services are covered by the reset orchestration suite.
                try check(conversation.beginMaintenance(), "full-reset receipt fixture owns maintenance")
                try conversation.reset(defaults: defaults)
                await conversation.drainBackgroundWork()
                conversation.endMaintenance()
            } else { try await model.clearChat(defaults: defaults) }
            let freshGeneration = try store.generation
            try check(oldGeneration != freshGeneration && conversation.replyReference == nil,
                      "reset replaces history without creating an explicit reply")
            // Reproduce an old row's delayed visibility callback borrowing the refreshed
            // conversation generation. This is read-receipt work, never a user submission.
            conversation.markRead(messageIDs: [visibleMessage], generation: freshGeneration)
            try check(conversation.storageError == nil,
                      "stopped run then reset must not show a reply warning for a late read receipt")
            conversation.markRead(messageIDs: [visibleMessage], generation: oldGeneration)
            let freshMessage = try store.append(Event(taskID: UUID(), kind: .assistantMessage, text: "New conversation answer"))
            conversation.refresh()
            conversation.markRead(messageIDs: [freshMessage.event.id], generation: oldGeneration)
            try check(try store.unreadCount == 1, "old-generation receipts cannot mark fresh messages read")
            conversation.markRead(messageIDs: [freshMessage.event.id], generation: freshGeneration)
            try check(try store.unreadCount == 0 && conversation.storageError == nil, "valid new-generation receipts still work")
            do {
                _ = try store.append(Event(taskID: UUID(), kind: .userMessage, text: "Explicit stale reply",
                                           reply: .init(messageID: visibleMessage)))
                fatalError("explicit stale reply was accepted")
            } catch Store.Failure.invalidReply { checks += 1 }
            store.close()
            conversation.markRead(messageIDs: [freshMessage.event.id], generation: freshGeneration)
            try check(conversation.storageError != nil, "actual storage failure is not swallowed as a stale receipt")
            conversation.beginMaintenance(); await conversation.drainBackgroundWork(); conversation.closeForUninstall()
        }
    }

    static func recoveryPresentation(root: URL, defaults: UserDefaults) async throws {
        // Existing failure-notice timing keeps its original 8-second visible / 7-second
        // return window. Clarifications deliberately persist when their notch hides.
        var legacy = SidekickRecoveryTiming(now: 100)
        legacy.advance(now: 108)
        try check(legacy.visibility == .hidden && legacy.deadline == 115, "legacy failure timing no longer hides after eight seconds")
        legacy.advance(now: 114)
        try check(legacy.visibility == .hidden, "legacy return window expired early")
        legacy.advance(now: 115)
        try check(legacy.visibility == .expired && !legacy.reopen(now: 116), "legacy failure notice no longer expires after return window")
        var persistent = SidekickRecoveryTiming(now: 100, expiresWhenHidden: false)
        persistent.advance(now: 108)
        try check(persistent.visibility == .hidden && persistent.deadline == nil, "hidden clarification retained an expiry deadline")
        persistent.advance(now: 1_000_000)
        try check(persistent.visibility == .hidden && persistent.reopen(now: 1_000_000), "clarification expired while hidden")
        persistent.interact(true, now: 1_000_001)
        persistent.advance(now: 2_000_000)
        try check(persistent.visibility == .visible && persistent.deadline == nil, "active clarification interaction failed to pause notch hide")
        persistent.interact(false, now: 2_000_000)
        persistent.advance(now: 2_000_007)
        try check(persistent.visibility == .hidden && persistent.deadline == nil, "clarification returned to expiring hidden state")

        let conversation = SidekickConversation(url: root.appendingPathComponent("recovery-draft.sqlite"), defaults: defaults)
        conversation.draft = "Unsent next-task draft"
        let recovery = SidekickRecovery()
        let question = try SidekickQuestion(error: nil, question: "Which choice?", answers: ["Left", "Right"])
        var resolutions = 0, received: SidekickAnswer?
        recovery.present(.clarification(question)) { resolution in
            resolutions += 1
            if case .answered(let answer) = resolution { received = answer }
        }
        try check(recovery.draft.isEmpty && conversation.draft == "Unsent next-task draft", "clarification draft was prefilled from another composer")
        recovery.draft = "My clarification draft"
        recovery.dismiss()
        try check(recovery.isPending && !recovery.isVisible && recovery.draft == "My clarification draft", "hiding clarification lost pending state or draft")
        recovery.answer(id: question.id, choice: 1)
        try check(resolutions == 1 && received?.text == "Right" && received?.selectedAnswer == 1, "hidden question could not accept its real choice")
        try check(!recovery.isPending && conversation.draft == "Unsent next-task draft", "answer consumed the unrelated composer draft")
        recovery.answer(id: question.id, choice: 0)
        recovery.cancel(id: question.id)
        try check(resolutions == 1, "answered question was consumed more than once")

        let freeform = try SidekickQuestion(error: nil, question: "Any details?", answers: ["First", "Second"])
        recovery.present(.clarification(freeform)) { resolution in
            resolutions += 1
            if case .answered(let answer) = resolution { received = answer }
        }
        recovery.draft = "Actual custom answer"
        recovery.dismiss()
        recovery.answer(id: question.id, text: "stale prior answer")
        try check(recovery.content?.id == freeform.id && resolutions == 1, "stale question answer affected the newer question")
        recovery.answer(id: freeform.id)
        try check(received?.text == "Actual custom answer" && received?.selectedAnswer == nil && resolutions == 2, "hidden freeform answer was not consumed exactly")

        let waiting = try SidekickQuestion(error: nil, question: "Wait for me", answers: ["Continue", "Stop"])
        var explicitCancellations = 0
        let pending = Task { try await recovery.ask(waiting) { _ in explicitCancellations += 1 } }
        try await eventually { recovery.content?.id == waiting.id }
        recovery.dismiss()
        recovery.cancel(id: waiting.id, cause: .user)
        do { _ = try await pending.value; fatalError("cancelled hidden question returned an answer") }
        catch is CancellationError { checks += 1 }
        recovery.cancel(id: waiting.id, cause: .user)
        try check(explicitCancellations == 1 && !recovery.isPending, "hidden question cancellation was not consumed once")
        let interrupted = Task { try await recovery.ask(waiting) { _ in explicitCancellations += 1 } }
        try await eventually { recovery.content?.id == waiting.id }
        recovery.dismiss(); interrupted.cancel()
        do { _ = try await interrupted.value; fatalError("interrupted hidden question returned an answer") }
        catch is CancellationError { checks += 1 }
        try check(!recovery.isPending && explicitCancellations == 1, "task interruption invoked explicit user cancellation twice")
        try check(conversation.draft == "Unsent next-task draft", "question cancellation changed next-task draft")
        conversation.beginMaintenance(); await conversation.drainBackgroundWork(); conversation.closeForUninstall()
    }
    static func completionContract(root: URL, defaults: UserDefaults) async throws {
        let conversation = SidekickConversation(url: root.appendingPathComponent("completion-contract.sqlite"), defaults: defaults)
        let model = CommandRunModel(conversation: conversation)
        let store = conversation.store!
        let baselineCalls = Fixture.providerCalls
        defer { Fixture.provider = nil; Fixture.providerCalls = baselineCalls }
        Fixture.provider = { _ in
            _ = try SidekickInteraction.current!.conversationRun!.message("Your verified result.", kind: .answer, priority: .high, completion: .done)
            return "Your verified result." // deliberately no STATUS footer
        }
        model.start("Use the explicit final-message outcome", mode: .computer)
        let doneID = model.runID
        try await eventually { !model.isRunning }
        try check(try store.records(taskID: doneID).last?.event.outcome == .success && !model.recovery.isPending,
            "clean foreground run accepts explicit saved completion without STATUS footer")
        try check(try store.records(taskID: doneID).filter { $0.event.kind == .assistantMessage }.count == 1,
            "structured completion does not duplicate its answer")
        Fixture.provider = { _ in
            _ = try SidekickInteraction.current!.conversationRun!.message("I could not finish that action.", kind: .answer, priority: .high, completion: .couldNot)
            return "I could not finish that action."
        }
        model.start("Honest explicit incomplete outcome", mode: .computer)
        let failedID = model.runID
        try await eventually { !model.isRunning }
        try check(try store.records(taskID: failedID).last?.event.outcome == .failed && model.recovery.isPending,
            "structured could_not remains failed without STATUS footer")
        model.recovery.cancel()
        Fixture.provider = { _ in
            _ = try SidekickInteraction.current!.conversationRun!.message("An earlier answer.", kind: .answer, priority: .high, completion: .done)
            throw URLError(.networkConnectionLost)
        }
        model.start("A provider crash is not success", mode: .computer)
        let crashedID = model.runID
        try await eventually { !model.isRunning }
        try check(try store.records(taskID: crashedID).last?.event.outcome == .failed,
            "foreground catch path never promotes saved completion after provider error")
        model.recovery.cancel()
        conversation.beginMaintenance(); await conversation.drainBackgroundWork(); conversation.closeForUninstall()
    }
    static func networkRecovery(root: URL, defaults: UserDefaults) async throws {
        let conversation = SidekickConversation(url: root.appendingPathComponent("network-recovery.sqlite"), defaults: defaults)
        let model = CommandRunModel(conversation: conversation)
        let store = conversation.store!
        let baselineCalls = Fixture.providerCalls
        defer {
            Fixture.provider = nil
            NetworkSnapshot.shared.current.status = "satisfied"
            Fixture.providerCalls = baselineCalls
        }
        func network(_ status: String) {
            NetworkSnapshot.shared.current.status = status
            NotificationCenter.default.post(name: NetworkSnapshot.didChange, object: nil)
        }
        var release = false, cancellations = 0
        Fixture.provider = { _ in
            do {
                while !release { try await Task.sleep(for: .milliseconds(5)) }
                return "The task finished.\nSTATUS: DONE"
            } catch { cancellations += 1; throw error }
        }
        network("satisfied")
        model.start("Keep working across a brief network interruption", mode: .computer)
        try await eventually { Fixture.providerCalls == baselineCalls + 1 }
        let taskID = model.runID
        let originalProgress = model.statusLine
        network("unsatisfied")
        try await eventually { model.isOffline }
        try check(model.statusLine == "You might be offline. Retrying...", "offline status uses gentle retry copy")
        try await Task.sleep(for: .milliseconds(100))
        try check(model.isRunning && model.runID == taskID && cancellations == 0, "offline path never cancels or replaces owned command")
        try check(!model.recovery.isPending && Fixture.providerCalls == baselineCalls + 1, "offline path neither asks for guidance nor replays task")
        try check(try store.records(taskID: taskID).allSatisfy { $0.event.kind != .taskFinished }, "network hint cannot record terminal task status")
        network("satisfied")
        try await eventually { !model.isOffline }
        try check(model.statusLine == originalProgress && model.isRunning, "reconnection restores existing live progress")
        network("requires_connection")
        try await Task.sleep(for: .milliseconds(20))
        try check(!model.isOffline, "on-demand connection does not imply offline")
        network("unsatisfied")
        try await eventually { model.isOffline }
        release = true
        try await eventually { !model.isRunning }
        try check(try store.records(taskID: taskID).last?.event.outcome == .success, "success can finish while route monitor still says offline")
        try check(!model.isOffline && !model.recovery.isPending && model.statusLine == "✓ done", "stale offline hint does not replace actual success")

        // Already-offline starts remain owned and cancellable without recreating the executor.
        release = false
        model.start("Stop this while its provider reconnects", mode: .computer)
        try await eventually { model.isOffline && Fixture.providerCalls == baselineCalls + 2 }
        let stoppedID = model.runID
        model.stop()
        try check(!model.isOffline && model.statusLine == "Stopping…", "Stop immediately replaces retry banner")
        try await eventually { !model.isRunning }
        try check(try cancellations == 1 && store.records(taskID: stoppedID).last?.event.outcome == .stopped, "user Stop cancels exactly once and stays a user stop")

        // The same rules apply to proactive actions and questions; live progress is not lost.
        var externalStops = 0
        model.adoptExternal(caption: "Initial progress", onStopRequest: { externalStops += 1 })
        let externalID = model.runID
        try await eventually { model.isOffline }
        model.externalPush("codex", runID: externalID)
        model.externalPush("The local draft is ready", runID: externalID)
        let question = try SidekickQuestion(error: nil, question: "Which local draft?", answers: ["First", "Second"])
        let interaction = model.interaction!
        let ask = Task { try await interaction.ask(question) }
        try await eventually { model.recovery.content?.id == question.id }
        model.recovery.answer(id: question.id, choice: 0)
        let answer = try await ask.value
        try check(answer.text == "First" && externalStops == 0, "offline path does not cancel real questions or external actions")
        network("satisfied")
        try await eventually { !model.isOffline }
        try check(model.statusLine == "The local draft is ready", "progress received during outage is retained for reconnection")
        model.completeExternal(.success, line: "Done", runID: externalID)

        // A genuinely terminated provider still surfaces its actual error, never a false
        // promise that it is retrying after the owned process has ended.
        Fixture.provider = { _ in throw URLError(.networkConnectionLost) }
        network("unsatisfied")
        model.start("Provider exhausts its own transport retries", mode: .computer)
        try await eventually { !model.isRunning }
        try check(model.recovery.isPending && !model.isOffline && model.statusLine != CommandRunModel.offlineMessage,
            "terminal provider failure replaces temporary retry status honestly")
        model.recovery.cancel()
        network("satisfied")
        try await Task.sleep(for: .milliseconds(20))
        try check(!model.isRunning && !model.isOffline, "late network updates cannot revive finished task")
        conversation.beginMaintenance(); await conversation.drainBackgroundWork(); conversation.closeForUninstall()
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "sidekick-lifecycle-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        try await completionContract(root: root, defaults: defaults)
        try await networkRecovery(root: root, defaults: defaults)
        try await recoveryPresentation(root: root, defaults: defaults)
        try await clearChat(root: root, defaults: defaults)
        try await stoppedRunReadReceipts(root: root, defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let conversation = SidekickConversation(url: root.appendingPathComponent("main.sqlite"), defaults: defaults)
        defer { conversation.beginMaintenance() }
        let model = CommandRunModel(conversation: conversation)
        let store = conversation.store!
        var finishes = 0
        model.onFinished = { _ in finishes += 1 }
        var delegatedStop = 0
        model.adoptExternal(caption: "Fixture card", request: "Create the fixture", onStopRequest: { delegatedStop += 1 })
        let first = model.runID, interaction = model.interaction!
        try interaction.conversationRun!.observe(raw(["type":"item.started", "item":["id":"notch-fixture", "type":"mcp_tool_call",
            "server":"sentient_native", "tool":"get_app_state", "arguments":["app":"com.spotify.client"]]]), streamID: first)
        conversation.refresh()
        try check(conversation.latestActivity?.event.taskID == first
            && conversation.latestActivity?.event.activity?.name == "sentient_native.get_app_state", "notch receives active task's structured activity")
        let started = Latch(), cancellationReceived = Latch(), allowCleanup = Latch()
        let work = Task { @MainActor in
            _ = try! interaction.conversationRun!.message("Created a partial draft", kind: .update, priority: .normal)
            await started.signal()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { await cancellationReceived.signal() }
            await allowCleanup.wait() // non-cancellable drain simulates owned process cleanup
            model.completeExternal(.success, line: "Late DONE", finalText: "STATUS: DONE", runID: first)
        }
        model.ownExternalTask(work, cardID: "fixture-card")
        await started.wait()
        try check(model.externalCardID == "fixture-card", "app model owns proactive task identity")
        do { _ = try conversation.begin(request: "Cannot recover a live producer", source: "fixture", taskID: UUID()); fatalError("conversation accepted overlapping producer") }
        catch { checks += 1 }
        try check(try store.records(taskID: first).allSatisfy { $0.event.kind != .taskFinished }, "before-begin orphan repair cannot terminate a legitimate active task")
        model.stop(); model.stop()
        await cancellationReceived.wait()
        var drainFinished = false
        let drain = Task { let result = await model.stopAndDrain(); drainFinished = true; return result }
        await Task.yield()
        try check(!drainFinished, "teardown waits for owned task cleanup")
        try check(model.isRunning && model.isExternal && model.statusLine == "Stopping…", "Stop holds one-task lock until owned task cleanup")
        try check(delegatedStop == 0, "owned task cancellation no longer delegates to Home")
        let before = try store.latestSequence
        model.start("Cannot start while cleanup is pending", mode: .computer)
        try check(try store.latestSequence == before && Fixture.providerCalls == 0, "new execution cannot overlap stopping owned task")
        await allowCleanup.signal(); await work.value
        let drained = await drain.value
        try check(drained, "teardown confirms owned task drained")
        try check(!model.isRunning && model.externalCardID == nil && finishes == 1, "cleanup releases lock exactly once")
        try check(conversation.latestActivity == nil, "terminal task clears live notch activity")
        let firstRecords = try store.records(taskID: first)
        try check(firstRecords.last?.event.outcome == .stopped, "latched user Stop beats late success")
        try check(firstRecords.contains { $0.event.text == "Created a partial draft" }, "partial response survives Stop")
        model.completeExternal(.failed, line: "duplicate", runID: first)
        try check(finishes == 1, "duplicate terminal callback is ignored")

        model.adoptExternal(caption: "Second fixture", onStopRequest: {})
        let second = model.runID
        try check(conversation.latestActivity == nil, "new task cannot inherit previous app icon or activity")
        let secondStatus = model.statusLine
        model.externalPush("wrong old status", runID: first)
        model.completeExternal(.success, line: "wrong old completion", runID: first)
        try check(model.isRunning && model.runID == second && model.statusLine == secondStatus, "old generation cannot alter newer run")
        let staleQuestion = try SidekickQuestion(error: nil, question: "Old task question", answers: ["Yes", "No"])
        do { _ = try await interaction.ask(staleQuestion); fatalError("old interaction reopened a question") }
        catch { checks += 1 }
        try check(model.isRunning && model.runID == second && !model.recovery.isPending, "stale interaction cannot cancel or replace current run")
        model.completeExternal(.success, line: "Done", finalText: "Second answer\nSTATUS: DONE", runID: second)
        try check(!model.isRunning, "current generation can complete")

        var retryContext = ""
        model.adoptExternal(caption: "Retry fixture", request: "Original card request", onRetry: { context in
            retryContext = context
            model.adoptExternal(caption: "Retrying fixture", request: "Original card request", retryContext: context, onStopRequest: {})
        }, onStopRequest: {})
        let failed = model.runID
        model.completeExternal(.failed, line: "Need another account", finalText: "Could not choose account", runID: failed)
        let recoveryID = model.recovery.content!.id
        model.recovery.answer(id: recoveryID, text: "Use the work account")
        let retry = model.runID
        try check(model.isRunning && retry != failed && retryContext.contains("Use the work account"), "real recovery guidance starts linked retry")
        let retryRecords = try store.records(taskID: retry)
        try check(retryRecords.contains { $0.event.kind == .userMessage && $0.event.text == "Use the work account" }, "retry records actual new user guidance")
        try check(retryRecords.contains { $0.event.kind == .userMessage && $0.event.reply?.messageID == "end:\(failed)" }, "retry links original failed task")
        model.completeExternal(.success, line: "Done", runID: retry)

        model.adoptExternal(caption: "Question fixture", onStopRequest: {})
        let questionTask = model.runID, questionInteraction = model.interaction!
        let question = try SidekickQuestion(error: nil, question: "Which option?", answers: ["First", "Second"])
        let asking = Task { try await questionInteraction.ask(question) }
        try await eventually { model.recovery.content?.id == question.id }
        try check(questionInteraction.isWaiting && (try store.record(id: "question:\(question.id)")) != nil, "question persisted before waiting for real answer")
        model.recovery.answer(id: question.id, choice: 1)
        let answer = try await asking.value
        try check(answer.text == "Second" && !questionInteraction.isWaiting, "real answer resumes question wait")
        try check(try store.record(id: "answer:\(question.id)")?.event.text == "Second", "real answer durably persisted")
        model.completeExternal(.success, line: "Done", runID: questionTask)

        // Ordinary command path keeps cancellation ownership through provider cleanup too.
        let commandStarted = Latch(), commandCancelled = Latch(), commandCleanup = Latch()
        Fixture.provider = { _ in
            guard let current = SidekickInteraction.current, current.conversationRun != nil else { fatalError("foreground interaction not inherited") }
            _ = try current.conversationRun!.message("Ordinary command partial answer", kind: .update, priority: .normal)
            await commandStarted.signal()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { await commandCancelled.signal() }
            await commandCleanup.wait()
            return "Late provider answer\nSTATUS: DONE — fixture complete"
        }
        model.start("Ordinary cancellable command", mode: .computer)
        let ordinaryID = model.runID
        await commandStarted.wait()
        model.stop()
        await commandCancelled.wait()
        try check(model.isRunning, "ordinary command keeps lock while cancelled provider drains")
        await commandCleanup.signal()
        try await eventually { !model.isRunning }
        try check(try store.records(taskID: ordinaryID).last?.event.outcome == .stopped, "late normal-provider success cannot overwrite Stop")
        Fixture.provider = nil

        // A failed attempt leaves no active-tool lock in its fallback while durable evidence remains.
        let (recording, _) = try conversation.begin(request: "Continue after tool failure", source: "fixture", taskID: UUID())
        let independent = SidekickInteraction(conversationRun: recording) { _ in .init(text: "First", selectedAnswer: 0) }
        let stream = UUID()
        try independent.observeToolEvent(raw(["type":"item.started", "item":["id":"tool0","type":"command_execution","command":"RAW_COMMAND_SHOULD_NOT_ENTER_CONTEXT"]]), streamID: stream)
        try check(independent.hasActiveTools, "structured tool start tracked")
        independent.endExecution(streamID: stream)
        try check(!independent.hasActiveTools, "failed execution releases question exclusion for fallback")
        _ = try await independent.ask(try SidekickQuestion(error: nil, question: "Continue?", answers: ["First", "Second"]))
        conversation.finish(recording, outcome: .stopped, status: "[Stopped by user]", finalText: "")
        let (followup, context) = try conversation.begin(request: "Continue", source: "fixture", taskID: UUID())
        try check(!context.contains("RAW_COMMAND_SHOULD_NOT_ENTER_CONTEXT"), "next task receives no raw tool history")
        try check(context.contains("Created a partial draft") && context.contains("stopped"), "next context retains useful stopped-task state")
        conversation.finish(followup, outcome: .success, status: "Done", finalText: "Resumed")

        // Persist failure before execution: exercise a real SQLite write rejection.
        let failing = SidekickConversation(url: root.appendingPathComponent("failing.sqlite"), defaults: defaults)
        defer { failing.beginMaintenance() }
        try executeSQL(failing.store!, "CREATE TRIGGER fixture_reject BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'fixture write rejected'); END")
        let blocked = CommandRunModel(conversation: failing)
        let oldGateCalls = Fixture.gateCalls, oldProviders = Fixture.providerCalls
        blocked.start("Must never execute", mode: .computer)
        try check(!blocked.isRunning && Fixture.gateCalls == oldGateCalls && Fixture.providerCalls == oldProviders, "failed initial persistence prevents setup and execution")
        try check(try failing.store!.latestSequence == 0, "failed start transaction leaves no partial user task")

        let terminalFailure = SidekickConversation(url: root.appendingPathComponent("terminal-failure.sqlite"), defaults: defaults)
        defer { terminalFailure.beginMaintenance() }
        let terminalStore = terminalFailure.store!
        let (terminalRun, _) = try terminalFailure.begin(request: "Action succeeds but final persistence fails", source: "fixture", taskID: UUID())
        _ = try terminalRun.message("Already saved update", kind: .update, priority: .normal)
        let beforeTerminal = try terminalStore.latestSequence
        try executeSQL(terminalStore, "CREATE TRIGGER fixture_terminal_reject BEFORE INSERT ON events WHEN NEW.kind = 'taskFinished' BEGIN SELECT RAISE(ABORT, 'fixture terminal rejected'); END")
        let terminalSaved = terminalFailure.finish(terminalRun, outcome: .success, status: "Done", finalText: "Actual result")
        try check(!terminalSaved && terminalFailure.storageError != nil, "terminal persistence failure is reported separately from actual action outcome")
        try check(try terminalStore.latestSequence == beforeTerminal, "failed terminal transaction preserves prior messages without partial fallback")
        do { _ = try terminalRun.message("late after failed finish", kind: .answer, priority: .high); fatalError("failed finish left producer open") }
        catch { checks += 1 }
        do { _ = try terminalFailure.begin(request: "Storage still broken", source: "fixture", taskID: UUID()); fatalError("new task bypassed failed orphan recovery") }
        catch { checks += 1 }
        try executeSQL(terminalStore, "DROP TRIGGER fixture_terminal_reject")
        let (recoveredWriter, _) = try terminalFailure.begin(request: "A new durable request", source: "fixture", taskID: UUID())
        try check(terminalFailure.storageError == nil, "successful request commit clears previous recovered storage error")
        try check(try terminalStore.records(taskID: terminalRun.taskID).last?.event.outcome == .interrupted, "recovered storage closes orphan without inventing successful action outcome")
        try check(terminalFailure.finish(recoveredWriter, outcome: .success, status: "Done", finalText: "Saved now"), "terminal save reports actual commit success")
        try check(terminalFailure.storageError == nil, "successful terminal commit clears storage error")

        // Recovery Retry must work after a failed terminal transaction created no end:<id>.
        let retryPersistence = SidekickConversation(url: root.appendingPathComponent("retry-persistence.sqlite"), defaults: defaults)
        defer { retryPersistence.beginMaintenance() }
        let retryModel = CommandRunModel(conversation: retryPersistence)
        let retryStore = retryPersistence.store!
        retryModel.adoptExternal(caption: "Original action", request: "Original action request", onRetry: { context in
            retryModel.adoptExternal(caption: "Retry original action", request: "Original action request", retryContext: context, onStopRequest: {})
        }, onStopRequest: {})
        let failedPersistenceID = retryModel.runID
        try executeSQL(retryStore, "CREATE TRIGGER fixture_retry_terminal_reject BEFORE INSERT ON events WHEN NEW.kind = 'taskFinished' BEGIN SELECT RAISE(ABORT, 'fixture terminal rejected'); END")
        retryModel.completeExternal(.failed, line: "Fixture action could not finish", runID: failedPersistenceID)
        try check(!retryModel.isRunning && retryModel.recovery.isPending, "failed action keeps retry available despite terminal storage failure")
        try check(try retryStore.record(id: "end:\(failedPersistenceID)") == nil, "fixture actually has no durable terminal reference")
        let retryPresentation = retryModel.recovery.content!.id
        try executeSQL(retryStore, "DROP TRIGGER fixture_retry_terminal_reject")
        retryModel.recovery.answer(id: retryPresentation, text: "Try the other account")
        try check(retryModel.isRunning && retryModel.runID != failedPersistenceID, "repaired storage admits actual recovery Retry")
        let retriedRecords = try retryStore.records(taskID: retryModel.runID)
        try check(retriedRecords.contains { $0.event.kind == .userMessage && $0.event.text == "Try the other account"
            && $0.event.reply?.messageID == "request:\(failedPersistenceID)" }, "retry uses durable original request when terminal is missing")
        try check(retriedRecords.first?.event.text == "Original action request", "retry preserves original execution task alongside new guidance")
        let recoveredOriginal = try retryStore.records(taskID: failedPersistenceID)
        try check(recoveredOriginal.last?.event.outcome == .interrupted && recoveredOriginal.filter { $0.event.kind == .taskFinished }.count == 1,
            "orphan becomes one truthful interrupted ending after storage repair")
        retryModel.completeExternal(.success, line: "Done", runID: retryModel.runID)
        try check(try retryStore.compactionBoundary(keepingRecentTasks: 0) == retryStore.latestSequence,
            "recovered orphan does not block future completed-prefix compaction")

        let corruptPath = root.appendingPathComponent("corrupt.sqlite")
        let corruptBytes = Data("synthetic unreadable SQLite file".utf8)
        try corruptBytes.write(to: corruptPath)
        let memoryPath = root.appendingPathComponent("SidekickMemory.md")
        let memoryBytes = Data("User memory survives explicit history reset".utf8)
        try memoryBytes.write(to: memoryPath)
        let unreadable = SidekickConversation(url: corruptPath, defaults: defaults)
        defer { unreadable.beginMaintenance() }
        try check(unreadable.store == nil && unreadable.storageError != nil, "normal startup refuses unreadable conversation database")
        try check(try Data(contentsOf: corruptPath) == corruptBytes, "normal startup preserves unreadable original bytes")
        try unreadable.reset(defaults: defaults)
        try check(unreadable.store != nil && unreadable.storageError == nil && unreadable.messages.isEmpty, "explicit reset replaces failed-open store with usable empty database")
        try check(try unreadable.store!.needsLegacyImport == false, "explicit reset disables stale legacy reimport")
        try check(try Data(contentsOf: memoryPath) == memoryBytes, "history reset preserves neighboring memory file")
        let (afterReset, _) = try unreadable.begin(request: "After explicit recovery", source: "fixture", taskID: UUID())
        try check(afterReset.backend == "claude" && afterReset.source == "fixture", "recording captures originating provider and source")
        _ = try afterReset.message("Recovered live answer", kind: .answer, priority: .high, id: "recovered-live-answer")
        try await eventually { unreadable.attention?.event.id == "recovered-live-answer" }
        try check(unreadable.unreadCount == 1, "replacement-store observer publishes new live messages")
        try check(unreadable.finish(afterReset, outcome: .success, status: "Done", finalText: "Recovered live answer"), "recovered store accepts terminal commit")

        let restartPath = root.appendingPathComponent("restart.sqlite")
        let previous = SidekickConversation(url: restartPath, defaults: defaults)
        defer { previous.beginMaintenance() }
        let unfinishedID = UUID()
        let (unfinished, _) = try previous.begin(request: "Remember this exact request", source: "fixture", taskID: unfinishedID)
        _ = try unfinished.message("Exact **partial** café 👩🏽‍💻", kind: .update, priority: .normal)
        let pendingQuestion = UUID()
        try unfinished.question(id: pendingQuestion, text: "Still waiting?", choices: ["Yes", "No"], error: nil)
        let restarted = SidekickConversation(url: restartPath, defaults: defaults)
        defer { restarted.beginMaintenance() }
        let recovered = try restarted.store!.records(taskID: unfinishedID)
        try check(recovered.last?.event.outcome == .interrupted, "startup marks unfinished task interrupted without executing")
        try check(recovered.contains { $0.event.text == "Exact **partial** café 👩🏽‍💻" } && recovered.contains { $0.event.id == "question:\(pendingQuestion)" }, "restart preserves exact messages and historical question")
        try check(recovered.filter { $0.event.kind == .taskFinished }.count == 1, "startup recovery adds exactly one terminal state")
        let restartedAgain = SidekickConversation(url: restartPath, defaults: defaults)
        defer { restartedAgain.beginMaintenance() }
        try check(try restartedAgain.store!.records(taskID: unfinishedID).filter { $0.event.kind == .taskFinished }.count == 1, "restart recovery is idempotent")
        do { _ = try unfinished.message("late callback", kind: .answer, priority: .high); fatalError("old producer revived recovered task") }
        catch { checks += 1 }

        let staleGeneration = try store.generation
        let (resetRun, _) = try conversation.begin(request: "Reset fixture", source: "fixture", taskID: UUID())
        try conversation.reset(defaults: defaults)
        do { _ = try resetRun.message("must not return", kind: .answer, priority: .high); fatalError("reset producer revived history") }
        catch { checks += 1 }
        try check(try store.latestSequence == 0 && store.generation != staleGeneration, "reset invalidates old generation and clears durable content")
        // Reset/maintenance prevents new work and stale producers while teardown suspends.
        conversation.beginMaintenance()
        do { _ = try conversation.begin(request: "Blocked during maintenance", source: "fixture", taskID: UUID()); fatalError("maintenance admitted a request") }
        catch { checks += 1 }
        conversation.endMaintenance()
        let (afterMaintenance, _) = try conversation.begin(request: "After maintenance", source: "fixture", taskID: UUID())
        conversation.finish(afterMaintenance, outcome: .success, status: "Done", finalText: "Available again")
        try check(try store.latestSequence > 0, "ending maintenance restores normal conversation")

        // Observe live database commits without manually refreshing the projection.
        let projection = SidekickConversation(url: root.appendingPathComponent("projection.sqlite"), defaults: defaults)
        defer { projection.beginMaintenance() }
        let projectedTask = UUID(), projectedStore = projection.store!
        _ = try projectedStore.appendBatch((0..<501).map { index in
            Event(taskID: projectedTask, kind: .assistantMessage, text: "Quiet progress \(index)", messageKind: .update)
        })
        _ = try projectedStore.append(Event(id: "projected-newest-answer", taskID: projectedTask, kind: .assistantMessage, text: "Fresh answer"))
        try await eventually { projection.unreadCount == 502 }
        try check(projection.attention?.event.id == "projected-newest-answer", "live projection attention reaches answer beyond oldest unread page")
        let activityRecord = try projectedStore.append(Event(taskID: projectedTask, kind: .activity,
            activity: .init(toolID: "projected-tool", name: "fixture", status: .completed)))
        try check(try projection.activity(taskID: projectedTask).map(\.sequence) == [activityRecord.sequence], "projection activity query ignores preceding message count")
        let projectedQuestion = Event(id: "projected-question", taskID: projectedTask, kind: .question,
            text: "Are you ready?", priority: .high, choices: ["Ready", "Stop"])
        _ = try projectedStore.append(projectedQuestion)
        try await eventually { projection.attention?.event.id == projectedQuestion.id }
        _ = try projectedStore.append(Event(taskID: projectedTask, kind: .answer, text: "Ready", reply: .init(messageID: projectedQuestion.id)))
        try await eventually { projection.attention?.event.id == "projected-newest-answer" }
        try check(projection.unreadCount == 502, "answered question leaves actionable unread count")
        _ = try projectedStore.append(Event(id: "projected-stopped-question", taskID: projectedTask, kind: .question,
            text: "Confirm?", priority: .high, choices: ["Yes", "Stop"]))
        _ = try projectedStore.append(Event(taskID: projectedTask, kind: .taskFinished, outcome: .stopped))
        try await eventually { projection.attention?.event.id == "projected-newest-answer" && projection.unreadCount == 502 && projection.messages.contains { $0.event.id == "projected-stopped-question" } }
        try check(projection.messages.contains { $0.event.id == "projected-stopped-question" }, "dead question stays visible as historical text")
        projection.isVisible = true
        try check(projection.attention == nil && projection.unreadCount == 502, "visible history suppresses attention without marking unseen messages read")
        projection.isVisible = false
        projection.markRead(through: try projectedStore.latestSequence, generation: try projectedStore.generation)
        try check(projection.attention == nil && projection.unreadCount == 0, "explicit read watermark clears current unread projection")

        let uninstallDirectory = root.appendingPathComponent("uninstall")
        let uninstallProjection = SidekickConversation(url: uninstallDirectory.appendingPathComponent("Conversation.sqlite"), defaults: defaults)
        let (retainedRun, _) = try uninstallProjection.begin(request: "Before uninstall", source: "fixture", taskID: UUID())
        let retainedStore = uninstallProjection.store!, retainedGeneration = try retainedStore.generation
        _ = try retainedRun.message("Already saved before teardown", kind: .answer, priority: .high)
        uninstallProjection.refresh()
        let beforeMaintenanceMessages = uninstallProjection.messages.count
        uninstallProjection.beginMaintenance()
        uninstallProjection.markRead(through: try retainedStore.latestSequence, generation: retainedGeneration)
        try check(try retainedStore.readThroughSequence == 0, "maintenance prevents late read-watermark mutation")
        _ = try retainedRun.message("Queued callback during teardown", kind: .update, priority: .normal)
        uninstallProjection.refresh()
        try await Task.sleep(for: .milliseconds(20))
        try check(uninstallProjection.messages.count == beforeMaintenanceMessages, "maintenance ignores queued projection refreshes")
        await uninstallProjection.drainBackgroundWork()
        uninstallProjection.closeForUninstall(); uninstallProjection.closeForUninstall()
        try check(uninstallProjection.store == nil && uninstallProjection.generation == nil && uninstallProjection.messages.isEmpty,
            "uninstall closes store and clears projection idempotently")
        try FileManager.default.removeItem(at: uninstallDirectory)
        NotificationCenter.default.post(name: .sidekickConversationChanged, object: retainedStore)
        uninstallProjection.refresh()
        uninstallProjection.markRead(through: 1, generation: retainedGeneration)
        try await Task.sleep(for: .milliseconds(20))
        try check(uninstallProjection.messages.isEmpty && uninstallProjection.attention == nil && uninstallProjection.storageError == nil,
            "late observer/read callbacks cannot change closed projection")
        do { _ = try retainedRun.message("late producer", kind: .answer, priority: .high); fatalError("retained recorder wrote after uninstall close") }
        catch { checks += 1 }
        do { _ = try retainedStore.append(Event(taskID: UUID(), kind: .userMessage, text: "late store write")); fatalError("retained store reopened itself") }
        catch Store.Failure.closed { checks += 1 }
        try check(!FileManager.default.fileExists(atPath: uninstallDirectory.path), "late writes cannot recreate removed support directory")
        try uninstallProjection.reset(defaults: defaults)
        try check(uninstallProjection.store != nil && uninstallProjection.generation != retainedGeneration,
            "explicit reset can create a fresh store after shutdown")
        uninstallProjection.endMaintenance()
        let (freshRun, _) = try uninstallProjection.begin(request: "Fresh explicit reset", source: "fixture", taskID: UUID())
        try check(uninstallProjection.finish(freshRun, outcome: .success, status: "Done", finalText: "Fresh response"), "fresh store is usable after explicit recovery")
        uninstallProjection.beginMaintenance(); await uninstallProjection.drainBackgroundWork()
        uninstallProjection.closeForUninstall()

        // A provider that ignores cancellation must abort teardown at the bounded deadline.
        model.adoptExternal(caption: "Uncooperative owned cleanup fixture", onStopRequest: {})
        let uncooperativeID = model.runID
        let beforeTimeout = try store.records(), timeoutGeneration = try store.generation
        let drainBegan = ProcessInfo.processInfo.systemUptime
        do { try await model.clearChat(defaults: defaults); fatalError("clear ignored uncooperative task") }
        catch CommandRunModel.ClearChatFailure.stillStopping { checks += 1 }
        try check(model.isRunning && !model.isClearingChat, "unsettled task aborts clear without releasing one-task lock")
        try check(try store.records() == beforeTimeout && store.generation == timeoutGeneration, "clear timeout preserves stored history and generation")
        try check(conversation.beginMaintenance(), "clear timeout releases its maintenance ownership")
        conversation.endMaintenance()
        try check(ProcessInfo.processInfo.systemUptime - drainBegan >= 9.5, "real drain deadline exercised")
        model.completeExternal(.stopped, line: "Eventually stopped", runID: uncooperativeID)
        for value in [conversation, failing, terminalFailure, retryPersistence, unreadable, previous, restarted, restartedAgain, projection] {
            value.beginMaintenance()
            await value.drainBackgroundWork()
        }
        print("Sidekick lifecycle: \(checks) assertions passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-lifecycle-tests-") as directory:
    tmp = Path(directory)
    (tmp / "Support.swift").write_text(SUPPORT)
    (tmp / "Tests.swift").write_text(TESTS)
    names = ["CommandRunModel.swift", "SidekickConversation.swift", "SidekickConversationRun.swift", "SidekickConversationStore.swift", "SidekickContext.swift", "SidekickInteraction.swift", "SidekickRecovery.swift", "SidekickTaskEnd.swift"]
    sources = [APP / "Notch Magic" / name for name in names] + [APP / "Cloud/AgentStatus.swift", APP / "Diagnostics/SidekickDiagnostics.swift", APP / "Diagnostics/ComputerUseDiagnosticConsent.swift", APP / "System/PermissionWaitDraft.swift", APP / "Views/Onboarding/OnboardingRestaurantStory.swift"]
    executable = tmp / "lifecycle-tests"
    subprocess.run(["xcrun", "swiftc", "-D", "DEBUG", "-swift-version", "5", "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library", *map(str, sources), str(tmp / "Support.swift"), str(tmp / "Tests.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30, env={**os.environ, "FIXTURE_EMPTY_VAULT": str(tmp / "empty-vault"), "FIXTURE_PERMISSION_SUPPORT": str(tmp / "permission-support")})
