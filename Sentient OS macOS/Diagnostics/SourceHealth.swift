//
//  SourceHealth.swift
//  Sentient OS macOS
//
//  Tiny UserDefaults-backed memory for the diagnostics sensors (doc: Diagnostics/Documentation -
//  Diagnostics (Sentry & TelemetryDeck).md). Modeled on LifetimeStats: one dict key, sync + thread-safe, so the
//  off-main connector decoders and the @MainActor IterativeRun can both touch it with no executor hop.
//
//  Today it holds the run-over-run LISTING count per source, so a brittle decoder that silently
//  stops producing output (an OS update zeroing out the iMessage decode, a WhatsApp schema change
//  hiding every group) shows up as a listing collapse the very next run — see checkListingCollapse.
//  Its OWN key (never LifetimeStats') so a stats reset can't wipe it.
//

import Foundation
import Synchronization

nonisolated enum SourceHealth {
    private static let lock = Mutex(())
    private static let key = "stats.sourceHealth"   // [String: Int]

    /// The last listing count we saw for a bucket key (a source's full eligible set, sampled every
    /// run). nil = never recorded.
    static func lastListingCount(_ bucketKey: String) -> Int? { dict()["listing:\(bucketKey)"] }

    static func recordListingCount(_ bucketKey: String, _ count: Int) {
        lock.withLock { _ in
            var d = dict(); d["listing:\(bucketKey)"] = count; save(d)
        }
    }

    /// Compare this run's listing count to the last, emit a `<source>.listing_collapsed` event if a
    /// previously-healthy source cratered to zero, then record the new count. The clearest, lowest-
    /// noise silent-breakage signal; a partial drop is deliberately NOT alarmed (too noisy without a
    /// baseline model). `minPrevious` keeps small accounts from false-firing.
    static func checkListingCollapse(source: String, bucketKey: String, count: Int, minPrevious: Int = 20) {
        let previous: Int? = lock.withLock { _ in
            var d = dict()
            let previous = d["listing:\(bucketKey)"]
            // Keep a healthy baseline through repeated zero reads; a later recovery refreshes it.
            if count > 0 || previous == nil { d["listing:\(bucketKey)"] = count }
            save(d)
            return previous
        }
        if let previous, previous >= minPrevious, count == 0 {
            CrashReporting.captureEvent("\(Diagnostics.source(source)).listing_collapsed", level: .error,
                tags: ["source": Diagnostics.source(source)], extra: ["previous": String(previous), "now": "0"],
                fingerprint: [Diagnostics.source(source), "listing_collapsed"], cooldown: 86400)
        }
    }

    // MARK: - Rolling extraction rate (§7.8/§8-R2 — a PER-ITEM sensor)

    // File extraction is per-item, so an iterative run sees 0–3 files — a per-run rate is noise. Keep
    // a ROLLING window (epoch-hour buckets, pruned to `extractionWindowHours`) and alarm on the rate
    // across it, so a `.pdf`/`.doc` extraction break still surfaces as new files trickle in.
    private static let extractionWindowHours = 24 * 7
    private static let extractionMinSamples = 30
    private static let extractionFloorPct = 50   // below this (with a real sample) = degraded

    static func extractionFormat(_ suffix: String) -> String {
        let value = suffix.lowercased()
        return ["pdf", "doc", "docx", "txt", "md", "rtf", "html", "ppt", "pptx", "xls", "xlsx", "csv", "pages", "jpg", "jpeg", "png", "heic"].contains(value) ? value : "other"
    }

    static func recordExtraction(succeeded: Bool, format: String? = nil) {
        lock.withLock { _ in
            var d = dict()
            let hour = Int(Date().timeIntervalSince1970 / 3600)
            d["extract.\(hour).att", default: 0] += 1
            if succeeded { d["extract.\(hour).suc", default: 0] += 1 }
            if let format {
                let prefix = "extractfmt.\(extractionFormat(format)).\(hour)"
                d[prefix + ".att", default: 0] += 1
                if succeeded { d[prefix + ".suc", default: 0] += 1 }
            }
            prune(&d, hour: hour)
            save(d)
        }
    }

    static func extractionTotals(_ values: [String: Int], now: Date = Date(), format: String? = nil) -> (attempts: Int, successes: Int) {
        let hour = Int(now.timeIntervalSince1970 / 3600)
        var attempts = 0, successes = 0
        let prefix = format.map { "extractfmt.\(extractionFormat($0))." } ?? "extract."
        for (key, value) in values where key.hasPrefix(prefix) {
            let parts = key.dropFirst(prefix.count).split(separator: ".")
            guard parts.count == 2, let recorded = Int(parts[0]), recorded > hour - extractionWindowHours, recorded <= hour else { continue }
            if parts[1] == "att" { attempts += value }
            if parts[1] == "suc" { successes += value }
        }
        return (attempts, successes)
    }

    static func checkExtractionRate() {
        let values = lock.withLock { _ in
            var d = dict(); prune(&d, hour: Int(Date().timeIntervalSince1970 / 3600)); save(d)
            return d
        }
        let formats = Set(values.keys.filter { $0.hasPrefix("extractfmt.") }.compactMap { $0.split(separator: ".").dropFirst().first.map { extractionFormat(String($0)) } })
        for format in [String?.none] + formats.sorted().map({ Optional($0) }) {
            let totals = extractionTotals(values, format: format)
            guard totals.attempts >= (format == nil ? extractionMinSamples : 10) else { continue }
            let pct = totals.successes * 100 / totals.attempts
            if pct < extractionFloorPct {
                CrashReporting.captureEvent("files.extraction_degraded", level: .warning,
                    tags: ["source": "file", "format": format ?? "all"],
                    extra: ["attempts": String(totals.attempts), "success_pct": String(pct), "window_hours": String(extractionWindowHours)],
                    fingerprint: ["files", "extraction_degraded", format ?? "all"], cooldown: 86400)
            }
        }
    }

    /// Small daily runs share a seven-day structural parser counter. Never stores item identifiers.
    static func recordTriage(source: String, failed: Bool) {
        let family = Diagnostics.source(source)
        let totals: (Int, Int) = lock.withLock { _ in
            var d = dict()
            let hour = Int(Date().timeIntervalSince1970 / 3600)
            let prefix = "parse.\(family)."
            d["\(prefix)\(hour).att", default: 0] += 1
            if failed { d["\(prefix)\(hour).fail", default: 0] += 1 }
            var attempted = 0, failures = 0
            for key in Array(d.keys) where key.hasPrefix("parse.") {
                let parts = key.split(separator: ".")
                guard parts.count == 4, let recorded = Int(parts[2]), recorded > hour - extractionWindowHours, recorded <= hour else { d[key] = nil; continue }
                if key.hasPrefix(prefix) {
                    if parts[3] == "att" { attempted += d[key] ?? 0 }
                    if parts[3] == "fail" { failures += d[key] ?? 0 }
                }
            }
            save(d)
            return (attempted, failures)
        }
        if totals.0 >= 5, totals.1 >= 3, totals.1 * 100 / totals.0 >= 20 {
            Diagnostics.report(.modelOutputInvalid, phase: .parse, reason: "rolling_triage_degradation", source: family,
                               counts: [.attempted: totals.0, .failed: totals.1], cooldown: 86400)
        }
    }

    private static func prune(_ values: inout [String: Int], hour: Int) {
        for key in Array(values.keys) where key.hasPrefix("extract.") || key.hasPrefix("extractfmt.") {
            let parts = key.split(separator: ".")
            if parts.count < 3 || Int(parts[parts.count - 2]).map({ $0 <= hour - extractionWindowHours || $0 > hour }) != false { values[key] = nil }
        }
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    private static func dict() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }
    private static func save(_ d: [String: Int]) { UserDefaults.standard.set(d, forKey: key) }
}
