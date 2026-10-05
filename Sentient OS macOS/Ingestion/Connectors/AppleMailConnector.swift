// AppleMailConnector.swift
// Mail opt-in and source adapter. Progress is planned by AppleMailCheckpoint and committed by
// IterativeRun with CycleStore; no cursor lives in the reader. Doc: Ingestion/Documentation - Ingestion Pipeline.md

import Foundation

nonisolated enum AppleMailSelection {
    static let key = "sources.appleMail.accounts"
    static var accounts: Set<String> {
        Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",")
            .map(String.init).filter { UUID(uuidString: $0) != nil }.map { $0.uppercased() })
    }
}

struct AppleMailConnector: Connector {
    nonisolated static let maximumMessagesPerPass = 600
    // The 12 KB input plus prompt, retry instruction and 1K reply fit even at one piece/byte.
    nonisolated static let contextSize = 16_384
    nonisolated static let maximumInputBytes = 12_000
    let accounts: Set<String>
    var kind: SourceKind { .appleMail }
    var maxTokens: Int { Self.contextSize }
    // The generic ItemKey Double cannot represent arbitrary Mail rowids. Mail uses its Int64
    // checkpoint path in IterativeRun, never generic timestamp pointers.
    func buckets(since marks: [String: ItemKey]) throws -> [Bucket] { throw AppleMailError.unsupportedSchema }
    func load(_ item: Candidate) throws -> Artifact { throw AppleMailError.missingBody }
}

nonisolated struct AppleMailCheckpoint: Codable, Sendable {
    var version = 1
    var classificationVersion: Int? = AppleMailSource.classificationVersion
    var generation: String
    var salt = UUID().uuidString
    var highWater: Int64
    var backfillBefore: Int64?
    var deferred: Set<Int64> = []
    var retryAfter: Int64 = 0
    var reconcileBefore: Int64? = nil
    var reconciledAt: Date? = nil

    init(generation: String, top: Int64) {
        self.generation = generation; highWater = top; backfillBefore = top
    }

    enum Phase: Sendable { case discovery, backfill, retry, reconcile }
    struct Work: Sendable { let row: AppleMailRow; let phase: Phase }

    /// Disjoint frontiers: new inserts cannot erase unfinished backfill. A rowid is meaningful
    /// only within one Envelope Index UUID. Rebuilds reset traversal while survivor identities live.
    mutating func prepare(generation: String, rows: [AppleMailRow], now: Date,
                          limit: Int = AppleMailConnector.maximumMessagesPerPass) -> [Work] {
        let top = rows.first?.id ?? 0
        if self.generation != generation || top < highWater || classificationVersion != AppleMailSource.classificationVersion {
            let savedSalt = salt
            self = AppleMailCheckpoint(generation: generation, top: top)
            salt = savedSalt
        }
        let existing = Set(rows.filter { !$0.excluded || $0.previewJunk }.map(\.id))
        deferred.formIntersection(existing)
        let budget = min(AppleMailConnector.maximumMessagesPerPass, max(0, limit))
        let fresh = rows.filter { $0.id > highWater }.reversed().prefix(budget).map { Work(row: $0, phase: .discovery) }
        var work = Array(fresh)
        var occupied = Set(work.map { $0.row.id })
        let retries = rows.filter { deferred.contains($0.id) && !occupied.contains($0.id) }.sorted { $0.id < $1.id }
        let rotated = retries.filter { $0.id > retryAfter } + retries.filter { $0.id <= retryAfter }
        // Reserve a bounded retry turn before backfill so missing bodies do not wait for all history.
        work += rotated.prefix(min(100, budget - work.count)).map { Work(row: $0, phase: .retry) }
        occupied.formUnion(work.map { $0.row.id })
        if let before = backfillBefore {
            work += rows.filter { $0.id <= before && $0.id <= highWater && !occupied.contains($0.id) }
                .prefix(budget - work.count).map { Work(row: $0, phase: .backfill) }
        }
        if backfillBefore == nil && (reconcileBefore != nil || now.timeIntervalSince(reconciledAt ?? .distantPast) >= 86400) {
            let used = Set(work.map { $0.row.id })
            let before = reconcileBefore ?? top
            work += rows.filter { $0.id <= before && !used.contains($0.id) }
                .prefix(budget - work.count).map { Work(row: $0, phase: .reconcile) }
        }
        return work
    }

    mutating func finish(_ work: Work, retry: Bool) {
        if retry { deferred.insert(work.row.id) } else { deferred.remove(work.row.id) }
        switch work.phase {
        case .discovery: highWater = work.row.id
        case .backfill: backfillBefore = work.row.id - 1
        case .retry: retryAfter = work.row.id
        case .reconcile: reconcileBefore = work.row.id - 1
        }
    }

    mutating func completePass(rows: [AppleMailRow], now: Date) {
        if let before = backfillBefore, !rows.contains(where: { $0.id <= before }) { backfillBefore = nil }
        if let before = reconcileBefore, !rows.contains(where: { $0.id <= before }) { reconcileBefore = nil; reconciledAt = now }
        if rows.isEmpty { backfillBefore = nil; reconciledAt = now }
    }
}
