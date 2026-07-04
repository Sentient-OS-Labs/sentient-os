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

    // MARK: - Rolling extraction rate (§7.8/§8-R2 — a PER-ITEM sensor)

    // File extraction is per-item, so an iterative run sees 0–3 files — a per-run rate is noise. Keep
    // a ROLLING window (epoch-hour buckets, pruned to `extractionWindowHours`) and alarm on the rate
    // across it, so a `.pdf`/`.doc` extraction break still surfaces as new files trickle in.
    private static let extractionWindowHours = 24 * 7
    private static let extractionMinSamples = 30
    private static let extractionFloorPct = 50   // below this (with a real sample) = degraded

    static func recordExtraction(succeeded: Bool) {
        var d = dict()
        let hour = Int(Date().timeIntervalSince1970 / 3600)
        d["extract.\(hour).att", default: 0] += 1
        if succeeded { d["extract.\(hour).suc", default: 0] += 1 }
        let cutoff = hour - extractionWindowHours
        for k in d.keys where k.hasPrefix("extract.") {
            let parts = k.split(separator: ".")
            if parts.count == 3, let h = Int(parts[1]), h < cutoff { d[k] = nil }
        }
        save(d)
    }

    /// Called once at run-end: emit `files.extraction_degraded` if the rolling rate has collapsed
    /// (Apple/format change, or a corrupt-file wave) with enough samples to be real.
    static func checkExtractionRate() {
        let d = dict()
        var att = 0, suc = 0
        for (k, v) in d where k.hasPrefix("extract.") {
            if k.hasSuffix(".att") { att += v } else if k.hasSuffix(".suc") { suc += v }
        }
        guard att >= extractionMinSamples else { return }
        let pct = suc * 100 / att
        if pct < extractionFloorPct {
            CrashReporting.captureEvent("files.extraction_degraded", level: .warning,
                tags: ["source": "file"],
                extra: ["attempts": String(att), "success_pct": String(pct)],
                fingerprint: ["files", "extraction_degraded"])
        }
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    private static func dict() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }
    private static func save(_ d: [String: Int]) { UserDefaults.standard.set(d, forKey: key) }
}
