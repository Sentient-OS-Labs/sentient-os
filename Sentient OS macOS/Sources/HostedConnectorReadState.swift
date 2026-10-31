// Fixed windows and cursor checkpoints for hosted connector ingestion; contains no raw source content.
// Doc: Documentation - Sources - Cloud (Gmail, Calendar).md
import Foundation

nonisolated struct HostedConnectorReadState: Codable, Sendable, Equatable {
    enum Failure: Error { case invalidCheckpoint }
    struct Window: Codable, Sendable, Equatable { let start: Date; let end: Date }
    let id: UUID
    let origin: String
    let through: Date
    let windows: [Window]
    var windowIndex = 0
    var pageIndex = 0
    var revision = 0
    var cursor: String?
    var complete: Bool { windowIndex == windows.count }
    var sourceID: String { "hosted:\(id):\(windowIndex):\(pageIndex)" }
    func validate() throws {
        guard !origin.isEmpty, windows.count <= 64, !windows.isEmpty, (0...windows.count).contains(windowIndex),
              pageIndex >= 0, revision >= 0, windows.last?.end == through,
              !complete || (cursor == nil && pageIndex == 0),
              windows.allSatisfy({ $0.start < $0.end && $0.end.timeIntervalSince($0.start) <= 31 * 86400 }),
              zip(windows, windows.dropFirst()).allSatisfy({ $0.end == $1.start }),
              cursor == nil || UUID(uuidString: cursor!) != nil else { throw Failure.invalidCheckpoint }
    }
    static func plan(origin: String, calendar: Bool, since: Date?, now: Date) throws -> Self {
        let now = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        let start = since.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
            ?? now.addingTimeInterval(-Double(calendar ? 365 : 28) * 86400)
        guard start < now else { throw Failure.invalidCheckpoint }
        let end = min(now, start.addingTimeInterval(365 * 86400))
        let stride = Double(calendar ? 30 : 7) * 86400
        var windows: [Window] = [], next = start
        while next < end { let upper = min(end, next.addingTimeInterval(stride)); windows.append(.init(start: next, end: upper)); next = upper }
        return Self(id: UUID(), origin: origin, through: end, windows: windows)
    }
    mutating func advance(cursor: String?) {
        revision += 1
        self.cursor = cursor
        if cursor == nil { windowIndex += 1; pageIndex = 0 } else { pageIndex += 1 }
    }
}
