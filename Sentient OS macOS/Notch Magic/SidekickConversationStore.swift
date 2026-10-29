// App-owned, provider-independent Sidekick history. A transaction commits before an event is
// published. Generation checks reject late callbacks after reset; task closure and event IDs
// prevent duplicate endings or rewritten history. Summaries never replace original records.

import Foundation
import SQLite3

extension Notification.Name {
    nonisolated static let sidekickConversationChanged = Notification.Name("SidekickConversationChanged")
}

nonisolated struct SidekickConversationEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case userMessage, assistantMessage, question, answer, taskStarted, taskFinished, activity, checkpoint
    }
    enum MessageKind: String, Codable, Sendable { case update, answer }
    enum Priority: String, Codable, Sendable { case normal, high }
    enum Outcome: String, Codable, Sendable { case success, failed, stopped, interrupted }

    struct ReplyReference: Codable, Equatable, Sendable {
        let messageID: String
        let selectedText: String?
        init(messageID: String, selectedText: String? = nil) {
            self.messageID = messageID; self.selectedText = selectedText
        }
    }

    /// Text excerpts only, never image/audio blobs or a raw provider envelope. The producer
    /// chooses a bounded description/result before appending; oversized content is rejected.
    struct Activity: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable { case started, completed, failed, interrupted }
        let toolID: String
        let name: String
        let arguments: String?
        let result: String?
        let status: Status
        init(toolID: String, name: String, arguments: String? = nil,
             result: String? = nil, status: Status) {
            self.toolID = toolID; self.name = name; self.arguments = arguments
            self.result = result; self.status = status
        }
    }

    let id: String
    let taskID: UUID
    let attemptID: UUID?
    let kind: Kind
    let text: String
    let createdAt: Date
    let source: String?
    let messageKind: MessageKind?
    let priority: Priority
    let outcome: Outcome?
    let reply: ReplyReference?
    let activity: Activity?
    let choices: [String]?

    init(id: String = UUID().uuidString, taskID: UUID, attemptID: UUID? = nil,
         kind: Kind, text: String = "", createdAt: Date = Date(), source: String? = nil,
         messageKind: MessageKind? = nil, priority: Priority = .normal,
         outcome: Outcome? = nil, reply: ReplyReference? = nil,
         activity: Activity? = nil, choices: [String]? = nil) {
        self.id = id; self.taskID = taskID; self.attemptID = attemptID; self.kind = kind
        self.text = text; self.createdAt = createdAt; self.source = source
        self.messageKind = kind == .assistantMessage ? (messageKind ?? .answer) : messageKind
        self.priority = priority; self.outcome = outcome; self.reply = reply
        self.activity = activity; self.choices = choices
    }
}

