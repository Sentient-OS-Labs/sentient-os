// Keeps only vetted Calendar survivors between incomplete analysis passes. Revalidation drops
// edited, deleted, expired and newly excluded events before reuse. Never stores rejected IDs.
// Doc: Documentation - Ingestion Pipeline.md

import Foundation

nonisolated struct CalendarRetryCache: Codable, Sendable {
    var version = 1
    let coverage: AppleCalendarSource.Coverage
    var survivors: [String: Survivor] = [:]

    struct Survivor: Codable, Sendable {
        let revision: String
        let summary: String
        let title: String?
    }

    mutating func validate(against snapshot: AppleCalendarSource.Snapshot) {
        guard version == 1, coverage == snapshot.coverage else { survivors = [:]; return }
        let events = Dictionary(snapshot.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        survivors = survivors.filter { id, saved in
            guard let event = events[id], !event.revision.isEmpty, saved.revision == event.revision else { return false }
            return Triage.calendarInputDecision(for: Artifact(candidate: event.candidate, text: event.content)) == nil
        }
    }
}
