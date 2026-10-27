#!/usr/bin/env python3
"""Compile complete production presentation + Store; exercise isolated saved history.

SwiftUI/AppKit are linked, but no application/window/provider is started. Collaborators
are inert types; defaults are a process-local volatile domain under a unique fixture key.
"""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

SUPPORT = r'''
import Foundation

@MainActor final class ForYouModel {
    var clearCount = 0
    func clear() { clearCount += 1 }
}
@MainActor final class SidekickConversation {
    var store: SidekickConversationStore?
    var generation: UUID?
    var navigationRequest: UUID?
    private var revisionValue: UInt64 = 0
    // A one-shot observation barrier at the real refresh's version capture. It does not
    // replace the production read worker or SQLite query and is inert in other cases.
    var onRevisionRead: (@MainActor () -> Void)?
    var revision: UInt64 {
        get {
            let captured = revisionValue
            let callback = onRevisionRead; onRevisionRead = nil
            callback?()
            return captured
        }
        set { revisionValue = newValue }
    }
    var draft = ""
    init(_ store: SidekickConversationStore) throws {
        self.store = store; generation = try store.generation
    }
}
enum ProactiveCycle {
    static let lastCycleKey = "sidekick.presentation.fixture." + UUID().uuidString
}
enum SidekickDiagnostics {
    enum Stage { case historyRead }
    enum Count { case messages }
    enum Reason { case readFailed }
    static var errors = 0
    static func event(_ stage: Stage, counts: [Count: Int], duration: Double) { }
    static func failure(_ stage: Stage, reason: Reason) { errors += 1 }
}
'''

