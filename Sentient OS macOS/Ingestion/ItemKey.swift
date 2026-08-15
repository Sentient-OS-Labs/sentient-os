//
//  ItemKey.swift
//  Sentient OS macOS
//
//  A work item's position in its connector's ordered timeline: `(order, tiebreak)`, compared
//  lexicographically. One shape for every connector:
//    Files → (dateAdded epoch, path)   ·   Notes → (createdDate epoch, uuid)   ·   Chats → (rowID, "")
//
//  `order` alone isn't always unique (files share a date-added second), so `tiebreak` makes every
//  item a distinct point — the per-bucket pointer names EXACTLY one boundary, so a re-scan on a
//  later run never duplicates or drops a same-key item. Chats need no tiebreak (row ids are unique).
//

import Foundation

struct ItemKey: Comparable, Codable, Sendable, Hashable {
    let order: Double      // date epoch, or Double(rowID)
    let tiebreak: String   // path / uuid / ""

    init(order: Double, tiebreak: String = "") { self.order = order; self.tiebreak = tiebreak }
    init(date: Date, tiebreak: String) { self.init(order: date.timeIntervalSince1970, tiebreak: tiebreak) }
    init(rowID: Int64) { self.init(order: Double(rowID)) }

    /// Order by `order`, then by `tiebreak` for the same-order tiebreak.
    static func < (a: ItemKey, b: ItemKey) -> Bool {
        a.order == b.order ? a.tiebreak < b.tiebreak : a.order < b.order
    }
}
