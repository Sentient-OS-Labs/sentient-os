import SwiftUI
import AppKit

/// App-owned presentation survives closing Home, visiting Settings, and notch handoffs.
/// These values never control the lifetime or success of a provider task.
@MainActor @Observable
final class SidekickPresentation {
    enum Surface: String { case suggestions, conversation }
    enum Page: Sendable { case latest, earlier(Int64), later(Int64), around(String) }
    var surface: Surface = .suggestions
    let cards = ForYouModel()
    var windowActive = false
    var composerFocused = false
    var sendPulse = 0
    var scrollID: String?
    var atLatest = true
    var isScrolling = false
    private var selectedMessages = Set<String>()
    var textSelected: Bool { !selectedMessages.isEmpty }
    func setSelection(_ selected: Bool, messageID: String) {
        if selected { selectedMessages.insert(messageID) } else { selectedMessages.remove(messageID) }
    }
    var search = ""
    var searchShown = false
    var searchResults: [SidekickConversationStore.Record] = []
    var rows: [SidekickConversationStore.Record] = []
    var taskStates: [UUID: SidekickConversationStore.TranscriptTaskState] = [:]
    var expandedWorkTasks = Set<UUID>()
    var hasEarlier = false
    var hasLater = false
    var loading = false
    var error: String?
    var generation: UUID?
    var navigationTarget: String?
    var scrollRequest = 0
    var scrollIsAutomatic = false
    var newMessages = false
    var canFollowLatest: Bool { atLatest && !textSelected && !isScrolling && !hasLater }
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
        if case .latest = page { } else { atLatest = false }
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
            if generation != expected { rows = []; scrollID = nil }
            generation = expected
            taskStates = Dictionary(uniqueKeysWithValues: states.map { ($0.taskID, $0) })
            expandedWorkTasks.formIntersection(taskStates.keys)
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

    func resetForGeneration(_ next: UUID?) {
        guard generation != next else { return }
        loadToken &+= 1; searchToken &+= 1; loading = false; isScrolling = false
        rows = []; taskStates = [:]; expandedWorkTasks.removeAll()
        searchResults = []; search = ""; scrollID = nil; selectedMessages.removeAll()
        hasEarlier = false; hasLater = false; newMessages = false; navigationTarget = nil
        error = nil; generation = next; lastVisitedAttention = 0
    }
}
