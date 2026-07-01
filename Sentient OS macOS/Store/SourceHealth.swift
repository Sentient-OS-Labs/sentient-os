//
//  SourceHealth.swift
//  Sentient OS macOS
//
//  Tiny UserDefaults-backed memory for the diagnostics sensors (Documentation/Source Diagnostics &
//  Hardening (Sentry).md §4.4). Modeled on LifetimeStats: one dict key, sync + thread-safe, so the
//  off-main connector decoders and the @MainActor IterativeRun can both touch it with no executor hop.
//
//  Today it holds the run-over-run LISTING count per source, so a brittle decoder that silently
//  stops producing output (an OS update zeroing out the iMessage decode, a WhatsApp schema change
//  hiding every group) shows up as a listing collapse the very next run — see checkListingCollapse.
//  Its OWN key (never LifetimeStats') so a stats reset can't wipe it.
//

import Foundation

enum SourceHealth {
    private static let key = "stats.sourceHealth"   // [String: Int]

    /// The last listing count we saw for a bucket key (a source's full eligible set, sampled every
    /// run). nil = never recorded.
    static func lastListingCount(_ bucketKey: String) -> Int? { dict()["listing:\(bucketKey)"] }

    static func recordListingCount(_ bucketKey: String, _ count: Int) {
        var d = dict(); d["listing:\(bucketKey)"] = count; save(d)
    }

    /// Compare this run's listing count to the last, emit a `<source>.listing_collapsed` event if a
    /// previously-healthy source cratered to zero, then record the new count. The clearest, lowest-
    /// noise silent-breakage signal; a partial drop is deliberately NOT alarmed (too noisy without a
    /// baseline model). `minPrevious` keeps small accounts from false-firing.
    static func checkListingCollapse(source: String, bucketKey: String, count: Int, minPrevious: Int = 20) {
        if let prev = lastListingCount(bucketKey), prev >= minPrevious, count == 0 {
            CrashReporting.captureEvent("\(source).listing_collapsed", level: .error,
                tags: ["source": source],
                extra: ["previous": String(prev), "now": "0"],
                fingerprint: [source, "listing_collapsed"])
        }
        recordListingCount(bucketKey, count)
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    private static func dict() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }
    private static func save(_ d: [String: Int]) { UserDefaults.standard.set(d, forKey: key) }
}
