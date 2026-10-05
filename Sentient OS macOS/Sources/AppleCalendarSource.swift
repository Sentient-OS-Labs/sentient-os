// AppleCalendarSource.swift
// Reads explicitly selected calendars through EventKit. Raw events stay in memory; capture()
// returns a bounded occurrence snapshot and validate() checks it again before publication.
// Doc: Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md

import Foundation
import EventKit
import CryptoKit

nonisolated enum AppleCalendarSource {
    static let selectionKey = "appleCalendar.selectedIDs"
    static let issueKey = "appleCalendar.readIssue"
    static let bucketKey = "apple-calendar"
    static let maximumEvents = 2_000
    private static let queue = DispatchQueue(label: "ai.sentient.calendar", qos: .utility)

    struct CalendarInfo: Identifiable, Sendable {
        let id: String
        let title: String
        let account: String
    }

    enum ReadError: Error { case permission, noSelection, missingCalendar, tooManyEvents, invalidEvent, changed }

    static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var selectedIDs: Set<String> {
        guard let data = UserDefaults.standard.data(forKey: selectionKey),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }
    static var isEnabled: Bool { hasAccess && !selectedIDs.isEmpty }

    /// Structure-only source health. Set before a run, clear only after a complete commit.
    /// A crash therefore leaves an honest retry message, never a persisted "reading" spinner.
    enum Issue: String { case incomplete, permission, missing, limit, changed, model, storage, deadline }
    static func recordIssue(_ issue: Issue) { UserDefaults.standard.set(issue.rawValue, forKey: issueKey) }

    static func recordIssue(_ error: Error? = nil) {
        let code: String
        switch error as? ReadError {
        case .permission: code = "permission"
        case .missingCalendar: code = "missing"
        case .tooManyEvents: code = "limit"
        case .changed: code = "changed"
        default: code = "incomplete"
        }
        UserDefaults.standard.set(code, forKey: issueKey)
    }

    static func issueMessage(_ code: String) -> String? {
        switch code {
        case "permission": "Calendar access changed. Check Full Access in System Settings."
        case "missing": "A selected calendar is unavailable. Refresh the list and review your selection."
        case "limit": "These calendars contain more than 2,000 events in the analysis window. Choose fewer calendars to continue."
        case "changed": "Your calendar changed during analysis. Run Analyze Now to read the updated schedule."
        case "incomplete": "Calendar analysis did not finish. Run Analyze Now again, or choose fewer calendars."
        case "model": "The on-device model could not finish Calendar analysis. No partial schedule was saved. Try analysis again."
        case "storage": "Calendar analysis could not save its results. Check available disk space, then try again."
        case "deadline": "Calendar analysis reached its time limit. Choose fewer calendars or try again."
        default: nil
        }
    }

    static func saveSelection(_ ids: Set<String>) {
        UserDefaults.standard.set(try? JSONEncoder().encode(ids.sorted()), forKey: selectionKey)
        UserDefaults.standard.removeObject(forKey: issueKey)
    }

    /// Called only by the explicit Connect button, never by background ingestion.
    @MainActor static func requestAccess() async throws -> Bool {
        let store = EKEventStore()
        return try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    static func calendars() throws -> [CalendarInfo] {
        try queue.sync {
            guard hasAccess else { throw ReadError.permission }
            let store = EKEventStore()
            let result = store.calendars(for: .event).map {
                CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title)
            }.sorted { ($0.account, $0.title, $0.id) < ($1.account, $1.title, $1.id) }
            guard hasAccess else { throw ReadError.permission }
            return result
        }
    }

    /// A checkpoint describes completed coverage, never an event-time or modification-time cursor.
    /// No event identifiers, content hashes, or rejected-item records are persisted here.
    struct Coverage: Codable, Equatable, Sendable {
        let version: Int
        let lower: Date
        let upper: Date
        let selection: String

        init(now: Date, ids: Set<String>, calendar: Calendar = .current) {
            version = 1
            let day = calendar.startOfDay(for: now)
            lower = calendar.date(byAdding: .day, value: -7, to: day)!
            upper = calendar.date(byAdding: .day, value: 31, to: day)!
            selection = AppleCalendarSource.digest(ids.sorted())
        }

        var encoded: String { String(decoding: try! JSONEncoder().encode(self), as: UTF8.self) }
        static func decode(_ text: String) -> Coverage? {
            guard let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
                  value.version == 1, value.lower < value.upper else { return nil }
            return value
        }
        var matchesSelection: Bool { selection == AppleCalendarSource.digest(AppleCalendarSource.selectedIDs.sorted()) }
        var scheduleDescription: String {
            "Window: \(AppleCalendarSource.timestamp(lower)) to \(AppleCalendarSource.timestamp(upper)), end exclusive."
        }
    }

    struct Event: Equatable, Sendable {
        let id: String
        let start: Date
        let end: Date
        let schedule: String
        let content: String
        let inputRisk: String?
        /// Ephemeral hash of complete source fields; edits past the model excerpt still invalidate it.
        let revision: String

        init(id: String, start: Date, end: Date, schedule: String, content: String,
             inputRisk: String? = nil, revision: String = "") {
            self.id = id; self.start = start; self.end = end; self.schedule = schedule
            self.content = content; self.inputRisk = inputRisk; self.revision = revision
        }

        var candidate: Candidate {
            Candidate(id: id, kind: .appleCalendar, itemDate: start,
                      metadata: ["folder": "Apple Calendar", "displayPath": "Apple Calendar event",
                                 "calendarText": content, "calendarSchedule": schedule,
                                 "calendarInputRisk": inputRisk ?? ""])
        }
    }

    struct Snapshot: Sendable {
        let capturedAt: Date
        let coverage: Coverage
        let events: [Event]

        /// A changed selection, permission, deletion, edit, or recurrence expansion invalidates
        /// the pending batch. Old checkpoints remain intact; the next run captures fresh state.
        func validate() throws {
            guard coverage.matchesSelection else { throw ReadError.changed }
            let fresh = try AppleCalendarSource.capture(ids: AppleCalendarSource.selectedIDs, coverage: coverage)
            guard events == fresh.events else { throw ReadError.changed }
        }

        var marker: NoteDraft {
            NoteDraft(kind: .appleCalendar, sourceID: "apple-calendar:coverage", folder: "Apple Calendar",
                      itemDate: capturedAt,
                      text: """
                      Apple Calendar schedule snapshot as of \(AppleCalendarSource.timestamp(capturedAt)).
                      \(coverage.scheduleDescription)
                      Only explicitly selected calendars synced to this Mac were read. Privacy-filtered summaries
                      accompany this snapshot. Replace earlier Apple Calendar schedule claims in this window with
                      the current summaries across ALL corpus parts in this cycle, not just this part. Missing summaries do not prove deletion, attendance, or free time.
                      Older schedule claims are historical, not current availability. Other calendar sources may
                      describe the same meeting; do not count it twice. Verify the live calendar before any action.
                      """, title: "Apple Calendar schedule coverage", reminderFlagged: false)
        }
    }

    static func capture(ids: Set<String>, now: Date = Date(), coverage: Coverage? = nil) throws -> Snapshot {
        try queue.sync {
            guard hasAccess else { throw ReadError.permission }
            guard !ids.isEmpty else { throw ReadError.noSelection }
            let bounds = coverage ?? Coverage(now: now, ids: ids)
            guard bounds.selection == digest(ids.sorted()) else { throw ReadError.changed }
            let store = EKEventStore() // fresh objects for each read; no stale EventKit cache crosses runs
            let calendars = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
            guard Set(calendars.map(\.calendarIdentifier)) == ids else { throw ReadError.missingCalendar }
            let predicate = store.predicateForEvents(withStart: bounds.lower, end: bounds.upper, calendars: calendars)
            var raw: [EKEvent] = []
            var exceededLimit = false
            store.enumerateEvents(matching: predicate) { event, stop in
                guard raw.count < maximumEvents else { exceededLimit = true; stop.pointee = true; return }
                raw.append(event)
            }
            guard !exceededLimit else { throw ReadError.tooManyEvents } // never silently truncate coverage
            var events: [String: Event] = [:]
            for event in raw {
                guard let rawStart = event.startDate, let rawEnd = event.endDate, rawStart <= rawEnd,
                      rawStart.timeIntervalSince1970.isFinite, rawEnd.timeIntervalSince1970.isFinite,
                      !event.calendarItemIdentifier.isEmpty else { throw ReadError.invalidEvent }
                let zone = event.isAllDay ? TimeZone.current : (event.timeZone ?? .current)
                let (start, end) = interval(start: rawStart, end: rawEnd, allDay: event.isAllDay, zone: zone)
                guard start < bounds.upper, end > bounds.lower || (start == end && start >= bounds.lower) else { continue }
                let id = occurrenceID(calendarID: event.calendar.calendarIdentifier,
                                      itemID: event.calendarItemIdentifier,
                                      occurrence: event.occurrenceDate ?? start)
                let schedule = schedule(start: start, end: end, allDay: event.isAllDay, zone: zone,
                                        status: event.status.rawValue, availability: event.availability.rawValue,
                                        response: event.attendees?.first(where: \.isCurrentUser)?.participantStatus.rawValue)
                // Attendee addresses, organizer addresses, and conference URLs are deliberately
                // omitted. Even local calendar/account names stay out of downstream metadata.
                let projection = try project(title: event.title ?? "", notes: event.notes ?? "",
                                             location: event.location ?? "", schedule: schedule)
                let value = Event(id: id, start: start, end: end, schedule: schedule, content: projection.content,
                                  inputRisk: projection.risk, revision: projection.revision)
                if let old = events[id], old != value { throw ReadError.invalidEvent }
                events[id] = value
            }
            guard hasAccess else { throw ReadError.permission }
            return Snapshot(capturedAt: now, coverage: bounds, events: events.values.sorted { $0.id < $1.id })
        }
    }

    /// EventKit on macOS may return an all-day inclusive 23:59:59 end. Normalize to
    /// local calendar-day boundaries, preserving already-exclusive midnight ends and DST.
    static func interval(start: Date, end: Date, allDay: Bool, zone: TimeZone) -> (Date, Date) {
        guard allDay else { return (start, end) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let first = calendar.startOfDay(for: start), last = calendar.startOfDay(for: end)
        let exclusive = end == last && end > first ? last : calendar.date(byAdding: .day, value: 1, to: last)!
        return (first, exclusive)
    }

    static func project(title: String, notes: String, location: String, schedule: String)
        throws -> (content: String, risk: String?, revision: String) {
        let full = [title, notes, location]
        let fields = ["title": bounded(title, bytes: 512), "notes": bounded(notes, bytes: 3_000),
                      "location": bounded(location, bytes: 512), "schedule": schedule]
        var data = fields
        data["truncated"] = fields["title"] != title || fields["notes"] != notes || fields["location"] != location ? "true" : "false"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (String(decoding: try encoder.encode(data), as: UTF8.self),
                Triage.calendarInputRisk(full), digest(full))
    }

    /// Recurrences share an item ID. Their ORIGINAL occurrence date distinguishes instances,
    /// including a detached instance whose current start was moved. IDs are local to this Mac.
    static func occurrenceID(calendarID: String, itemID: String, occurrence: Date) -> String {
        "apple-calendar:" + digest([calendarID, itemID, String(occurrence.timeIntervalSince1970)])
    }

    static func schedule(start: Date, end: Date, allDay: Bool, zone: TimeZone,
                         status: Int, availability: Int, response: Int?) -> String {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = zone
        if allDay { formatter.formatOptions = [.withFullDate] }
        let displayedDates: String
        if allDay {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let finalDay = calendar.date(byAdding: .day, value: -1, to: end)!
            displayedDates = "All-day dates: \(formatter.string(from: start)) through \(formatter.string(from: finalDay)) (inclusive). "
        } else { displayedDates = "" }
        let state: String
        switch status { case 1: state = "confirmed"; case 2: state = "tentative"; case 3: state = "cancelled"; default: state = "unknown" }
        let busy: String
        switch availability { case 0: busy = "busy"; case 1: busy = "free"; case 2: busy = "tentative"; case 3: busy = "unavailable"; default: busy = "unknown" }
        let participation: String
        switch response { case 1: participation = "pending"; case 2: participation = "accepted"; case 3: participation = "declined"; case 4: participation = "tentative"; case 5: participation = "delegated"; case 6: participation = "completed"; case 7: participation = "in process"; default: participation = "unknown" }
        return displayedDates + "Start: \(formatter.string(from: start)); end: \(formatter.string(from: end)) (exclusive); "
            + "time zone: \(zone.identifier); all-day: \(allDay); status: \(state); availability: \(busy); response: \(participation)."
    }

    static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func digest(_ parts: [String]) -> String {
        // JSON encoding prevents delimiter collisions; raw provider IDs never enter the vault.
        SHA256.hash(data: try! JSONEncoder().encode(parts)).map { String(format: "%02x", $0) }.joined()
    }
    private static func bounded(_ text: String, bytes: Int) -> String {
        // Count the encoded JSON cost, not raw UTF-8: a control scalar can expand to six bytes.
        // Iterate scalars so the cap cannot introduce a replacement character mid-sequence.
        var count = 0, result = ""
        for scalar in text.unicodeScalars {
            let cost: Int
            switch scalar.value {
            case 8, 9, 10, 12, 13, 34, 92: cost = 2
            case 0..<32: cost = 6
            default: cost = scalar.utf8.count
            }
            guard count + cost <= bytes else { break }
            result.unicodeScalars.append(scalar); count += cost
        }
        return result
    }
}
