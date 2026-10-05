// AppleCalendarConnector.swift
// Adapts local EventKit snapshots to the shared on-device pipeline. Calendar coverage must
// be replaced atomically, so it never uses the append-only high-water/floor cursor.
// Doc: ../Documentation - Ingestion Pipeline.md

import Foundation

struct AppleCalendarConnector: Connector {
    let calendarIDs: Set<String>
    let kind = SourceKind.appleCalendar
    // Includes JSON escaping, the fixed prompt, retry instruction and reply budget.
    nonisolated static let contextSize = 16_384
    var maxTokens: Int { Self.contextSize }

    func buckets(since marks: [String: ItemKey]) throws -> [Bucket] {
        guard calendarIDs == AppleCalendarSource.selectedIDs else { throw AppleCalendarSource.ReadError.changed }
        let snapshot = try AppleCalendarSource.capture(ids: calendarIDs)
        return [Bucket(key: AppleCalendarSource.bucketKey,
                       items: snapshot.events.map { (ItemKey(date: $0.start, tiebreak: $0.id), $0.candidate) },
                       snapshot: snapshot)]
    }

    func load(_ item: Candidate) throws -> Artifact {
        guard AppleCalendarSource.hasAccess, calendarIDs == AppleCalendarSource.selectedIDs,
              let text = item.metadata["calendarText"] else { throw AppleCalendarSource.ReadError.changed }
        return Artifact(candidate: item, text: text)
    }
}