TESTS = r'''
import Foundation
import Observation

typealias Store = SidekickConversationStore
typealias Event = SidekickConversationEvent
typealias Presentation = SidekickPresentation

@main enum PresentationTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { fatalError("FAIL: " + label) }
        checks += 1
    }

    static func seed(_ directory: URL, name: String, tasks: Int = 95) throws -> Store {
        let store = try Store(url: directory.appendingPathComponent(name + ".sqlite"))
        for number in 0..<tasks {
            let task = UUID()
            let keyword = number == 4 ? "search-alpha" : (number == 86 ? "search-beta" : "ordinary")
            try store.appendBatch([
                Event(id: "start-\(name)-\(number)", taskID: task, kind: .taskStarted, text: "request \(number)"),
                Event(id: "request-\(name)-\(number)", taskID: task, kind: .userMessage, text: "Request \(number), \(keyword)", source: "promptBar"),
                Event(id: "checkpoint-\(name)-\(number)", taskID: task, kind: .checkpoint, text: "checkpoint-hidden-marker"),
                Event(id: "response-\(name)-\(number)", taskID: task, kind: .assistantMessage, text: "Response \(number): exact **markdown** and café 👩🏽‍💻"),
                Event(id: "end-\(name)-\(number)", taskID: task, kind: .taskFinished, text: "Completed", outcome: .success)
            ])
        }
        return store
    }

    static func allTranscript(_ store: Store) throws -> [Store.Record] {
        var records: [Store.Record] = []
        while true {
            let page = try store.transcriptPage(after: records.last?.sequence ?? 0, limit: 100)
            records += page.records
            if !page.hasLater { return records }
        }
    }

    static func validWindow(_ model: Presentation, oracle: [Store.Record], label: String) throws {
        try check(model.rows.count <= 100, label + " stays bounded at100 rows")
        try check(model.rows.map(\.sequence) == model.rows.map(\.sequence).sorted(), label + " stays chronological")
        try check(Set(model.rows.map(\.sequence)).count == model.rows.count, label + " contains no duplicate rows")
        if let first = model.rows.first, let begin = oracle.firstIndex(where: { $0.sequence == first.sequence }) {
            try check(Array(oracle[begin..<begin + model.rows.count]) == model.rows, label + " has no hidden gap or changed payload")
        } else { try check(false, label + " has a valid source position") }
    }

    static func paging(_ store: Store) async throws {
        let conversation = try SidekickConversation(store)
        let model = Presentation()
        let oracle = try allTranscript(store)
        try check(oracle.count == 285, "fixture spans multiple rolling windows")
        await model.load(.latest, conversation: conversation)
        try check(model.rows == Array(oracle.suffix(40)), "latest loads exact final page")
        try check(model.hasEarlier && !model.hasLater && !model.loading, "latest page boundary flags settle")
        var encountered = Set(model.rows.map(\.sequence))
        var steps = 0
        while model.hasEarlier {
            let first = model.rows.first!
            await model.load(.earlier(first.sequence), conversation: conversation)
            try validWindow(model, oracle: oracle, label: "earlier \(steps)")
            try check(model.rows.contains(where: { $0.event.id == first.event.id }), "earlier navigation preserves its viewport anchor")
            try check(model.navigationTarget == first.event.id, "earlier scroll request targets retained anchor")
            try check(model.rows.first!.sequence < first.sequence, "earlier cursor makes progress")
            encountered.formUnion(model.rows.map(\.sequence)); steps += 1
            try check(steps < 20, "earlier pagination terminates")
        }
        try check(encountered == Set(oracle.map(\.sequence)), "scrolling backward reaches every saved transcript record")
        try check(model.hasLater && model.rows.first == oracle.first, "oldest window exposes forward navigation")
        steps = 0
        while model.hasLater {
            let last = model.rows.last!
            await model.load(.later(last.sequence), conversation: conversation)
            try validWindow(model, oracle: oracle, label: "later \(steps)")
            try check(model.rows.contains(where: { $0.event.id == last.event.id }), "later navigation preserves its viewport anchor")
            try check(model.navigationTarget == last.event.id, "later scroll request targets retained anchor")
            try check(model.rows.last!.sequence > last.sequence, "later cursor makes progress")
            steps += 1
            try check(steps < 20, "later pagination terminates")
        }
        try check(model.rows.last == oracle.last && model.hasEarlier, "forward pagination reaches newest saved response")

        let target = oracle[121]
        await model.load(.around(target.event.id), conversation: conversation)
        try validWindow(model, oracle: oracle, label: "deep link")
        try check(model.rows.contains(target) && model.navigationTarget == target.event.id,
                  "deep link retains exact original destination and Markdown bytes")
        try check(!model.atLatest && model.hasEarlier && model.hasLater, "deep link records reading mode and both boundaries")
        let retained = model.rows
        await model.load(.around("not-a-saved-message"), conversation: conversation)
        try check(model.error != nil && model.rows == retained && !model.loading, "missing destination shows recoverable error without losing current page")
        await model.load(.latest, conversation: conversation)
        try check(model.error == nil && model.navigationTarget == "sidekick-bottom", "explicit latest recovers navigation error")

        let cancelled = Task { await model.load(.around(target.event.id), conversation: conversation) }
        cancelled.cancel()
        await cancelled.value
        try check(model.rows == Array(oracle.suffix(40)) && !model.loading,
                  "cancelled load cannot replace current viewport")

        // Observe the real loading transition before superseding a request. No worker is
        // mocked or blocked; whichever SQLite read completes first, the latest request wins.
        let started = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = model.loading } onChange: { started.continuation.yield(()) }
        let earlier = Task { await model.load(.around(target.event.id), conversation: conversation) }
        for await _ in started.stream { break }
        let latest = Task { await model.load(.latest, conversation: conversation) }
        await earlier.value; await latest.value
        started.continuation.finish()
        try check(model.rows == Array(oracle.suffix(40)) && model.navigationTarget == "sidekick-bottom",
                  "superseding latest request wins over an older asynchronous around load")
    }

    static func searchAndReset(_ directory: URL, store: Store) async throws {
        let conversation = try SidekickConversation(store)
        let model = Presentation()
        await model.load(.latest, conversation: conversation)
        model.search = "checkpoint-hidden-marker"
        await model.find(conversation: conversation)
        try check(model.searchResults.isEmpty, "internal checkpoints are absent from chat search")
        model.search = "search-alpha"
        await model.find(conversation: conversation)
        try check(model.searchResults.map(\.event.id) == ["request-history-4"], "search returns exact saved user request")
        model.error = "a prior query failed"
        model.search = "search-beta"
        await model.find(conversation: conversation)
        try check(model.searchResults.map(\.event.id) == ["request-history-86"] && model.error == nil,
                  "successful search replaces results and clears stale search error")

        model.search = "search-alpha"
        let oldQuery = Task { await model.find(conversation: conversation) }
        try await Task.sleep(for: .milliseconds(30))
        model.search = "search-beta"
        let newQuery = Task { await model.find(conversation: conversation) }
        await oldQuery.value; await newQuery.value
        try check(model.searchResults.map(\.event.id) == ["request-history-86"], "superseded debounced search cannot restore previous results")
        model.search = "search-alpha"
        let clearedQuery = Task { await model.find(conversation: conversation) }
        try await Task.sleep(for: .milliseconds(30))
        model.search = " \n "
        await model.find(conversation: conversation)
        await clearedQuery.value
        try check(model.searchResults.isEmpty, "clearing query invalidates already debouncing result")

        model.setSelection(true, messageID: "one")
        model.setSelection(true, messageID: "two")
        model.setSelection(false, messageID: "one")
        try check(model.textSelected, "deselecting one message preserves another message selection")
        model.setSelection(false, messageID: "unknown")
        try check(model.textSelected, "unrelated renderer deselection cannot reenable autoscroll")
        model.setSelection(false, messageID: "two")
        try check(!model.textSelected, "autoscroll eligibility returns after last selection ends")

        let staleStore = try seed(directory, name: "stale", tasks: 6)
        let replacement = try seed(directory, name: "replacement", tasks: 6)
        let changing = try SidekickConversation(staleStore)
        let racing = Presentation()
        racing.resetForGeneration(changing.generation)
        racing.search = "search-alpha"
        let failedOldQuery = Task { await racing.find(conversation: changing) }
        try await Task.sleep(for: .milliseconds(30))
        staleStore.close()
        changing.store = replacement; changing.generation = try replacement.generation
        racing.resetForGeneration(changing.generation)
        racing.search = "search-alpha"
        let replacementQuery = Task { await racing.find(conversation: changing) }
        await failedOldQuery.value
        try check(racing.error == nil, "late error from old closed store cannot poison new generation")
        await replacementQuery.value
        try check(racing.error == nil && racing.searchResults.map(\.event.id) == ["request-replacement-4"],
                  "replacement store search remains usable after old worker failure")

        model.setSelection(true, messageID: "selected-old-message")
        model.search = "search-alpha"; model.navigationTarget = "old-target"
        model.newMessages = true; model.loading = true
        model.searchResults = try store.searchTranscript("search-alpha")
        try store.reset(); conversation.generation = try store.generation
        model.resetForGeneration(conversation.generation)
        try check(model.rows.isEmpty && model.searchResults.isEmpty && model.search.isEmpty, "generation reset clears old transcript and search state")
        try check(!model.textSelected && !model.loading && !model.newMessages, "generation reset releases selections, loading and unread presentation")
        try check(model.navigationTarget == nil && !model.hasEarlier && !model.hasLater,
                  "generation reset clears deleted destinations and page boundaries")

        model.surface = .conversation; model.searchShown = true; model.clearChatConfirmationShown = true
        model.atLatest = false; model.scrollIsAutomatic = true; model.composerFocused = true
        model.didClearChat(generation: conversation.generation)
        try check(model.surface == .suggestions && !model.searchShown && !model.clearChatConfirmationShown,
                  "Clear chat returns to suggestions and closes conversation controls")
        try check(model.atLatest && !model.scrollIsAutomatic && !model.composerFocused,
                  "Clear chat releases focus and old scroll intent")

        let firstLive = UUID(), secondLive = UUID(), thirdLive = UUID()
        model.followActiveWork(firstLive, generation: conversation.generation)
        try check(model.expandedWorkTasks.contains(firstLive), "live task opens its details automatically")
        model.toggleWork(firstLive)
        model.followActiveWork(firstLive, generation: conversation.generation)
        try check(!model.expandedWorkTasks.contains(firstLive), "updates do not override a manual collapse")
        model.toggleWork(firstLive)
        model.followActiveWork(nil, generation: conversation.generation)
        model.followActiveWork(secondLive, generation: conversation.generation)
        try check(model.expandedWorkTasks.contains(firstLive) && model.expandedWorkTasks.contains(secondLive),
                  "a new task does not collapse manually opened history")
        await model.load(.latest, conversation: conversation)
        try check(model.expandedWorkTasks.contains(secondLive), "page refresh preserves active work before its response arrives")
        model.followActiveWork(nil, generation: conversation.generation)
        model.followActiveWork(thirdLive, generation: conversation.generation)
        try check(!model.expandedWorkTasks.contains(secondLive) && model.expandedWorkTasks.contains(thirdLive),
                  "next task folds the preceding automatic expansion")
        model.resetForGeneration(UUID())
        try check(model.activeWorkTaskID == nil && model.expandedWorkTasks.isEmpty,
                  "clear removes active and automatic expansion state")

        // A load already started against a saved generation must not repopulate reset rows.
        let old = try seed(directory, name: "load-reset", tasks: 6)
        let resetConversation = try SidekickConversation(old)
        let resetModel = Presentation()
        let started = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = resetModel.loading } onChange: { started.continuation.yield(()) }
        let inflight = Task { await resetModel.load(.latest, conversation: resetConversation) }
        for await _ in started.stream { break }
        try old.reset(); resetConversation.generation = try old.generation
        resetModel.resetForGeneration(resetConversation.generation)
        await inflight.value
        started.continuation.finish()
        try check(resetModel.rows.isEmpty && !resetModel.loading && resetModel.error == nil,
                  "reset invalidates in-flight page and does not strand loading state")
    }

    static func arrivals(_ directory: URL) async throws {
        let store = try seed(directory, name: "arrivals", tasks: 20)
        let conversation = try SidekickConversation(store)
        let model = Presentation()
        await model.load(.latest, conversation: conversation)
        try check(model.canFollowLatest, "idle bottom follows incoming responses")
        model.setSelection(true, messageID: "reading")
        try check(!model.canFollowLatest, "selecting text holds the current viewport")
        model.newMessages = true
        model.setSelection(false, messageID: "reading")
        try check(model.newMessages && model.canFollowLatest, "ending selection makes deferred response eligible without another commit")
        model.isScrolling = true
        try check(!model.canFollowLatest, "active user scroll prevents automatic replacement")
        model.isScrolling = false
        model.hasLater = true
        try check(!model.canFollowLatest, "historical page never follows latest automatically")
        model.hasLater = false
        model.userScrollChanged(true)
        model.viewportChanged(atLatest: false)
        model.userScrollChanged(false)
        try check(!model.canFollowLatest, "reader away from bottom retains position")

        // Observation fires synchronously as the real asynchronous page request starts.
        // Advance the producer revision after that request captured its version. Even if
        // SQLite happens to include the new commit, the reader cannot assume that it did.
        withObservationTracking { _ = model.loading } onChange: {
            MainActor.assumeIsolated { conversation.revision &+= 1 }
        }
        await model.load(.latest, conversation: conversation)
        try check(model.newMessages, "back-to-latest read cannot erase a concurrent arrival notification")
        model.viewportChanged(atLatest: true)
        try check(model.canFollowLatest && model.newMessages, "reaching bottom schedules deferred arrival refresh")
        let task = UUID()
        try store.appendBatch([
            Event(taskID: task, kind: .taskStarted, text: "Concurrent arrival"),
            Event(id: "concurrent-response", taskID: task, kind: .assistantMessage, text: "The new reply")
        ])
        conversation.revision &+= 1
        await model.load(.latest, conversation: conversation)
        try check(model.rows.last?.event.id == "concurrent-response" && !model.newMessages,
                  "settled refresh includes actual committed response and clears pending indicator")
        await model.load(.latest, conversation: conversation, automaticallyFollowing: true)
        try check(model.scrollIsAutomatic, "incoming response scrolling remains subject to reading protection")
        await model.load(.latest, conversation: conversation)
        try check(!model.scrollIsAutomatic, "explicit latest navigation takes precedence over prior reading position")

        // Navigation relinquishes auto-follow immediately, while its SQLite read awaits.
        let started = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = model.loading } onChange: { started.continuation.yield(()) }
        let navigation = Task { await model.load(.around("response-arrivals-2"), conversation: conversation) }
        for await _ in started.stream { break }
        try check(!model.canFollowLatest, "explicit older-message navigation owns viewport before read returns")
        await navigation.value
        started.continuation.finish()
        try check(model.navigationTarget == "response-arrivals-2", "arrival policy preserves explicit history destination")
    }

    static func liveActivityFollowing(_ directory: URL) async throws {
        let store = try seed(directory, name: "live-follow", tasks: 2)
        let conversation = try SidekickConversation(store)
        let model = Presentation()
        await model.load(.latest, conversation: conversation)
        let task = UUID()
        model.followActiveWork(task, generation: conversation.generation)
        let intent = model.readingIntentRevision
        let before = model.scrollRequest
        model.viewportChanged(atLatest: false) // More rows increased content height, no user gesture.
        try check(model.canFollowLatest, "content growth preserves following intent while bottom moves")
        model.activityDidChange(taskID: task, generation: conversation.generation, intent: intent)
        try check(model.scrollRequest == before + 1 && model.scrollIsAutomatic
                    && model.navigationTarget == Presentation.workTailID(task), "tool-only page update requests current expanded activity tail")
        model.userScrollChanged(true)
        let held = model.scrollRequest
        model.activityDidChange(taskID: task, generation: conversation.generation, intent: intent)
        try check(model.scrollRequest == held && !model.canFollowLatest, "gesture revokes already-scheduled live follow intent")
        model.viewportChanged(atLatest: true)
        try check(!model.canFollowLatest, "geometry callback cannot re-enable following during user gesture")
        model.viewportChanged(atLatest: false)
        model.userScrollChanged(false)
        model.activityDidChange(taskID: task, generation: conversation.generation, intent: model.readingIntentRevision)
        try check(model.scrollRequest == held, "ending an upward scroll preserves deliberate older reading position")
        model.userScrollChanged(true)
        model.viewportChanged(atLatest: true)
        model.userScrollChanged(false)
        try check(model.canFollowLatest, "returning to bottom resumes live following")
        model.browseWork(task)
        model.setWorkPage(.before(42), taskID: task)
        try check(model.workPage(task) == .before(42), "task owns older activity cursor across disclosure view relocation")
        model.viewportChanged(atLatest: true)
        model.activityDidChange(taskID: task, generation: conversation.generation, intent: model.readingIntentRevision)
        try check(model.scrollRequest == held && !model.canFollowLatest, "manual older activity page stays pinned even at transcript bottom")
        model.followLatestWork(task)
        model.activityDidChange(taskID: task, generation: conversation.generation, intent: model.readingIntentRevision)
        try check(model.scrollRequest == held + 1 && model.canFollowLatest && model.workPage(task) == .latest,
                  "latest-steps action explicitly rejoins current activity")
        model.setSelection(true, messageID: "selected")
        let selected = model.scrollRequest
        model.activityDidChange(taskID: task, generation: conversation.generation, intent: model.readingIntentRevision)
        try check(model.scrollRequest == selected, "selecting text suppresses activity scroll")
        model.setSelection(false, messageID: "selected")
        let collapseIntent = model.readingIntentRevision
        model.toggleWork(task)
        try check(model.canFollowLatest && model.readingIntentRevision == collapseIntent,
                  "manually collapsing current work preserves response-following intent")
        model.activityDidChange(taskID: task, generation: conversation.generation, intent: model.readingIntentRevision)
        try check(model.scrollRequest == selected, "collapsed current work never targets hidden activity")
        model.toggleWork(task)
        model.activityDidChange(taskID: UUID(), generation: conversation.generation, intent: model.readingIntentRevision)
        model.activityDidChange(taskID: task, generation: UUID(), intent: model.readingIntentRevision)
        try check(model.scrollRequest == selected, "old task and cleared-generation callbacks cannot move viewport")
        model.searchShown = true
        model.activityDidChange(taskID: task, generation: conversation.generation, intent: model.readingIntentRevision)
        try check(model.scrollRequest == selected, "history search owns viewport over activity")
        model.searchShown = false
        model.browseWork(task)
        let pageVersion = model.latestWorkPageRevision
        await model.load(.latest, conversation: conversation)
        try check(model.latestWorkPageRevision > pageVersion && !model.isBrowsingWork(task)
                    && model.canFollowLatest, "back-to-latest restores live activity page and following together")

        // Native size-change anchoring must yield to explicit older-work inspection.
        let olderTask = model.rows.first!.event.taskID
        model.expandedWorkTasks.remove(olderTask)
        let olderIntent = model.readingIntentRevision
        model.toggleWork(olderTask)
        try check(!model.canFollowLatest && model.readingIntentRevision > olderIntent,
                  "expanding completed history pauses native bottom-follow before its height grows")
        let oldReadingTarget = model.navigationTarget, oldReadingRequest = model.scrollRequest
        model.activityDidChange(taskID: task, generation: conversation.generation, intent: model.readingIntentRevision)
        try check(model.navigationTarget == oldReadingTarget && model.scrollRequest == oldReadingRequest,
                  "live activity cannot displace an explicitly opened older disclosure")
        model.toggleWork(olderTask)
        try check(!model.canFollowLatest, "collapsing old work does not silently resume following")
        await model.load(.latest, conversation: conversation)
        try check(model.canFollowLatest, "explicit latest navigation restores size-change following")
        model.followActiveWork(nil, generation: conversation.generation)
        model.viewportChanged(atLatest: false)
        try check(model.canFollowLatest, "completion height changes retain intent even after active task clears")
        let latestCompleted = model.rows.last!.event.taskID
        model.expandedWorkTasks.remove(latestCompleted)
        model.toggleWork(latestCompleted)
        try check(!model.canFollowLatest, "manually opening the newest completed details also respects reading intent")
        await model.load(.latest, conversation: conversation)

        // Moving away while a real asynchronous latest query runs must also preserve rows.
        await model.load(.around("response-live-follow-0"), conversation: conversation)
        let pinned = model.rows, target = model.navigationTarget
        model.userScrollChanged(true, atLatest: true)
        model.userScrollChanged(false, atLatest: true)
        withObservationTracking { _ = model.loading } onChange: {
            MainActor.assumeIsolated { model.pauseAutomaticFollowing() }
        }
        await model.load(.latest, conversation: conversation, automaticallyFollowing: true)
        try check(model.rows == pinned && model.navigationTarget == target,
                  "user intent during asynchronous auto-refresh wins before row replacement")
    }


    static func completionAndActivationFollowing(_ directory: URL) async throws {
        let store = try seed(directory, name: "completion-follow", tasks: 2)
        let conversation = try SidekickConversation(store)
        let model = Presentation()
        let task = UUID()
        try store.appendBatch([
            Event(id: "completion-live-start", taskID: task, kind: .taskStarted),
            Event(id: "completion-live-request", taskID: task, kind: .userMessage, text: "A live fixture task")])
        await model.load(.latest, conversation: conversation)
        model.followActiveWork(task, generation: conversation.generation)
        let intent = model.readingIntentRevision
        model.resumeFollowing(generation: conversation.generation)
        try check(model.navigationTarget == Presentation.workTailID(task) && model.scrollIsAutomatic,
                  "reactivating an expanded live task resumes at current work tail")
        model.toggleWork(task)
        model.resumeFollowing(generation: conversation.generation)
        try check(model.navigationTarget == "sidekick-bottom" && model.readingIntentRevision == intent,
                  "reactivating collapsed current work targets visible bottom without changing intent")
        model.toggleWork(task)
        try store.append(Event(id: "completion-live-answer", taskID: task, kind: .assistantMessage,
                               text: "The final answer arrived before the provider stopped.", messageKind: .answer))
        conversation.revision &+= 1
        await model.load(.latest, conversation: conversation, automaticallyFollowing: true)
        let beforeLateActivity = model.scrollRequest
        model.activityDidChange(taskID: task, generation: conversation.generation, intent: model.readingIntentRevision)
        try check(model.scrollRequest == beforeLateActivity + 1 && model.navigationTarget == "sidekick-bottom",
                  "late activity after final answer cannot override bottom with work tail")
        let beforeFinish = model.scrollRequest, finishIntent = model.readingIntentRevision
        model.followActiveWork(nil, generation: conversation.generation)
        try check(model.scrollRequest == beforeFinish + 1 && model.navigationTarget == "sidekick-bottom"
                    && model.readingIntentRevision == finishIntent && model.canFollowLatest,
                  "completion requests final response bottom without inventing a reading gesture")
        let discardedWhileHidden = model.scrollRequest
        model.resumeFollowing(generation: conversation.generation)
        try check(model.scrollRequest == discardedWhileHidden + 1 && model.navigationTarget == "sidekick-bottom",
                  "activation reissues an identical follow target that could have been dropped while inactive")
        let settled = model.scrollRequest
        model.activityDidChange(taskID: task, generation: conversation.generation, intent: model.readingIntentRevision)
        try check(model.scrollRequest == settled, "completed task's late tool callback cannot replace final destination")
        model.resumeFollowing(generation: UUID())
        try check(model.scrollRequest == settled, "stale-generation activation cannot navigate")

        let next = UUID()
        model.followActiveWork(next, generation: conversation.generation)
        model.userScrollChanged(true, atLatest: false)
        model.userScrollChanged(false, atLatest: false)
        let readerTarget = model.navigationTarget, readerRequest = model.scrollRequest
        model.resumeFollowing(generation: conversation.generation)
        model.followActiveWork(nil, generation: conversation.generation)
        try check(model.scrollRequest == readerRequest && model.navigationTarget == readerTarget && !model.followsLatest,
                  "activation and completion both preserve explicit older-message reading")
        await model.load(.latest, conversation: conversation)
        model.followActiveWork(UUID(), generation: conversation.generation)
        model.setSelection(true, messageID: "completion-live-answer")
        let selecting = model.scrollRequest
        model.resumeFollowing(generation: conversation.generation)
        model.followActiveWork(nil, generation: conversation.generation)
        try check(model.scrollRequest == selecting, "completion and activation cannot displace selected text")
        model.setSelection(false, messageID: "completion-live-answer")
        model.searchShown = true
        model.resumeFollowing(generation: conversation.generation)
        try check(model.scrollRequest == selecting, "history search keeps ownership on activation")
        model.searchShown = false; model.hasLater = true
        model.resumeFollowing(generation: conversation.generation)
        try check(model.scrollRequest == selecting, "an older history page is not automatically replaced")
        model.hasLater = false
        model.resumeFollowing(generation: conversation.generation)
        try check(model.scrollRequest == selecting + 1 && model.navigationTarget == "sidekick-bottom",
                  "eligible following resumes once the reader's transient hold ends")
    }

    static func workMetadata(_ directory: URL) async throws {
        let store = try seed(directory, name: "work-metadata", tasks: 50)
        let conversation = try SidekickConversation(store)
        let model = Presentation()
        let openTask = UUID(), began = Date(timeIntervalSinceReferenceDate: 765432100.25)
        try store.appendBatch([
            Event(id: "work-open-start", taskID: openTask, kind: .taskStarted, createdAt: began),
            Event(id: "work-open-request", taskID: openTask, kind: .userMessage, text: "An open request", createdAt: began),
            Event(id: "work-open-response", taskID: openTask, kind: .assistantMessage, text: "A partial response", createdAt: began.addingTimeInterval(1))
        ])
        await model.load(.latest, conversation: conversation)
        try check(model.taskStates[openTask]?.startedAt == began && model.taskStates[openTask]?.finished == nil,
                  "loaded open-task metadata is inaccurate")
        model.atLatest = false
        model.expandedWorkTasks.insert(openTask)
        model.navigationTarget = "work-open-response"
        let originalRows = model.rows, originalTarget = model.navigationTarget
        let originalRequest = model.scrollRequest
        let originalAutomatic = model.scrollIsAutomatic
        try store.appendBatch([
            Event(id: "work-operation", taskID: openTask, kind: .activity, text: "fixture.search",
                  activity: .init(toolID: "fixture-1", name: "fixture.search", status: .completed)),
            Event(id: "work-open-finish", taskID: openTask, kind: .taskFinished, text: "Done",
                  createdAt: began.addingTimeInterval(12), outcome: .success)
        ])
        conversation.revision &+= 1
        await model.refreshTaskStates(conversation: conversation)
        try check(model.taskStates[openTask]?.finished?.event.id == "work-open-finish"
                    && model.taskStates[openTask]?.hasActivity == true, "off-bottom refresh left completed work metadata stale")
        try check(model.rows == originalRows && !model.atLatest, "metadata-only refresh replaced rows or reading position")
        try check(model.navigationTarget == originalTarget && model.scrollRequest == originalRequest
                    && model.scrollIsAutomatic == originalAutomatic,
                  "metadata-only refresh issued or changed navigation")
        try check(model.expandedWorkTasks == [openTask], "metadata refresh collapsed the reader's open work disclosure")
        await model.load(.latest, conversation: conversation)
        try check(model.expandedWorkTasks.contains(openTask), "same-generation retained-page refresh lost expansion")
        try check(Set(model.taskStates.keys) == Set(model.rows.map { $0.event.taskID }), "page metadata included missing/off-page task identities")
        await model.load(.around("response-work-metadata-0"), conversation: conversation)
        try check(!model.rows.contains { $0.event.taskID == openTask } && !model.expandedWorkTasks.contains(openTask),
                  "evicted task kept an unbounded expansion entry")
        let retainedTask = model.rows.first!.event.taskID
        model.expandedWorkTasks.insert(retainedTask)
        await model.load(.around("response-work-metadata-0"), conversation: conversation)
        try check(model.expandedWorkTasks == [retainedTask], "retained older task lost expansion on repeated page refresh")

        // Cancel after the method captures its real version, before its detached read can
        // publish. The query stays real; a cancelled result cannot replace existing metadata.
        let cancelStore = try seed(directory, name: "work-cancel", tasks: 0)
        let cancelling = try SidekickConversation(cancelStore), cancelledModel = Presentation()
        let cancelTask = UUID()
        try cancelStore.appendBatch([
            Event(id: "cancel-request", taskID: cancelTask, kind: .userMessage, text: "Pending"),
            Event(id: "cancel-response", taskID: cancelTask, kind: .assistantMessage, text: "Partial")
        ])
        await cancelledModel.load(.latest, conversation: cancelling)
        cancelledModel.expandedWorkTasks.insert(cancelTask)
        try cancelStore.append(Event(id: "cancel-finish", taskID: cancelTask, kind: .taskFinished, text: "Done", outcome: .success))
        cancelling.revision &+= 1
        var cancelledRefresh: Task<Void, Never>?
        cancelling.onRevisionRead = { cancelledRefresh?.cancel() }
        cancelledRefresh = Task { await cancelledModel.refreshTaskStates(conversation: cancelling) }
        await cancelledRefresh!.value
        try check(cancelledModel.taskStates[cancelTask]?.finished == nil && cancelledModel.expandedWorkTasks == [cancelTask],
                  "cancelled metadata refresh published its result or changed expansion")
        cancelling.onRevisionRead = { cancelling.revision &+= 1 }
        await cancelledModel.refreshTaskStates(conversation: cancelling)
        try check(cancelledModel.taskStates[cancelTask]?.finished == nil, "concurrent revision change did not discard stale metadata snapshot")
        await cancelledModel.refreshTaskStates(conversation: cancelling)
        try check(cancelledModel.taskStates[cancelTask]?.finished?.event.id == "cancel-finish", "settled refresh could not recover after cancellation/version change")

        // Observe capture before resetting/replacing the real store. Either read ordering is
        // valid, but old results/errors must never survive after the newer generation settles.
        let resetStarted = AsyncStream<Void>.makeStream()
        cancelling.onRevisionRead = { resetStarted.continuation.yield(()) }
        let resetRefresh = Task { await cancelledModel.refreshTaskStates(conversation: cancelling) }
        for await _ in resetStarted.stream { break }
        try cancelStore.reset(); cancelling.generation = try cancelStore.generation
        cancelledModel.resetForGeneration(cancelling.generation)
        await resetRefresh.value; resetStarted.continuation.finish()
        try check(cancelledModel.rows.isEmpty && cancelledModel.taskStates.isEmpty && cancelledModel.expandedWorkTasks.isEmpty,
                  "reset metadata refresh reintroduced deleted tasks or expansion state")
        try check(cancelledModel.error == nil && cancelledModel.navigationTarget == nil,
                  "reset refresh restored a stale error or navigation state")
        try cancelStore.appendBatch([
            Event(id: "reused-request", taskID: cancelTask, kind: .userMessage, text: "New generation"),
            Event(id: "reused-response", taskID: cancelTask, kind: .assistantMessage, text: "New response")
        ])
        await cancelledModel.load(.latest, conversation: cancelling)
        try check(cancelledModel.expandedWorkTasks.isEmpty && cancelledModel.taskStates[cancelTask]?.finished == nil,
                  "reused task identity inherited old generation's work state")

        cancelledModel.expandedWorkTasks.insert(cancelTask)
        let replacement = try seed(directory, name: "work-replacement", tasks: 3)
        let replacedStarted = AsyncStream<Void>.makeStream()
        cancelling.onRevisionRead = { replacedStarted.continuation.yield(()) }
        let replacedRefresh = Task { await cancelledModel.refreshTaskStates(conversation: cancelling) }
        for await _ in replacedStarted.stream { break }
        cancelStore.close()
        cancelling.store = replacement; cancelling.generation = try replacement.generation
        cancelledModel.resetForGeneration(cancelling.generation)
        await cancelledModel.load(.latest, conversation: cancelling)
        await replacedRefresh.value; replacedStarted.continuation.finish()
        let expectedReplacementTasks = Set(try allTranscript(replacement).map { $0.event.taskID })
        try check(Set(cancelledModel.taskStates.keys) == expectedReplacementTasks && cancelledModel.taskStates[cancelTask] == nil,
                  "replaced-store worker restored old task metadata")
        try check(cancelledModel.expandedWorkTasks.isEmpty && cancelledModel.error == nil,
                  "replaced generation restored old expansions or worker errors")
    }

    static func briefing(_ date: Date?) {
        UserDefaults.standard.setVolatileDomain(date.map { [ProactiveCycle.lastCycleKey: $0] } ?? [:],
                                               forName: UserDefaults.argumentDomain)
    }

    static func visits(_ directory: URL) throws {
        let store = try Store(url: directory.appendingPathComponent("visits.sqlite"))
        let conversation = try SidekickConversation(store)
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let later = Calendar.current.date(byAdding: .day, value: 2, to: today)!
        briefing(today)
        let model = Presentation()
        model.visit(conversation: conversation, running: false, pending: false, now: today)
        try check(model.surface == .suggestions, "first safe visit opens proactive suggestions")
        model.surface = .conversation
        model.visit(conversation: conversation, running: false, pending: false, now: today)
        try check(model.surface == .conversation, "ordinary reopen preserves chat reading mode")
        briefing(tomorrow)
        model.visit(conversation: conversation, running: true, pending: false, now: tomorrow)
        try check(model.surface == .conversation, "active task takes precedence over new daily briefing")
        model.visit(conversation: conversation, running: false, pending: true, now: tomorrow)
        try check(model.surface == .conversation, "pending question takes precedence over new daily briefing")
        conversation.draft = "a draft worth keeping"
        model.visit(conversation: conversation, running: false, pending: false, now: tomorrow)
        try check(model.surface == .conversation && conversation.draft == "a draft worth keeping", "draft prevents automatic return to suggestions")
        conversation.draft = ""
        model.setSelection(true, messageID: "reading")
        model.visit(conversation: conversation, running: false, pending: false, now: tomorrow)
        try check(model.surface == .conversation, "selected text prevents automatic suggestions")
        model.setSelection(false, messageID: "reading")
        model.visit(conversation: conversation, running: false, pending: false, now: tomorrow)
        try check(model.surface == .suggestions, "first safe idle visit still receives deferred fresh briefing")
        model.surface = .conversation
        model.visit(conversation: conversation, running: false, pending: false, now: tomorrow)
        try check(model.surface == .conversation, "fresh briefing is shown only once on the same day")
        briefing(nil)
        model.visit(conversation: conversation, running: false, pending: false, now: later)
        try check(model.surface == .conversation, "new day without fresh briefing preserves conversation")

        let task = UUID()
        try store.appendBatch([
            Event(taskID: task, kind: .taskStarted, text: "Fixture"),
            Event(id: "unread-visit", taskID: task, kind: .assistantMessage, text: "An unread answer", priority: .high)
        ])
        briefing(later)
        model.visit(conversation: conversation, running: false, pending: false, now: later)
        try check(model.surface == .conversation, "new attention takes precedence over fresh daily suggestions")
        // Same unread record should not force a mode change every time Home reopens.
        model.surface = .suggestions
        model.visit(conversation: conversation, running: false, pending: false, now: later)
        try check(model.surface == .suggestions, "existing old unread attention does not override chosen suggestions")
        model.surface = .conversation
        model.visit(conversation: conversation, running: false, pending: false, now: later)
        try check(model.surface == .conversation, "ordinary reopen preserves reading even with old unread answer")
        model.surface = .suggestions
        conversation.navigationRequest = UUID()
        model.visit(conversation: conversation, running: false, pending: false, now: later)
        try check(model.surface == .conversation, "explicit notch/history navigation always opens chat")
        conversation.navigationRequest = nil
        try check(try store.unreadCount == 1, "visits never fabricate message read receipts")
    }

    static func resetOnboarding(_ directory: URL) async throws {
        let store = try seed(directory, name: "reset-onboarding", tasks: 6)
        let conversation = try SidekickConversation(store)
        let model = Presentation()
        let today = Date()
        briefing(nil)
        model.visit(conversation: conversation, running: false, pending: false, now: today)
        model.surface = .conversation
        await model.load(.latest, conversation: conversation)
        model.searchShown = true; model.clearChatConfirmationShown = true
        model.setSelection(true, messageID: "old-selected-message")
        try store.reset(); conversation.generation = try store.generation
        conversation.navigationRequest = nil; conversation.draft = ""
        // A mounted transcript has already reacted to the cleared SQLite generation. This
        // alone must not pretend that full app reset/navigation has occurred.
        model.resetForGeneration(conversation.generation)
        model.visit(conversation: conversation, running: false, pending: false, now: today)
        try check(model.surface == .conversation,
                  "regression prerequisite: clearing data alone retains this process's conversation surface")
        model.search = "old-query"
        let oldSearch = Task { await model.find(conversation: conversation) }
        try await Task.sleep(for: .milliseconds(30))
        model.didResetApp(generation: conversation.generation)
        await oldSearch.value
        try check(model.surface == .suggestions && model.cards.clearCount == 1,
                  "full reset returns to the first-Home invitation and discards old cards")
        try check(model.rows.isEmpty && model.searchResults.isEmpty && model.search.isEmpty
                    && !model.searchShown && !model.clearChatConfirmationShown && !model.textSelected,
                  "full reset clears conversation overlays even when generation was already observed")
        try check(model.error == nil && !model.loading && !model.composerFocused && model.atLatest,
                  "late search and old focus cannot restore the cleared conversation surface")
        model.visit(conversation: conversation, running: false, pending: false, now: today)
        try check(model.surface == .suggestions, "completing onboarding in the same process keeps first-Home invitation")
        model.surface = .conversation
        model.visit(conversation: conversation, running: false, pending: false, now: today)
        try check(model.surface == .conversation, "ordinary reopen still preserves explicitly chosen conversation")
        conversation.navigationRequest = UUID()
        model.didResetApp(generation: conversation.generation)
        model.visit(conversation: conversation, running: true, pending: false, now: today)
        try check(model.surface == .conversation, "genuine new work and navigation still take priority after reset")
    }

    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let store = try seed(directory, name: "history")
        try await paging(store)
        try await arrivals(directory)
        try await liveActivityFollowing(directory)
        try await completionAndActivationFollowing(directory)
        try await workMetadata(directory)
        try await searchAndReset(directory, store: store)
        try visits(directory)
        try await resetOnboarding(directory)
        print("PASS: \(checks) Sidekick presentation checks")
    }
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sentient-presentation-test-") as temporary:
        directory = Path(temporary)
        support = directory / "Support.swift"
        fixture = directory / "PresentationTests.swift"
        support.write_text(SUPPORT)
        fixture.write_text(TESTS)
        executable = directory / "presentation-tests"
        subprocess.run([
            "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
            "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
            str(APP / "Notch Magic/SidekickConversationStore.swift"),
            str(APP / "Views/Sidekick/SidekickPresentation.swift"), str(support), str(fixture),
            "-o", str(executable),
        ], check=True, timeout=60)
        subprocess.run([str(executable), str(directory)], check=True, timeout=40)


if __name__ == "__main__":
    main()