nonisolated final class SidekickConversationStore: @unchecked Sendable {
    struct Record: Codable, Equatable, Sendable {
        let sequence: Int64
        let event: SidekickConversationEvent
    }
    struct Summary: Codable, Equatable, Sendable {
        let generation: UUID
        let fromSequence: Int64
        let throughSequence: Int64
        let text: String
        let createdAt: Date
    }
    struct TranscriptPage: Sendable {
        let generation: UUID
        let records: [Record]
        let hasEarlier: Bool
        let hasLater: Bool
    }
    struct TranscriptTaskState: Sendable {
        let taskID: UUID
        let firstSequence: Int64
        let startedAt: Date?
        let hasActivity: Bool
        let finished: Record?
    }
    enum Failure: Error, LocalizedError {
        case closed
        case database(code: Int32, message: String)
        case unsupportedSchema(Int)
        case invalidSchema
        case invalidEvent(String)
        case duplicateEvent(String)
        case taskAlreadyFinished(UUID)
        case duplicateTaskStart(UUID)
        case staleGeneration
        case invalidReply
        case invalidReadReceipt
        case invalidWatermark
        case staleSummary
        case incompleteSummaryPrefix
        case corruptPayload

        var errorDescription: String? {
            switch self {
            case .closed: "Sidekick history is closed."
            case .database(let code, _): "Sidekick history could not be read or saved (database error \(code))."
            case .unsupportedSchema: "This Sidekick history was created by a newer version of Sentient."
            case .invalidSchema, .corruptPayload: "Sidekick history is unreadable. The existing file has been preserved."
            case .invalidEvent(let reason): "Sidekick could not save this history entry: \(reason)."
            case .duplicateEvent: "An existing Sidekick history entry cannot be changed."
            case .taskAlreadyFinished: "This Sidekick task has already ended."
            case .duplicateTaskStart: "This Sidekick task has already started."
            case .staleGeneration: "Sidekick history was reset while this work was running."
            case .invalidReply: "The message or selected text being replied to is unavailable."
            case .invalidReadReceipt: "That message is no longer available to mark as read."
            case .invalidWatermark: "The requested Sidekick history position is unavailable."
            case .staleSummary: "A newer Sidekick conversation summary is already saved."
            case .incompleteSummaryPrefix: "Sidekick cannot summarize a task that is still in progress."
            }
        }
    }

    static let maximumPageSize = 500
    static let maximumMessageBytes = 262_144
    static let maximumActivityTextBytes = 16_384
    static let maximumSummaryBytes = 65_536
    static let maximumTranscriptPageSize = 100
    private static let transcriptPredicate = "kind IN ('userMessage', 'assistantMessage', 'question', 'answer', 'taskFinished')"
    private static let schemaVersion = 1
    private static let identity = "sentient-sidekick-conversation-v1"
    let url: URL
    private let lock = NSLock()
    private var database: OpaquePointer?

    init(url: URL) throws {
        guard url.isFileURL else { throw Failure.invalidSchema }
        self.url = url
        let existed = FileManager.default.fileExists(atPath: url.path)
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database"
            if let opened { sqlite3_close_v2(opened) }
            throw Failure.database(code: status, message: message)
        }
        database = opened
        do {
            sqlite3_extended_result_codes(opened, 1)
            sqlite3_busy_timeout(opened, 5_000)
            // Restrict a newly created file before writing user content. Never repair permissions
            // on an existing read-only database behind the user's back.
            if !existed { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            // Check ownership/version before creating or migrating anything in an existing DB.
            try initializeSchema()
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA trusted_schema = OFF")
        } catch {
            sqlite3_close_v2(opened); database = nil
            throw error
        }
    }

    deinit { close() }

    /// Serialize with every read/write before unlinking app support during uninstall.
    /// Retained run/compactor references cannot reopen this handle or recreate its files.
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard let database else { return }
        sqlite3_close_v2(database)
        self.database = nil
    }

    var generation: UUID { get throws { try locked { try state().generation } } }
    var needsLegacyImport: Bool {
        get throws { try locked { try integer("SELECT legacy_imported FROM state WHERE singleton = 1") == 0 } }
    }
    var latestSequence: Int64 { get throws { try locked { try latest() } } }
    var readThroughSequence: Int64 { get throws { try locked { try state().readThrough } } }
    var summary: Summary? { get throws { try locked { try loadSummaries(limit: 1).first } } }

    /// Independently summarized segments, newest window in chronological order. Each segment
    /// names its exact source interval; older summaries are never rewritten into a rolling blob.
    func summaries(limit: Int = 8) throws -> [Summary] {
        return try locked {
            guard limit > 0 else { return [] }
            return try loadSummaries(limit: min(limit, Self.maximumPageSize)).reversed()
        }
    }

    /// Exact retries reuse their committed record. Changed payloads cannot replace an ID.
    /// Pass the launch generation from every asynchronous producer (including compactors).
    @discardableResult
    func append(_ event: SidekickConversationEvent, expectedGeneration: UUID? = nil) throws -> Record {
        try appendBatch([event], expectedGeneration: expectedGeneration)[0]
    }

    /// Atomic task start/message pairs, import batches, and terminal/status pairs. A failure
    /// anywhere rolls back the entire batch; no notification is sent for an uncommitted write.
    @discardableResult
    func appendBatch(_ events: [SidekickConversationEvent], expectedGeneration: UUID? = nil) throws -> [Record] {
        try locked { }
        let encoded = try Self.encodeBatch(events)
        let result = try locked {
            try transaction {
                try checkGeneration(expectedGeneration)
                return try zip(events, encoded).map { try insert($0.0, encoded: $0.1) }
            }
        }
        if result.contains(where: \.inserted) { publish() }
        return result.map(\.record)
    }

    /// The caller converts legacy entries and removes their source only after this succeeds.
    /// The completion flag shares the event transaction, so crash/retry cannot import twice.
    /// Reset keeps this flag set, preventing any stale legacy source from reviving deleted data.
    @discardableResult
    func importLegacy(events: [SidekickConversationEvent]) throws -> Bool {
        let imported = try locked {
            try transaction {
                guard try integer("SELECT legacy_imported FROM state WHERE singleton = 1") == 0 else { return false }
                let encoded = try Self.encodeBatch(events)
                for (event, payload) in zip(events, encoded) { _ = try insert(event, encoded: payload) }
                try execute("UPDATE state SET legacy_imported = 1 WHERE singleton = 1")
                return true
            }
        }
        if imported { publish() }
        return imported
    }

    func record(id: String) throws -> Record? {
        try locked { try queryRecords("SELECT sequence, payload FROM events WHERE id = ?", [.text(id)]).first }
    }

    /// Resolve the persisted identity rather than assuming a generated ID prefix. Legacy
    /// imports and callers that supplied their own IDs still expose a readable task request.
    func taskStart(taskID: UUID) throws -> Record? {
        try locked {
            try queryRecords("SELECT events.sequence, events.payload FROM tasks JOIN events ON events.sequence = tasks.started_sequence WHERE tasks.task_id = ?",
                [.text(taskID.uuidString)]).first
        }
    }

    /// Ascending sequence order; callers can continue after the last returned sequence.
    func records(taskID: UUID? = nil, after sequence: Int64 = 0, limit: Int = 200) throws -> [Record] {
        return try locked {
            guard limit > 0 else { return [] }
            var sql = "SELECT sequence, payload FROM events WHERE sequence > ?"
            var values: [Value] = [.integer(max(0, sequence))]
            if let taskID { sql += " AND task_id = ?"; values.append(.text(taskID.uuidString)) }
            sql += " ORDER BY sequence ASC LIMIT ?"
            values.append(.integer(Int64(min(limit, Self.maximumPageSize))))
            return try queryRecords(sql, values)
        }
    }

    /// UI transcript pagination is independent of model-context selection. Cursors are
    /// exclusive. Filter visible kinds before LIMIT so tool-heavy tasks cannot empty a page.
    /// Exact text is retained; one nearest record may exceed the budget to guarantee progress.
    func transcriptPage(before: Int64? = nil, after: Int64? = nil, limit: Int = 40,
                        byteBudget: Int = 1_048_576) throws -> TranscriptPage {
        try locked {
            try readSnapshot {
                guard before == nil || after == nil, before.map({ $0 >= 0 }) ?? true,
                      after.map({ $0 >= 0 }) ?? true else { throw Failure.invalidWatermark }
                let generation = try state().generation
                guard limit > 0 else { return TranscriptPage(generation: generation, records: [], hasEarlier: false, hasLater: false) }
                let direction = after == nil ? "DESC" : "ASC"
                let clause = before != nil ? " AND sequence < ?" : (after != nil ? " AND sequence > ?" : "")
                let values = (before ?? after).map { [Value.integer($0)] } ?? []
                let candidates = try transcriptSizes(clause: clause, values: values, direction: direction,
                                                     limit: min(limit, Self.maximumTranscriptPageSize))
                let budget = max(1, min(byteBudget, 4_194_304))
                var selected: [Int64] = [], bytes = 0
                for candidate in candidates {
                    guard selected.isEmpty || bytes + candidate.bytes <= budget else { break }
                    selected.append(candidate.sequence); bytes += candidate.bytes
                }
                return try transcriptResult(sequences: selected, generation: generation,
                    emptyBefore: before, emptyAfter: after)
            }
        }
    }

    /// A search/notch destination loads a bounded contiguous neighborhood, always containing
    /// the exact target. Activity, checkpoints and task-start payloads are not UI destinations.
    func transcriptAround(messageID: String, limit: Int = 40,
                          byteBudget: Int = 1_048_576) throws -> TranscriptPage {
        try locked {
            try readSnapshot {
                guard !messageID.isEmpty, messageID.utf8.count <= 512, limit > 0 else { throw Failure.invalidReply }
                let generation = try state().generation
                let target = try transcriptSizes(clause: " AND id = ?", values: [.text(messageID)], direction: "ASC", limit: 1)
                guard let target = target.first else { throw Failure.invalidReply }
                let count = min(limit, Self.maximumTranscriptPageSize)
                let before = try transcriptSizes(clause: " AND sequence < ?", values: [.integer(target.sequence)], direction: "DESC", limit: count - 1)
                let after = try transcriptSizes(clause: " AND sequence > ?", values: [.integer(target.sequence)], direction: "ASC", limit: count - 1)
                let budget = max(1, min(byteBudget, 4_194_304))
                var selected = [target.sequence], bytes = target.bytes
                var left = 0, right = 0, takeLeft = true
                while selected.count < count, left < before.count || right < after.count {
                    let chooseLeft = left < before.count && (takeLeft || right >= after.count)
                    let candidate = chooseLeft ? before[left] : after[right]
                    if bytes + candidate.bytes <= budget {
                        selected.append(candidate.sequence); bytes += candidate.bytes
                        if chooseLeft { left += 1 } else { right += 1 }
                    } else {
                        // Do not jump over an oversized neighbor; that would create a hidden gap.
                        if chooseLeft { left = before.count } else { right = after.count }
                    }
                    takeLeft = !chooseLeft
                }
                return try transcriptResult(sequences: selected, generation: generation)
            }
        }
    }

    /// Resolve task metadata in one bounded read snapshot, even for a page cut mid-task.
    /// No activity payload is decoded. Missing and synthetic legacy starts stay unknown,
    /// rather than borrowing request timestamps; only the app identifies currently live work.
    func transcriptTaskStates(taskIDs: [UUID], expectedGeneration: UUID? = nil) throws -> [TranscriptTaskState] {
        try locked {
            try readSnapshot {
                try checkGeneration(expectedGeneration)
                let ids = Array(Set(taskIDs)).sorted { $0.uuidString < $1.uuidString }
                guard ids.count <= Self.maximumTranscriptPageSize else { throw Failure.invalidEvent("too many visible tasks") }
                guard !ids.isEmpty else { return [] }
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let statement = try prepare("""
                    SELECT ended.sequence, ended.payload, tasks.task_id, tasks.first_sequence,
                           tasks.started_sequence, started.kind, started.task_id,
                           json_extract(CAST(started.payload AS TEXT), '$.createdAt'),
                           EXISTS (SELECT 1 FROM events AS activity
                               WHERE activity.task_id = tasks.task_id AND activity.kind = 'activity'
                               AND activity.text NOT IN (
                                   'sentient_recovery.describe_task_usage', 'mcp__sentient_recovery__describe_task_usage',
                                   'sentient_recovery.message_user', 'mcp__sentient_recovery__message_user',
                                   'sentient_recovery.read_history', 'mcp__sentient_recovery__read_history',
                                   'sentient_recovery.search_history', 'mcp__sentient_recovery__search_history')),
                           started.id
                    FROM tasks
                    LEFT JOIN events AS ended ON ended.sequence = tasks.finished_sequence
                    LEFT JOIN events AS started ON started.sequence = tasks.started_sequence
                    WHERE tasks.task_id IN (\(placeholders)) ORDER BY tasks.first_sequence
                    """, ids.map { .text($0.uuidString) })
                defer { sqlite3_finalize(statement) }
                var result: [TranscriptTaskState] = []
                while try step(statement) {
                    guard let id = UUID(uuidString: try string(statement, 2)) else { throw Failure.corruptPayload }
                    let first = sqlite3_column_int64(statement, 3)
                    guard first > 0 else { throw Failure.corruptPayload }
                    let finished = sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : try decodeRecord(statement)
                    guard finished == nil || (finished?.event.kind == .taskFinished && finished?.event.taskID == id) else { throw Failure.corruptPayload }
                    let startedAt: Date?
                    if sqlite3_column_type(statement, 4) == SQLITE_NULL { startedAt = nil }
                    else {
                        guard try string(statement, 5) == SidekickConversationEvent.Kind.taskStarted.rawValue,
                              try string(statement, 6) == id.uuidString,
                              [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(statement, 7)) else { throw Failure.corruptPayload }
                        let seconds = sqlite3_column_double(statement, 7)
                        guard seconds.isFinite else { throw Failure.corruptPayload }
                        // Imported legacy starts are structural anchors synthesized from a
                        // request date, not measured execution starts. Never invent a duration.
                        let startID = try string(statement, 9)
                        // The persisted Codable event uses JSONEncoder's default Date strategy.
                        startedAt = startID.hasPrefix("legacy-start:") ? nil : Date(timeIntervalSinceReferenceDate: seconds)
                    }
                    result.append(TranscriptTaskState(taskID: id, firstSequence: first, startedAt: startedAt,
                        hasActivity: sqlite3_column_int(statement, 8) != 0, finished: finished))
                }
                return result
            }
        }
    }

    // Payload lengths are inspected before decoding, bounding memory even for very long answers.
    private func transcriptSizes(clause: String, values: [Value], direction: String,
                                 limit: Int) throws -> [(sequence: Int64, bytes: Int)] {
        guard limit > 0 else { return [] }
        let statement = try prepare("SELECT sequence, length(payload) FROM events WHERE \(Self.transcriptPredicate)\(clause) ORDER BY sequence \(direction) LIMIT ?", values + [.integer(Int64(limit))])
        defer { sqlite3_finalize(statement) }
        var result: [(sequence: Int64, bytes: Int)] = []
        while try step(statement) {
            let sequence = sqlite3_column_int64(statement, 0), bytes = sqlite3_column_int64(statement, 1)
            guard sequence > 0, bytes > 0, bytes <= 524_288 else { throw Failure.corruptPayload }
            result.append((sequence, Int(bytes)))
        }
        return result
    }

    private func transcriptResult(sequences: [Int64], generation: UUID,
                                  emptyBefore: Int64? = nil, emptyAfter: Int64? = nil) throws -> TranscriptPage {
        guard !sequences.isEmpty else {
            let earlier = try emptyAfter.map { try integer("SELECT EXISTS(SELECT 1 FROM events WHERE \(Self.transcriptPredicate) AND sequence <= ?)", [.integer($0)]) != 0 } ?? false
            let later = try emptyBefore.map { try integer("SELECT EXISTS(SELECT 1 FROM events WHERE \(Self.transcriptPredicate) AND sequence >= ?)", [.integer($0)]) != 0 } ?? false
            return TranscriptPage(generation: generation, records: [], hasEarlier: earlier, hasLater: later)
        }
        let placeholders = Array(repeating: "?", count: sequences.count).joined(separator: ",")
        let records = try queryRecords("SELECT sequence, payload FROM events WHERE sequence IN (\(placeholders)) ORDER BY sequence ASC", sequences.map(Value.integer))
        guard records.count == sequences.count, let first = records.first, let last = records.last else { throw Failure.corruptPayload }
        let earlier = try integer("SELECT EXISTS(SELECT 1 FROM events WHERE \(Self.transcriptPredicate) AND sequence < ?)", [.integer(first.sequence)]) != 0
        let later = try integer("SELECT EXISTS(SELECT 1 FROM events WHERE \(Self.transcriptPredicate) AND sequence > ?)", [.integer(last.sequence)]) != 0
        return TranscriptPage(generation: generation, records: records, hasEarlier: earlier, hasLater: later)
    }

    /// Latest task window with activity excluded at the database boundary. When a task is
    /// chatty, preserve requests and final outcomes before progress so the bounded page cannot
    /// lose all fifteen request anchors. The selected source records stay chronological.
    func contextRecords(taskLimit: Int = 15, after sequence: Int64 = 0, limit: Int = 300) throws -> [Record] {
        return try locked {
            guard taskLimit > 0, limit > 0 else { return [] }
            return try queryRecords("""
                WITH recent_tasks AS (SELECT task_id FROM tasks ORDER BY last_sequence DESC LIMIT ?)
                SELECT sequence, payload FROM (
                    SELECT events.sequence, events.payload FROM events JOIN recent_tasks USING(task_id)
                    WHERE sequence > ? AND kind != 'activity'
                    ORDER BY CASE
                        WHEN kind = 'userMessage' THEN 0
                        WHEN kind = 'taskFinished' OR (kind = 'assistantMessage'
                            AND json_extract(CAST(payload AS TEXT), '$.messageKind') = 'answer') THEN 1
                        WHEN kind IN ('question', 'answer', 'checkpoint') THEN 2
                        WHEN kind = 'assistantMessage' THEN 3
                        ELSE 4 END ASC, sequence DESC LIMIT ?
                ) ORDER BY sequence ASC
                """, [.integer(Int64(min(taskLimit, Self.maximumPageSize))), .integer(max(0, sequence)),
                       .integer(Int64(min(limit, Self.maximumPageSize)))])
        }
    }

    /// Ascending filtered cursor page for the compactor. The caller chooses a completed-task
    /// boundary, paging further when necessary. installSummary verifies that boundary again.
    func contextRecordsForCompaction(after sequence: Int64 = 0, limit: Int = 300) throws -> [Record] {
        return try locked {
            guard limit > 0 else { return [] }
            return try queryRecords("SELECT sequence, payload FROM events WHERE sequence > ? AND kind != 'activity' ORDER BY sequence ASC LIMIT ?",
                [.integer(max(0, sequence)), .integer(Int64(min(limit, Self.maximumPageSize)))])
        }
    }

    /// Highest completed prefix before both the retained recent tasks and any unfinished task.
    /// The NOT EXISTS clause also handles interleaved attempts: a later task's end cannot split
    /// an earlier task. A single statement observes one SQLite snapshot across open handles.
    func compactionBoundary(keepingRecentTasks: Int = 15) throws -> Int64? {
        try locked {
            let sequence = try integer("""
                WITH protected AS (
                    SELECT first_sequence FROM tasks WHERE finished_sequence IS NULL
                    UNION ALL
                    SELECT first_sequence FROM (SELECT first_sequence FROM tasks ORDER BY last_sequence DESC LIMIT ?)
                )
                SELECT COALESCE(MAX(candidate.finished_sequence), 0) FROM tasks AS candidate
                WHERE candidate.finished_sequence < COALESCE((SELECT MIN(first_sequence) FROM protected), 9223372036854775807)
                AND NOT EXISTS (
                    SELECT 1 FROM tasks AS earlier WHERE earlier.first_sequence <= candidate.finished_sequence
                    AND (earlier.finished_sequence IS NULL OR earlier.finished_sequence > candidate.finished_sequence)
                )
                """, [.integer(Int64(max(0, min(keepingRecentTasks, 1_000))))])
            return sequence > 0 ? sequence : nil
        }
    }

    /// The latest window, returned in conversation order rather than newest-first.
    func recent(limit: Int = 100) throws -> [Record] {
        return try locked {
            guard limit > 0 else { return [] }
            return try queryRecords("SELECT sequence, payload FROM (SELECT sequence, payload FROM events ORDER BY sequence DESC LIMIT ?) ORDER BY sequence ASC",
                [.integer(Int64(min(limit, Self.maximumPageSize)))])
        }
    }

    /// Literal substring search of recorded message/checkpoint text; SQL wildcard characters
    /// in the user's query remain literal. Results are newest first and bounded.
    func search(_ query: String, limit: Int = 50) throws -> [Record] {
        try searchRecords(query, limit: limit, conversationOnly: false)
    }

    /// Apply the conversation-kind restriction before LIMIT, so matching tool activity cannot
    /// hide an earlier answer. Generic search remains available to the activity/history UI.
    func searchConversation(_ query: String, limit: Int = 50) throws -> [Record] {
        try searchRecords(query, limit: limit, conversationOnly: true)
    }

    /// UI search returns only navigable transcript rows. Internal checkpoints cannot crowd
    /// the visible matches out of the bounded result set or become invalid jump destinations.
    func searchTranscript(_ query: String, limit: Int = 40) throws -> [Record] {
        try searchRecords(query, limit: min(limit, Self.maximumTranscriptPageSize), conversationOnly: false, transcriptOnly: true)
    }

    private func searchRecords(_ query: String, limit: Int, conversationOnly: Bool, transcriptOnly: Bool = false) throws -> [Record] {
        try locked { }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        guard query.utf8.count <= 4_096 else { throw Failure.invalidEvent("search text is too long") }
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try locked {
            let kinds = transcriptOnly ? " AND " + Self.transcriptPredicate : conversationOnly
                ? " AND kind IN ('userMessage', 'assistantMessage', 'question', 'answer', 'taskFinished', 'checkpoint')" : ""
            return try queryRecords("SELECT sequence, payload FROM events WHERE text LIKE ? ESCAPE '\\'" + kinds + " ORDER BY sequence DESC LIMIT ?",
                [.text("%" + escaped + "%"), .integer(Int64(min(limit, Self.maximumPageSize)))])
        }
    }

    /// Questions cease to be actionable after their answer or task termination. Their exact
    /// text remains in history, but restart/Stop must never revive a dead user-input request.
    private static let unreadPredicate = """
        events.sequence > (SELECT read_through FROM state WHERE singleton = 1)
        AND events.kind IN ('assistantMessage', 'question')
        AND NOT EXISTS (SELECT 1 FROM read_events WHERE read_events.sequence = events.sequence)
        AND (events.kind = 'assistantMessage' OR (events.kind = 'question'
            AND EXISTS (SELECT 1 FROM tasks WHERE tasks.task_id = events.task_id AND finished_sequence IS NULL)
            AND NOT EXISTS (SELECT 1 FROM events AS answer WHERE answer.kind = 'answer'
                AND json_extract(CAST(answer.payload AS TEXT), '$.reply.messageID') = events.id)))
        """

    func unread(limit: Int = 100) throws -> [Record] {
        return try locked {
            guard limit > 0 else { return [] }
            return try queryRecords("SELECT sequence, payload FROM events WHERE " + Self.unreadPredicate + " ORDER BY sequence ASC LIMIT ?",
                [.integer(Int64(min(limit, Self.maximumPageSize)))])
        }
    }

    /// Counting is independent of pagination: old unseen messages cannot hide a new answer.
    var unreadCount: Int {
        get throws {
            try locked {
                Int(try integer("SELECT COUNT(*) FROM events WHERE " + Self.unreadPredicate))
            }
        }
    }

    /// Filter attention intent before selecting the newest record. Fetching the first unread
    /// page and taking its last answer would pin attention to old history after that page fills.
    var latestUnreadAttention: Record? {
        get throws {
            try locked {
                try queryRecords("""
                    SELECT sequence, payload FROM events
                    WHERE \(Self.unreadPredicate)
                      AND (kind = 'question' OR json_extract(CAST(payload AS TEXT), '$.priority') = 'high'
                        OR json_extract(CAST(payload AS TEXT), '$.messageKind') = 'answer')
                    ORDER BY sequence DESC LIMIT 1
                    """).first
            }
        }
    }

    /// Notch attention selects explicit high-priority messages independently of newer normal
    /// answers or questions. The coordinator separately owns live question precedence.
    var latestUnreadHighPriorityMessage: Record? {
        get throws {
            try locked {
                try queryRecords("""
                    SELECT sequence, payload FROM events
                    WHERE \(Self.unreadPredicate)
                      AND kind = 'assistantMessage'
                      AND json_extract(CAST(payload AS TEXT), '$.priority') = 'high'
                    ORDER BY sequence DESC LIMIT 1
                    """).first
            }
        }
    }

    /// The cursor counts activity records, not an arbitrary mixed page that can be empty
    /// after filtering even though this task has later tool operations.
    func activityRecords(taskID: UUID, after sequence: Int64 = 0, limit: Int = 200) throws -> [Record] {
        return try locked {
            guard limit > 0 else { return [] }
            return try queryRecords("SELECT sequence, payload FROM events WHERE task_id = ? AND sequence > ? AND kind = 'activity' ORDER BY sequence ASC LIMIT ?",
                [.text(taskID.uuidString), .integer(max(0, sequence)), .integer(Int64(min(limit, Self.maximumPageSize)))])
        }
    }

    /// A bounded activity window, independent of transcript pagination. Active work follows
    /// the latest window; explicit before/after cursors let readers inspect older steps without
    /// loading every operation or losing their place when more work arrives.
    func activityPage(taskID: UUID, before: Int64? = nil, after: Int64? = nil,
                      limit: Int = 40) throws -> TranscriptPage {
        try locked {
            try readSnapshot {
                guard before == nil || after == nil, before.map({ $0 >= 0 }) ?? true,
                      after.map({ $0 >= 0 }) ?? true else { throw Failure.invalidWatermark }
                let generation = try state().generation
                guard limit > 0 else { return TranscriptPage(generation: generation, records: [], hasEarlier: false, hasLater: false) }
                let direction = after == nil ? "DESC" : "ASC"
                let clause = before != nil ? " AND sequence < ?" : (after != nil ? " AND sequence > ?" : "")
                var values: [Value] = [.text(taskID.uuidString)]
                if let cursor = before ?? after { values.append(.integer(cursor)) }
                values.append(.integer(Int64(min(limit, Self.maximumTranscriptPageSize))))
                let selected = try queryRecords("SELECT sequence, payload FROM events WHERE task_id = ? AND kind = 'activity'" + clause + " ORDER BY sequence " + direction + " LIMIT ?", values)
                let records = after == nil ? Array(selected.reversed()) : selected
                let low = records.first?.sequence ?? after ?? 0
                let high = records.last?.sequence ?? before ?? Int64.max
                let earlierComparison = records.isEmpty && after != nil ? " <= " : " < "
                let laterComparison = records.isEmpty && before != nil ? " >= " : " > "
                let earlier = try integer("SELECT EXISTS(SELECT 1 FROM events WHERE task_id = ? AND kind = 'activity' AND sequence" + earlierComparison + "?)",
                    [.text(taskID.uuidString), .integer(low)]) != 0
                let later = try integer("SELECT EXISTS(SELECT 1 FROM events WHERE task_id = ? AND kind = 'activity' AND sequence" + laterComparison + "?)",
                    [.text(taskID.uuidString), .integer(high)]) != 0
                return TranscriptPage(generation: generation, records: records, hasEarlier: earlier, hasLater: later)
            }
        }
    }

    /// One indexed row for the live notch; never load a task's full activity history.
    func latestActivity(taskID: UUID) throws -> Record? {
        try locked {
            try queryRecords("SELECT sequence, payload FROM events WHERE task_id=? AND kind='activity' ORDER BY sequence DESC LIMIT 1",
                [.text(taskID.uuidString)]).first
        }
    }

    func markRead(throughSequence: Int64, expectedGeneration: UUID? = nil) throws {
        let changed = try locked {
            try transaction {
                try checkGeneration(expectedGeneration)
                guard throughSequence >= 0, throughSequence <= (try latest()) else { throw Failure.invalidWatermark }
                let current = try state().readThrough
                guard throughSequence > current else { return false }
                try execute("UPDATE state SET read_through = ? WHERE singleton = 1", [.integer(throughSequence)])
                return true
            }
        }
        if changed { publish() }
    }

    /// Exact viewport receipts do not mark skipped older answers as read. The legacy watermark
    /// remains supported for existing callers and already-read history from earlier versions.
    func markRead(messageIDs: [String], expectedGeneration: UUID) throws {
        let changed = try locked {
            try transaction {
                try checkGeneration(expectedGeneration)
                let ids = Array(Set(messageIDs)).sorted()
                guard ids.count <= Self.maximumTranscriptPageSize,
                      ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else { throw Failure.invalidReadReceipt }
                var changed = false
                for id in ids {
                    guard let record = try queryRecords("SELECT sequence, payload FROM events WHERE id = ?", [.text(id)]).first,
                          [.assistantMessage, .question].contains(record.event.kind) else { throw Failure.invalidReadReceipt }
                    try execute("INSERT OR IGNORE INTO read_events(sequence) VALUES(?)", [.integer(record.sequence)])
                    if sqlite3_changes(database) > 0 { changed = true }
                }
                return changed
            }
        }
        if changed { publish() }
    }

    /// Install only a complete, immutable prefix. Messages arriving beyond the watermark do
    /// not invalidate it. A slower old compactor cannot replace a later accepted summary.
    func installSummary(generation: UUID, throughSequence: Int64, text: String,
                        expectedFromSequence: Int64? = nil) throws {
        try locked { }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maximumSummaryBytes else { throw Failure.invalidEvent("summary is empty or too long") }
        let changed = try locked {
            try transaction {
                let current = try state()
                guard current.generation == generation else { throw Failure.staleGeneration }
                guard throughSequence > 0, throughSequence <= (try latest()) else { throw Failure.invalidWatermark }
                let previous = try loadSummaries(limit: 1).first
                if let previous {
                    if throughSequence == previous.throughSequence, text == previous.text,
                       expectedFromSequence == nil || expectedFromSequence == previous.fromSequence { return false }
                    guard throughSequence > previous.throughSequence else { throw Failure.staleSummary }
                }
                let from = previous.map { $0.throughSequence + 1 } ?? 1
                if let expectedFromSequence, expectedFromSequence != from { throw Failure.staleSummary }
                let incomplete = try integer("SELECT COUNT(*) FROM tasks WHERE first_sequence <= ? AND (finished_sequence IS NULL OR finished_sequence > ?)",
                    [.integer(throughSequence), .integer(throughSequence)])
                guard incomplete == 0 else { throw Failure.incompleteSummaryPrefix }
                try execute("INSERT INTO summaries(from_sequence, through_sequence, text, created_at) VALUES(?, ?, ?, ?)",
                    [.integer(from), .integer(throughSequence), .text(text), .real(Date().timeIntervalSince1970)])
                return true
            }
        }
        if changed { publish() }
    }

    /// Preserve the file/schema and invalidate every old producer before allowing new writes.
    func reset() throws {
        try locked {
            try transaction {
                try execute("DELETE FROM summaries")
                try execute("DELETE FROM read_events")
                try execute("DELETE FROM tasks")
                try execute("DELETE FROM events")
                try execute("DELETE FROM sqlite_sequence WHERE name = 'events'")
                try execute("UPDATE state SET generation = ?, legacy_imported = 1, read_through = 0 WHERE singleton = 1",
                    [.text(UUID().uuidString)])
            }
        }
        publish()
    }

    /// Called by the sole app owner at startup or before a new task with no active producer,
    /// never by ordinary store construction or by an independent open handle.
    /// No task is resumed and no outcome is inferred from its last narration.
    @discardableResult
    func recoverInterruptedTasks() throws -> [Record] {
        let records = try locked {
            try transaction {
                let generation = try state().generation
                let statement = try prepare("SELECT task_id FROM tasks WHERE finished_sequence IS NULL ORDER BY first_sequence ASC")
                var tasks: [UUID] = []
                do {
                    defer { sqlite3_finalize(statement) }
                    while try step(statement) {
                        guard let id = UUID(uuidString: try string(statement, 0)) else { throw Failure.corruptPayload }
                        tasks.append(id)
                    }
                }
                return try tasks.map { id in
                    let event = SidekickConversationEvent(id: "recovered:\(generation.uuidString):\(id.uuidString)",
                        taskID: id, kind: .taskFinished, text: "Interrupted before a durable result was saved; completed effects are not confirmed.",
                        source: "app_recovery", outcome: .interrupted)
                    return try insert(event, encoded: Self.encode(event)).record
                }
            }
        }
        if !records.isEmpty { publish() }
        return records
    }

    // MARK: Transaction and schema ownership

    private struct State {
        let generation: UUID
        let readThrough: Int64
    }

    private func initializeSchema() throws {
        try transaction {
            let version = Int(try integer("PRAGMA user_version"))
            if version == 0 {
                guard try integer("SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0 else {
                    throw Failure.invalidSchema
                }
                try execute("CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, task_id TEXT NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL, payload BLOB NOT NULL)")
                try execute("CREATE INDEX events_task_sequence ON events(task_id, sequence)")
                try execute("CREATE TABLE tasks (task_id TEXT PRIMARY KEY NOT NULL, first_sequence INTEGER NOT NULL REFERENCES events(sequence), last_sequence INTEGER NOT NULL REFERENCES events(sequence), started_sequence INTEGER REFERENCES events(sequence), finished_sequence INTEGER REFERENCES events(sequence))")
                try execute("CREATE TABLE state (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), identity TEXT NOT NULL, generation TEXT NOT NULL, legacy_imported INTEGER NOT NULL DEFAULT 0 CHECK (legacy_imported IN (0, 1)), read_through INTEGER NOT NULL DEFAULT 0)")
                try execute("CREATE INDEX tasks_recent ON tasks(last_sequence)")
                try execute("CREATE INDEX tasks_first ON tasks(first_sequence)")
                try execute("CREATE TABLE summaries (from_sequence INTEGER PRIMARY KEY CHECK (from_sequence > 0), through_sequence INTEGER NOT NULL UNIQUE CHECK (through_sequence >= from_sequence), text TEXT NOT NULL, created_at REAL NOT NULL)")
                try execute("INSERT INTO state(singleton, identity, generation, read_through) VALUES(1, ?, ?, 0)",
                    [.text(Self.identity), .text(UUID().uuidString)])
                try execute("PRAGMA user_version = \(Self.schemaVersion)")
            } else {
                guard version == Self.schemaVersion else { throw Failure.unsupportedSchema(version) }
            }
            let identity = try prepare("SELECT identity FROM state WHERE singleton = 1")
            defer { sqlite3_finalize(identity) }
            guard try step(identity), try string(identity, 0) == Self.identity,
                  try integer("SELECT COUNT(*) FROM state") == 1 else { throw Failure.invalidSchema }
            _ = try state()
            // Preparing these verifies every required column without mutating existing data.
            for sql in ["SELECT sequence, id, task_id, kind, text, payload FROM events LIMIT 0",
                        "SELECT task_id, first_sequence, last_sequence, started_sequence, finished_sequence FROM tasks LIMIT 0",
                        "SELECT from_sequence, through_sequence, text, created_at FROM summaries LIMIT 0",
                        "SELECT legacy_imported FROM state LIMIT 0"] {
                let statement = try prepare(sql); sqlite3_finalize(statement)
            }
            // Compatible additive v1 extension: older builds can ignore exact read receipts.
            // Verify an existing table instead of accepting a similarly named incompatible object.
            try execute("CREATE TABLE IF NOT EXISTS read_events (sequence INTEGER PRIMARY KEY REFERENCES events(sequence) ON DELETE CASCADE)")
            guard try integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'read_events'") == 1 else { throw Failure.invalidSchema }
            let columns = try prepare("PRAGMA table_info(read_events)")
            do {
                defer { sqlite3_finalize(columns) }
                guard try step(columns), try string(columns, 1) == "sequence", try string(columns, 2).uppercased() == "INTEGER",
                      sqlite3_column_int(columns, 5) == 1, try !step(columns) else { throw Failure.invalidSchema }
            }
            let foreignKey = try prepare("PRAGMA foreign_key_list(read_events)")
            do {
                defer { sqlite3_finalize(foreignKey) }
                guard try step(foreignKey), try string(foreignKey, 2) == "events",
                      try string(foreignKey, 3) == "sequence", try string(foreignKey, 4) == "sequence",
                      try string(foreignKey, 6).uppercased() == "CASCADE", try !step(foreignKey) else { throw Failure.invalidSchema }
            }
            // Tool-heavy history should not be scanned to find forty messages or one unread
            // answer. Additive partial indexes leave the existing v1 data/columns unchanged.
            try execute("CREATE INDEX IF NOT EXISTS events_transcript_sequence ON events(sequence) WHERE \(Self.transcriptPredicate)")
            try execute("CREATE INDEX IF NOT EXISTS events_incoming_sequence ON events(sequence) WHERE kind IN ('assistantMessage', 'question')")
            // Resolving whether a question was answered must not rescan every tool event.
            try execute("CREATE INDEX IF NOT EXISTS events_answers_sequence ON events(sequence) WHERE kind = 'answer'")
        }
    }

    private func state() throws -> State {
        let statement = try prepare("SELECT generation, read_through FROM state WHERE singleton = 1")
        defer { sqlite3_finalize(statement) }
        guard try step(statement), let generation = UUID(uuidString: try string(statement, 0)) else { throw Failure.invalidSchema }
        let readThrough = sqlite3_column_int64(statement, 1)
        guard readThrough >= 0 else { throw Failure.invalidSchema }
        return State(generation: generation, readThrough: readThrough)
    }

    private func loadSummaries(limit: Int) throws -> [Summary] {
        // One SELECT snapshots generation together with segments, even if another handle resets.
        let statement = try prepare("SELECT state.generation, summaries.from_sequence, summaries.through_sequence, summaries.text, summaries.created_at FROM summaries CROSS JOIN state WHERE state.singleton = 1 ORDER BY summaries.through_sequence DESC LIMIT ?", [.integer(Int64(limit))])
        defer { sqlite3_finalize(statement) }
        var summaries: [Summary] = []
        while try step(statement) {
            guard let generation = UUID(uuidString: try string(statement, 0)) else { throw Failure.invalidSchema }
            let from = sqlite3_column_int64(statement, 1), through = sqlite3_column_int64(statement, 2)
            let text = try string(statement, 3), created = sqlite3_column_double(statement, 4)
            guard from > 0, through >= from, !text.isEmpty,
                  text.utf8.count <= Self.maximumSummaryBytes, created.isFinite else { throw Failure.corruptPayload }
            summaries.append(Summary(generation: generation, fromSequence: from, throughSequence: through,
                text: text, createdAt: Date(timeIntervalSince1970: created)))
        }
        return summaries
    }

    private func checkGeneration(_ expected: UUID?) throws {
        if let expected, try state().generation != expected { throw Failure.staleGeneration }
    }

    private func insert(_ event: SidekickConversationEvent, encoded: Data) throws -> (record: Record, inserted: Bool) {
        let existing = try prepare("SELECT sequence, payload FROM events WHERE id = ?", [.text(event.id)])
        do {
            defer { sqlite3_finalize(existing) }
            if try step(existing) {
                let original = try data(existing, 1)
                guard original == encoded else { throw Failure.duplicateEvent(event.id) }
                return (try decodeRecord(existing), false)
            }
        }
        let task = try prepare("SELECT started_sequence, finished_sequence FROM tasks WHERE task_id = ?", [.text(event.taskID.uuidString)])
        do {
            defer { sqlite3_finalize(task) }
            if try step(task) {
                guard sqlite3_column_type(task, 1) == SQLITE_NULL else { throw Failure.taskAlreadyFinished(event.taskID) }
                if event.kind == .taskStarted, sqlite3_column_type(task, 0) != SQLITE_NULL {
                    throw Failure.duplicateTaskStart(event.taskID)
                }
            }
        }
        if let reply = event.reply {
            guard let original = try queryRecords("SELECT sequence, payload FROM events WHERE id = ?", [.text(reply.messageID)]).first,
                  [.userMessage, .assistantMessage, .question, .answer].contains(original.event.kind)
                    || (event.kind == .userMessage && original.event.kind == .taskFinished && reply.selectedText == nil),
                  reply.selectedText.map({ !$0.isEmpty && original.event.text.contains($0) }) ?? true else {
                throw Failure.invalidReply
            }
        }
        try execute("INSERT INTO events(id, task_id, kind, text, payload) VALUES(?, ?, ?, ?, ?)",
            [.text(event.id), .text(event.taskID.uuidString), .text(event.kind.rawValue), .text(event.text), .blob(encoded)])
        let sequence = sqlite3_last_insert_rowid(database)
        try execute("INSERT OR IGNORE INTO tasks(task_id, first_sequence, last_sequence) VALUES(?, ?, ?)",
            [.text(event.taskID.uuidString), .integer(sequence), .integer(sequence)])
        try execute("UPDATE tasks SET last_sequence = ? WHERE task_id = ?",
            [.integer(sequence), .text(event.taskID.uuidString)])
        if event.kind == .taskStarted {
            try execute("UPDATE tasks SET started_sequence = ? WHERE task_id = ?",
                [.integer(sequence), .text(event.taskID.uuidString)])
        } else if event.kind == .taskFinished {
            try execute("UPDATE tasks SET finished_sequence = ? WHERE task_id = ?",
                [.integer(sequence), .text(event.taskID.uuidString)])
        }
        return (Record(sequence: sequence, event: event), true)
    }

    private static func encodeBatch(_ events: [SidekickConversationEvent]) throws -> [Data] {
        guard events.count <= 1_000 else { throw Failure.invalidEvent("too many entries in one transaction") }
        var bytes = 0
        return try events.map { event in
            let data = try encode(event)
            bytes += data.count
            guard bytes <= 8_388_608 else { throw Failure.invalidEvent("history transaction is too large") }
            return data
        }
    }

    private static func encode(_ event: SidekickConversationEvent) throws -> Data {
        try validate(event)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(event)
        guard data.count <= 524_288 else { throw Failure.invalidEvent("entry is too large") }
        return data
    }

    private static func validate(_ event: SidekickConversationEvent) throws {
        func bounded(_ text: String?, _ maximum: Int, _ label: String) throws {
            if let text, text.utf8.count > maximum { throw Failure.invalidEvent("\(label) is too long") }
        }
        guard !event.id.isEmpty, !event.id.contains("\0"), event.id.utf8.count <= 512,
              event.createdAt.timeIntervalSince1970.isFinite else { throw Failure.invalidEvent("invalid identity or timestamp") }
        try bounded(event.text, maximumMessageBytes, "message")
        try bounded(event.source, 256, "source")
        if [.userMessage, .assistantMessage, .question, .answer, .checkpoint].contains(event.kind),
           event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Failure.invalidEvent("message is empty")
        }
        guard (event.kind == .taskFinished) == (event.outcome != nil),
              (event.kind == .activity) == (event.activity != nil),
              event.messageKind == nil || event.kind == .assistantMessage,
              event.reply == nil || [.userMessage, .answer].contains(event.kind),
              event.choices == nil || event.kind == .question else { throw Failure.invalidEvent("fields do not match the entry type") }
        if let reply = event.reply {
            guard !reply.messageID.isEmpty, reply.messageID.utf8.count <= 512 else { throw Failure.invalidReply }
            try bounded(reply.selectedText, maximumMessageBytes, "reply quote")
        }
        if let choices = event.choices {
            guard !choices.isEmpty, choices.count <= 16,
                  choices.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 1_024 }) else {
                throw Failure.invalidEvent("invalid question choices")
            }
        }
        if let activity = event.activity {
            guard !activity.toolID.isEmpty, !activity.name.isEmpty else { throw Failure.invalidEvent("invalid tool identity") }
            try bounded(activity.toolID, 512, "tool identity")
            try bounded(activity.name, 512, "tool name")
            try bounded(activity.arguments, maximumActivityTextBytes, "tool arguments")
            try bounded(activity.result, maximumActivityTextBytes, "tool result")
        }
    }

    // MARK: SQLite primitives; caller holds the lock

    private enum Value { case text(String), integer(Int64), real(Double), blob(Data) }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard database != nil else { throw Failure.closed }
        return try body()
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func readSnapshot<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN DEFERRED")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func latest() throws -> Int64 {
        try integer("SELECT COALESCE(MAX(sequence), 0) FROM events")
    }

    private func prepare(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw databaseError(result) }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                let bound: Int32
                switch value {
                case .text(let text):
                    bound = text.utf8CString.withUnsafeBufferPointer {
                        sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), transient)
                    }
                case .integer(let value): bound = sqlite3_bind_int64(statement, index, value)
                case .real(let value): bound = sqlite3_bind_double(statement, index, value)
                case .blob(let data):
                    bound = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
                }
                guard bound == SQLITE_OK else { throw databaseError(bound) }
            }
        } catch { sqlite3_finalize(statement); throw error }
        return statement
    }

    @discardableResult
    private func step(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw databaseError(result)
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while try step(statement) { }
    }

    private func integer(_ sql: String, _ values: [Value] = []) throws -> Int64 {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard try step(statement), sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw Failure.invalidSchema }
        return sqlite3_column_int64(statement, 0)
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column) else { throw Failure.corruptPayload }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard let string = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else { throw Failure.corruptPayload }
        return string
    }

    private func data(_ statement: OpaquePointer, _ column: Int32) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, column) else { throw Failure.corruptPayload }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= 524_288 else { throw Failure.corruptPayload }
        return Data(bytes: bytes, count: count)
    }

    private func decodeRecord(_ statement: OpaquePointer) throws -> Record {
        let payload = try data(statement, 1)
        guard let event = try? JSONDecoder().decode(SidekickConversationEvent.self, from: payload),
              (try? Self.validate(event)) != nil else { throw Failure.corruptPayload }
        let sequence = sqlite3_column_int64(statement, 0)
        guard sequence > 0 else { throw Failure.corruptPayload }
        return Record(sequence: sequence, event: event)
    }

    private func queryRecords(_ sql: String, _ values: [Value] = []) throws -> [Record] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var records: [Record] = []
        while try step(statement) { records.append(try decodeRecord(statement)) }
        return records
    }

    private func databaseError(_ code: Int32) -> Failure {
        .database(code: code, message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "Database unavailable")
    }

    /// Outside the database lock/transaction: observers may safely read the committed snapshot.
    private func publish() { NotificationCenter.default.post(name: .sidekickConversationChanged, object: self) }
}
