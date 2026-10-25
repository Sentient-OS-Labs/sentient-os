import SwiftUI
import AppKit

/// App-owned presentation survives closing Home, visiting Settings, and notch handoffs.
/// These values never control the lifetime or success of a provider task.
@MainActor @Observable
final class SidekickPresentation {
    enum Surface: String { case suggestions, conversation }
    enum Page: Sendable { case latest, earlier(Int64), later(Int64), around(String) }
    enum WorkPage: Equatable, Sendable { case latest, before(Int64), after(Int64) }
    var surface: Surface = .suggestions
    let cards = ForYouModel()
    var windowActive = false
    var composerFocused = false
    var sendPulse = 0
    var atLatest = true
    var isScrolling = false
    // Viewport distance changes when content grows; only user intent relinquishes following.
    private(set) var followsLatest = true
    private(set) var readingIntentRevision = 0
    private(set) var latestWorkPageRevision = 0
    private var browsingWorkTasks = Set<UUID>()
    private var workPages: [UUID: WorkPage] = [:]
    private var selectedMessages = Set<String>()
    var textSelected: Bool { !selectedMessages.isEmpty }
    func setSelection(_ selected: Bool, messageID: String) {
        if selected {
            selectedMessages.insert(messageID)
            readingIntentRevision &+= 1
        } else { selectedMessages.remove(messageID) }
    }
    var clearChatConfirmationShown = false
    var search = ""
    var searchShown = false
    var searchResults: [SidekickConversationStore.Record] = []
    var rows: [SidekickConversationStore.Record] = []
    var taskStates: [UUID: SidekickConversationStore.TranscriptTaskState] = [:]
    var expandedWorkTasks = Set<UUID>()
    private(set) var activeWorkTaskID: UUID?
    private var automaticallyExpandedWorkTaskID: UUID?
    var hasEarlier = false
    var hasLater = false
    var loading = false
    var error: String?
    var generation: UUID?
    var navigationTarget: String?
    var scrollRequest = 0
    var scrollIsAutomatic = false
    var newMessages = false
    var canFollowLatest: Bool {
        followsLatest && !textSelected && !isScrolling && !hasLater && !searchShown
            && !(activeWorkTaskID.map { browsingWorkTasks.contains($0) } ?? false)
    }

    func userScrollChanged(_ scrolling: Bool, atLatest latest: Bool? = nil) {
        let wasScrolling = isScrolling
        if let latest { atLatest = latest && !hasLater }
        if scrolling && !wasScrolling { pauseAutomaticFollowing() }
        isScrolling = scrolling
        if !scrolling && wasScrolling { followsLatest = atLatest }
    }

    func viewportChanged(atLatest latest: Bool) {
        // Layout growth is not a gesture. Only a completed user scroll (or explicit latest
        // navigation) changes following intent, so late geometry cannot undo a manual pause.
        atLatest = latest && !hasLater
    }

    func pauseAutomaticFollowing() {
        followsLatest = false
        readingIntentRevision &+= 1
    }

    func browseWork(_ taskID: UUID) {
        browsingWorkTasks.insert(taskID)
        pauseAutomaticFollowing()
    }

    func workPage(_ taskID: UUID) -> WorkPage? { workPages[taskID] }
    func setWorkPage(_ page: WorkPage, taskID: UUID) {
        guard workPages[taskID] != page else { return }
        workPages[taskID] = page
    }

    func followLatestWork(_ taskID: UUID) {
        browsingWorkTasks.remove(taskID)
        workPages[taskID] = .latest
        if taskID == activeWorkTaskID { followsLatest = true }
    }

    func isBrowsingWork(_ taskID: UUID) -> Bool { browsingWorkTasks.contains(taskID) }

    static func workTailID(_ taskID: UUID) -> String { "sidekick-work-bottom-" + taskID.uuidString }

    /// Called after the current activity page changes. Queue a viewport request separately
    /// from message revisions so tool-only progress follows just like a new response.
    func activityDidChange(taskID: UUID, generation expected: UUID?, intent: Int) {
        guard expected == generation, taskID == activeWorkTaskID,
              expandedWorkTasks.contains(taskID), intent == readingIntentRevision,
              canFollowLatest else { return }
        enqueueFollowingScroll()
    }

    /// A hidden window may drop a scroll request before it can apply. Resume from
    /// current state on activation/completion, without changing the reader's intent.
    func resumeFollowing(generation expected: UUID?) {
        guard expected != nil, expected == generation, canFollowLatest,
              !rows.isEmpty || activeWorkTaskID != nil else { return }
        enqueueFollowingScroll()
    }

    private func enqueueFollowingScroll() {
        if let taskID = activeWorkTaskID, expandedWorkTasks.contains(taskID),
           !rows.contains(where: { $0.event.taskID == taskID && $0.event.kind == .assistantMessage && $0.event.messageKind == .answer }) {
            navigationTarget = Self.workTailID(taskID)
        } else {
            // message_user can publish the final answer before the process finishes.
            // Subsequent activity must not move following back above that response.
            navigationTarget = "sidekick-bottom"
        }
        scrollIsAutomatic = true
        scrollRequest &+= 1
    }
    private var loadToken = 0
    private var searchToken = 0
    private var visited = false
    private var lastVisitedAttention: Int64 = 0
    private var lastBriefing: Date?
    private var lastVisitDay: Date?

