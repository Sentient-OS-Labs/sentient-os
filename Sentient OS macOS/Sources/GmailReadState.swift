// GmailReadState.swift
// Fixed Gmail read windows and durable coverage for an interrupted import. Stores no mail content.
// A window receipt survives consumption of its summary; the watermark advances only across full coverage.
// Doc: Documentation - Sources - Cloud (Gmail, Calendar).md

import Foundation

nonisolated struct GmailReadState: Codable, Sendable, Equatable {
    struct Window: Codable, Sendable, Equatable {
        let start: Date
        let end: Date

        // Gmail's epoch boundaries avoid its date-string timezone interpretation. One second
        // of overlap at the lower bound includes mail exactly on a preceding window boundary.
        var query: String { "after:\(Int(start.timeIntervalSince1970) - 1) before:\(Int(end.timeIntervalSince1970))" }
    }

    enum Failure: Error { case invalidCheckpoint }

    var version = 1
    let id: UUID
    let origin: String
    let through: Date
    let windows: [Window]
    var completed: Set<Int> = []
    let replaceNotes: Bool

    var isComplete: Bool { completed.count == windows.count }
    var pending: [Int] { windows.indices.filter { !completed.contains($0) } }

    func sourceID(for index: Int) -> String { "gmail:window:\(id.uuidString):\(index)" }

    static func initial(origin: String, through: Date, replaceNotes: Bool) -> Self {
        let end = Date(timeIntervalSince1970: floor(through.timeIntervalSince1970))
        let week: TimeInterval = 7 * 24 * 60 * 60
        return Self(id: UUID(), origin: origin, through: end, windows: (0..<4).map {
            Window(start: end.addingTimeInterval(-Double($0 + 1) * week),
                   end: end.addingTimeInterval(-Double($0) * week))
        }, replaceNotes: replaceNotes)
    }

    static func incremental(origin: String, since: Date, through: Date) -> Self {
        let end = Date(timeIntervalSince1970: floor(through.timeIntervalSince1970))
        return Self(id: UUID(), origin: origin, through: end,
                    windows: [Window(start: Date(timeIntervalSince1970: floor(since.timeIntervalSince1970)), end: end)],
                    replaceNotes: false)
    }

    func validate() throws {
        let sorted = windows.sorted { $0.start < $1.start }
        guard version == 1, !origin.isEmpty, (1...4).contains(windows.count),
              through.timeIntervalSince1970.isFinite, through.timeIntervalSince1970 > 0,
              completed.isSubset(of: Set(windows.indices)), !isComplete,
              sorted.last?.end == through,
              windows.allSatisfy({ $0.start.timeIntervalSince1970.isFinite && $0.start.timeIntervalSince1970 > 0
                  && $0.end.timeIntervalSince1970.isFinite && $0.start < $0.end }),
              zip(sorted, sorted.dropFirst()).allSatisfy({ $0.end == $1.start }) else {
            throw Failure.invalidCheckpoint
        }
    }
}
