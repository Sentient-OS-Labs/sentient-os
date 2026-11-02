// Keeps only vetted Calendar survivors between incomplete analysis passes. Revalidation drops
// edited, deleted, expired and newly excluded events before reuse. Failed event revisions
// are retained without content so an unchanged failure is skipped on later nights.
// Doc: Documentation - Ingestion Pipeline.md

import Foundation

nonisolated struct CalendarRetryCache: Codable, Sendable {
    var version = 1
    var coverage: AppleCalendarSource.Coverage
    var survivors: [String: Survivor] = [:]
    var skipped: [String: String]? = nil

    struct Survivor: Codable, Sendable {
        let revision: String
        let summary: String
        let title: String?
    }

    mutating func validate(against snapshot: AppleCalendarSource.Snapshot) {
        guard version == 1 else { survivors = [:]; skipped = nil; return }
        coverage = snapshot.coverage
        let events = Dictionary(snapshot.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        skipped = skipped?.filter { id, revision in !revision.isEmpty && events[id]?.revision == revision }
        survivors = survivors.filter { id, saved in
            guard let event = events[id], !event.revision.isEmpty, saved.revision == event.revision else { return false }
            return Triage.calendarInputDecision(for: Artifact(candidate: event.candidate, text: event.content)) == nil
        }
    }
}