    func visit(conversation: SidekickConversation, running: Bool, pending: Bool, now: Date = Date()) {
        let day = Calendar.current.startOfDay(for: now)
        let briefing = UserDefaults.standard.object(forKey: ProactiveCycle.lastCycleKey) as? Date
        let attention = (try? conversation.store?.latestUnreadAttention?.sequence) ?? 0
        let newAttention = attention > lastVisitedAttention
        lastVisitedAttention = max(lastVisitedAttention, attention)
        if conversation.navigationRequest != nil || running || pending || newAttention {
            surface = .conversation
        } else if conversation.draft.isEmpty, !textSelected,
                  !visited || (day != lastVisitDay && briefing != nil && briefing != lastBriefing) {
            surface = .suggestions
        }
        visited = true
        if surface == .suggestions && !running && !pending && conversation.draft.isEmpty && !newAttention {
            lastVisitDay = day; lastBriefing = briefing
        }
    }

    func load(_ page: Page, conversation: SidekickConversation, animated: Bool = false, automaticallyFollowing: Bool = false) async {
        guard let store = conversation.store, let expected = conversation.generation else { return }
        loadToken &+= 1
        let token = loadToken
        let requestedRevision = conversation.revision
        let began = ContinuousClock.now
        // A deliberate history navigation takes ownership before its asynchronous read.
        // Incoming replies must not replace that destination while it is loading.
        if !automaticallyFollowing {
            readingIntentRevision &+= 1
            if case .latest = page {
                followsLatest = true
                if let activeWorkTaskID {
                    browsingWorkTasks.remove(activeWorkTaskID)
                    workPages[activeWorkTaskID] = .latest
                }
                latestWorkPageRevision &+= 1
            } else { atLatest = false; followsLatest = false }
        }
        loading = true
        defer { if token == loadToken { loading = false } }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                switch page {
                case .latest: return try store.transcriptPage()
                case .earlier(let cursor): return try store.transcriptPage(before: cursor)
                case .later(let cursor): return try store.transcriptPage(after: cursor)
                case .around(let id): return try store.transcriptAround(messageID: id)
                }
            }.value
            guard token == loadToken, !Task.isCancelled, conversation.generation == expected,
                  result.generation == expected else { return }
            let retained: [SidekickConversationStore.Record]
            switch page {
            case .earlier:
                retained = Array((result.records + rows.filter { row in !result.records.contains { $0.sequence == row.sequence } }).prefix(100))
            case .later:
                retained = Array((rows + result.records.filter { row in !rows.contains { $0.sequence == row.sequence } }).suffix(100))
            case .latest, .around: retained = result.records
            }
            let ids = Array(Set(retained.map { $0.event.taskID }))
            let states = try await Task.detached(priority: .userInitiated) {
                try store.transcriptTaskStates(taskIDs: ids, expectedGeneration: expected)
            }.value
            guard token == loadToken, !Task.isCancelled, conversation.generation == expected else { return }
            guard !automaticallyFollowing || canFollowLatest else { return }
            if generation != expected { rows = [] }
            generation = expected
            taskStates = Dictionary(uniqueKeysWithValues: states.map { ($0.taskID, $0) })
            var retainedWork = Set(taskStates.keys)
            if let activeWorkTaskID { retainedWork.insert(activeWorkTaskID) }
            expandedWorkTasks.formIntersection(retainedWork)
            workPages = workPages.filter { retainedWork.contains($0.key) }
            scrollIsAutomatic = automaticallyFollowing
            withAnimation(animated ? .spring(response: 0.42, dampingFraction: 0.92) : nil) {
            switch page {
            case .earlier:
                let anchor = rows.first?.event.id
                let joined = result.records + rows.filter { row in !result.records.contains { $0.sequence == row.sequence } }
                rows = Array(joined.prefix(100)); hasEarlier = result.hasEarlier
                hasLater = hasLater || joined.count > 100
                navigationTarget = anchor; scrollRequest &+= 1
            case .later:
                let anchor = rows.last?.event.id
                let joined = rows + result.records.filter { row in !rows.contains { $0.sequence == row.sequence } }
                rows = Array(joined.suffix(100)); hasLater = result.hasLater
                hasEarlier = hasEarlier || joined.count > 100
                navigationTarget = anchor; scrollRequest &+= 1
            case .around(let id):
                rows = result.records; hasEarlier = result.hasEarlier; hasLater = result.hasLater
                navigationTarget = id; scrollRequest &+= 1; atLatest = false
            case .latest:
                rows = result.records; hasEarlier = result.hasEarlier; hasLater = result.hasLater
                navigationTarget = "sidekick-bottom"; scrollRequest &+= 1
                // A commit during the read may be newer than this SQLite snapshot.
                // Keep it pending so reaching the bottom triggers another refresh.
                newMessages = conversation.revision != requestedRevision
            }
            error = nil
            }
            if case .latest = page { } else {
                let elapsed = began.duration(to: .now)
                SidekickDiagnostics.event(.historyRead, counts: [.messages: result.records.count],
                    duration: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            }
        } catch {
            guard token == loadToken, !Task.isCancelled, conversation.generation == expected else { return }
            self.error = "History couldn’t be loaded. Your existing data has been preserved."
            SidekickDiagnostics.failure(.historyRead, reason: .readFailed)
        }
    }

    func find(conversation: SidekickConversation) async {
        searchToken &+= 1
        let token = searchToken
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let store = conversation.store else { searchResults = []; return }
        let expected = conversation.generation
        do {
            try await Task.sleep(for: .milliseconds(240))
            let found = try await Task.detached(priority: .userInitiated) { try store.searchTranscript(query, limit: 30) }.value
            guard token == searchToken, !Task.isCancelled, conversation.generation == expected else { return }
            searchResults = found.filter { $0.event.kind != .checkpoint }
            error = nil
        } catch is CancellationError { }
        catch {
            guard token == searchToken, !Task.isCancelled, conversation.generation == expected else { return }
            self.error = "Search couldn’t be completed. Try again."
            SidekickDiagnostics.failure(.historyRead, reason: .readFailed)
        }
    }

    /// Update outcomes while a reader stays on an older page, without replacing rows or
    /// issuing a scroll request. Finishing a task must not leave its work header stale.
    func refreshTaskStates(conversation: SidekickConversation) async {
        guard let store = conversation.store, let expected = conversation.generation,
              generation == expected, !rows.isEmpty else { return }
        let token = loadToken, revision = conversation.revision
        let ids = Array(Set(rows.map { $0.event.taskID }))
        do {
            let states = try await Task.detached(priority: .userInitiated) {
                try store.transcriptTaskStates(taskIDs: ids, expectedGeneration: expected)
            }.value
            guard !Task.isCancelled, loadToken == token, conversation.generation == expected,
                  conversation.revision == revision else { return }
            taskStates = Dictionary(uniqueKeysWithValues: states.map { ($0.taskID, $0) })
        } catch {
            guard !Task.isCancelled, loadToken == token, conversation.generation == expected else { return }
            SidekickDiagnostics.failure(.historyRead, reason: .readFailed)
        }
    }

    /// Open each new live task once. Respect manual collapse, and fold the preceding
    /// automatically opened task when a new one starts. Explicitly opened history stays put.
    func followActiveWork(_ taskID: UUID?, generation: UUID?) {
        resetForGeneration(generation)
        guard taskID != activeWorkTaskID else { return }
        let previousTask = activeWorkTaskID
        activeWorkTaskID = taskID
        browsingWorkTasks.formIntersection(taskID.map { [$0] } ?? [])
        guard let taskID else {
            if previousTask != nil { resumeFollowing(generation: generation) }
            return
        }
        if let previous = automaticallyExpandedWorkTaskID, previous != taskID {
            expandedWorkTasks.remove(previous)
        }
        expandedWorkTasks.insert(taskID)
        automaticallyExpandedWorkTaskID = taskID
    }

    func toggleWork(_ taskID: UUID) {
        if !expandedWorkTasks.contains(taskID), taskID != activeWorkTaskID {
            // Opening completed work is deliberate reading. Its growing details should
            // stay in view rather than letting native bottom-follow pull the reader away.
            pauseAutomaticFollowing()
        }
        if automaticallyExpandedWorkTaskID == taskID { automaticallyExpandedWorkTaskID = nil }
        if expandedWorkTasks.contains(taskID) { expandedWorkTasks.remove(taskID) }
        else { expandedWorkTasks.insert(taskID) }
    }

    func didClearChat(generation: UUID?) {
        clearHistoryPresentation(generation: generation)
        searchShown = false; clearChatConfirmationShown = false
        atLatest = true; scrollIsAutomatic = false; composerFocused = false
        surface = .suggestions
    }

    /// Full Reset starts a new Home visit in this same app process. Ordinary window reopen
    /// still preserves the reader's surface; only the explicit reset discards that intent.
    func didResetApp(generation: UUID?) {
        didClearChat(generation: generation)
        cards.clear()
        visited = false; lastVisitedAttention = 0; lastBriefing = nil; lastVisitDay = nil
        sendPulse = 0
    }

    func resetForGeneration(_ next: UUID?) {
        guard generation != next else { return }
        clearHistoryPresentation(generation: next)
    }

    private func clearHistoryPresentation(generation next: UUID?) {
        loadToken &+= 1; searchToken &+= 1; loading = false; isScrolling = false
        rows = []; taskStates = [:]; expandedWorkTasks.removeAll()
        activeWorkTaskID = nil; automaticallyExpandedWorkTaskID = nil
        followsLatest = true; browsingWorkTasks.removeAll(); workPages.removeAll(); readingIntentRevision &+= 1
        latestWorkPageRevision &+= 1
        searchResults = []; search = ""; selectedMessages.removeAll()
        hasEarlier = false; hasLater = false; newMessages = false; navigationTarget = nil
        error = nil; generation = next; lastVisitedAttention = 0
    }
}
