//
//  IterativeRun.swift
//  Sentient OS macOS
//
//  The connector-agnostic on-device orchestrator — the ONE engine path behind BOTH the home
//  "Analyze Now" takeover and the dev "start on device" buttons (both via ProcessingView). Drives
//  any Connector through ONE Engine (sized to the biggest connector), per BUCKET. Every processed
//  item commits its (optional) survivor note AND its progress marker in ONE atomic store write — so a
//  crash mid-run resumes, never duplicates, never skips:
//   • .initial   (top→bottom): fill the bucket newest→oldest, sinking a FLOOR per item (the oldest
//                  done so far). A crash RESUMES strictly below the floor instead of restarting; on
//                  reaching the bottom the floor collapses into the normal high-water mark.
//   • .iterative (bottom→top): take items past the mark, walk oldest→newest, advancing the mark per
//                  item. No mark yet (or a first run unfinished) ⇒ skipped — run initial first.
//   • .auto:      per bucket — initial if it has no mark yet OR a first run is mid-descent (floor
//                  set, i.e. resume it), else iterative. This is the home button's mode: the first
//                  run backfills, every run after catches up, a freshly-added folder backfills while
//                  the rest catch up, and an interrupted first run picks up where it left off.
//  Reuses Engine + Triage + the GPU-wedge resilience (preemptive + reactive reloads). Survivors →
//  CycleNote; junk/sensitive store nothing (zero trace). Synchronous generate() only — no streaming.
//

import Foundation

// MARK: - Per-item extraction timeout (Arch §H — one corrupt/huge file must never hang the run)

private struct ExtractionTimeout: Error { let seconds: Double }

/// Holds the racing continuation behind a lock so it resumes exactly once, and so the `@Sendable`
/// dispatch closures capture this (`@unchecked Sendable`) box instead of the continuation directly.
///
/// Deliberately NON-GENERIC. A generic `TimeoutBox<T>` crashes the Swift optimizer — the
/// `EarlyPerfInliner` pass infinite-recurses on the generic class's `deinit` layout under `-O`,
/// which segfaults swift-frontend and breaks EVERY Release/Archive build (Debug is `-Onone`, so it
/// builds fine — the bug hides until you ship). We erase the element type at the boundary below: the
/// box stores a `fire` closure that already captures the typed continuation, so only an erased
/// `Result<Any, Error>` crosses the box. The success value is always a `T`, so the downcast is total.
private final class TimeoutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fire: ((Result<Any, Error>) -> Void)?
    init(_ fire: @escaping (Result<Any, Error>) -> Void) { self.fire = fire }
    func resume(_ result: Result<Any, Error>) {
        lock.lock(); let f = fire; fire = nil; lock.unlock()
        f?(result)
    }
}

/// Runs blocking `work` with a hard wall-clock cap, resolving to whichever wins — the work
/// finishing or the deadline. On timeout it throws `ExtractionTimeout` and the run moves on; a
/// truly-hung synchronous extractor keeps running on its background thread (sync work can't be
/// force-killed) but never blocks the pipeline. FilesSource's size ceiling is the first-line guard
/// against this; the timeout is the backstop for a small-but-corrupt file.
private func withExtractionTimeout<T: Sendable>(_ seconds: Double,
                                                _ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        // Erase T here so TimeoutBox stays non-generic (see its note). The success value is always
        // a T, so the downcast in `map` is total.
        let box = TimeoutBox { result in cont.resume(with: result.map { $0 as! T }) }
        DispatchQueue.global(qos: .utility).async { box.resume(Result { try work() as Any }) }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            box.resume(.failure(ExtractionTimeout(seconds: seconds)))
        }
    }
}

/// Live progress for one analysis run — the bar, the verdict counts, and the most-recently-processed
/// item (its prompt/title/summary/verdict). Every snapshot is internally consistent: all the `last*`
/// fields describe the SAME item, so a UI can show them together without desync. Read by ProcessingView.
struct RunProgress: Sendable {
    var total = 0
    var done = 0
    var survivors = 0
    var junk = 0
    var sensitive = 0
    var failed = 0
    var lastPath: String?
    var lastFilePath: String?      // absolute path (for the thumbnail)
    var lastPrompt: String?        // the EXACT prompt fed to the model for this item (dev prompt pane)
    var lastTitle: String?
    var lastSummary: String?
    var lastVerdict: Verdict?
    var lastSeconds: Double?
    var totalSeconds: Double = 0   // sum over successful generations (for avg)
}

struct IterativeRun {
    let modelPath: String
    var store: CycleStore = .shared

    enum Mode { case initial, iterative, auto }

    private static let preemptiveReloadEvery = 40
    private static let failuresBeforeReload = 3
    private static let maxReloadsWithoutProgress = 4
    private static let extractionTimeoutSeconds: Double = 30   // Arch §H: one file's content extraction can't hang the run
    private static let sourceTimeCapSeconds: Double = 3600     // §5: a source gets ≤60 min wall-clock, then we move on (progress is per-item atomic, so it just resumes next run)

    /// Runs each connector's buckets through ONE engine (sized to the biggest connector). The caller
    /// passes every selected source at once; per-connector load + kind ride along per bucket.
    @discardableResult
    func run(_ connectors: [any Connector], mode: Mode,
             onProgress: @Sendable @escaping (RunProgress) -> Void = { _ in }) async -> RunProgress {
        var p = RunProgress()
        guard !connectors.isEmpty else { return p }
        let engine = Engine(modelPath: modelPath, maxNumTokens: connectors.map(\.maxTokens).max() ?? 4096)
        do { try await engine.load() } catch {
            Log("IterativeRun: engine load failed — \(error)")
            return p
        }

        var sinceReload = 0
        var consecutiveFailures = 0
        var reloadsWithoutProgress = 0

        func reloadEngine() async {
            p.lastFilePath = nil; p.lastVerdict = nil
            p.lastTitle = "Resetting on-device engine…"
            p.lastSummary = "The GPU runtime needs a quick reset — resuming shortly."
            onProgress(p)
            try? await engine.reload()
            sinceReload = 0
        }

        // One full attempt at one item: load → generate → decide. Returns whether it succeeded and,
        // for a survivor, the NoteDraft to commit — the loop writes it atomically WITH the marker, so
        // a crash never leaves a note without its marker. The exact prompt is stashed on the progress
        // so ProcessingView's dev pane can show it.
        func attempt(_ cand: Candidate, connector: any Connector) async -> (ok: Bool, draft: NoteDraft?) {
            do {
                let artifact = try await withExtractionTimeout(Self.extractionTimeoutSeconds) {
                    try autoreleasepool { try connector.load(cand) }
                }
                let prompt = Triage.prompt(for: artifact, currentDate: Date())
                p.lastPrompt = prompt
                let result = try await engine.generate(prompt: prompt, imageData: artifact.imageData)
                let outcome = Triage.decide(result.text)
                var draft: NoteDraft?
                if outcome.verdict == .survivor {
                    draft = NoteDraft(kind: connector.kind, sourceID: cand.id,
                                      folder: cand.metadata["folder"] ?? "", itemDate: cand.itemDate,
                                      text: outcome.summary, title: outcome.title, reminderFlagged: false)
                }
                LifetimeStats.bump(outcome.verdict)
                switch outcome.verdict {
                case .survivor:  p.survivors += 1
                case .junk:      p.junk += 1
                case .sensitive: p.sensitive += 1
                }
                p.lastTitle = outcome.title
                p.lastSummary = outcome.summary.isEmpty ? nil : outcome.summary
                p.lastVerdict = outcome.verdict
                p.lastSeconds = result.totalTime
                p.totalSeconds += result.totalTime
                #if DEBUG
                Log("• \(cand.metadata["displayPath"] ?? cand.id) → \(outcome.verdict)")
                #endif
                return (true, draft)
            } catch {
                p.lastSummary = "(skipped: \(error))"
                return (false, nil)
            }
        }

        // Explicit INITIAL reprocesses from scratch → pass [:]. Otherwise pass the per-bucket marks as
        // a connector query hint (connectorMarks omits mid-first-run buckets so their connector returns
        // the FULL set — the descent needs items below the top); the run still filters authoritatively.
        let marks = mode == .initial ? [:] : await store.connectorMarks()

        runLoop: for connector in connectors {
            if Task.isCancelled { break }
            let buckets: [Bucket]
            do { buckets = try connector.buckets(since: marks) }
            catch { Log("IterativeRun: buckets() failed for \(connector.kind) — \(error)"); continue }

            // §5: each SOURCE gets a 60-minute wall-clock budget spanning all its buckets. On overrun
            // we stop THIS source and move to the next — every item's mark commits atomically, so a
            // cut-off source just resumes next run. `processedThisConnector` feeds the cap event.
            let connectorDeadline = Date().addingTimeInterval(Self.sourceTimeCapSeconds)
            var processedThisConnector = 0

            bucketLoop: for bucket in buckets {
                if Task.isCancelled { break runLoop }

                var state = await store.pointerState(bucket.key)

                // Per-bucket effective mode. .auto: no state → fresh first run; floor still set → a
                // first run was interrupted, RESUME it; collapsed (floor nil) → everyday catch-up.
                let effective: Mode
                switch mode {
                case .auto:      effective = (state == nil || state?.floor != nil) ? .initial : .iterative
                case .initial:   effective = .initial
                case .iterative: effective = .iterative
                }

                // Build this bucket's ordered work; for a first run, also capture the fixed TOP.
                let work: [(key: ItemKey, item: Candidate)]
                let top: ItemKey?
                switch effective {
                case .initial:
                    // Explicit INITIAL = full reset (re-summarize everything). An .auto-chosen initial
                    // (fresh first run OR resuming an interrupted one) keeps its partial progress.
                    if mode == .initial { await store.clearBucket(bucket.key); state = nil }
                    let resumeFloor = state?.floor
                    let descentTop: ItemKey
                    if let m = state?.mark, resumeFloor != nil {
                        descentTop = m                                   // resume: top was saved
                    } else if let newest = bucket.items.first?.key {
                        descentTop = newest                              // fresh: top = newest
                    } else {
                        continue                                         // empty bucket — nothing to do
                    }
                    top = descentTop
                    work = bucket.items
                        .filter { $0.key <= descentTop && (resumeFloor == nil || $0.key < resumeFloor!) }
                        .sorted { $0.key > $1.key }                      // newest → oldest (top-down)
                case .iterative:
                    guard let s = state, s.floor == nil else {
                        Log("IterativeRun: \(bucket.key) — \(state == nil ? "no pointer" : "first run unfinished"); run initial first; skipping.")
                        continue
                    }
                    top = nil
                    work = bucket.items.filter { $0.key > s.mark }.sorted { $0.key < $1.key }   // oldest → newest
                case .auto:
                    continue   // resolved into .initial / .iterative above; never reached
                }

                p.total += work.count
                onProgress(p)

                var finished = true
                for w in work {
                    if Task.isCancelled { finished = false; break runLoop }
                    // §5: source over its 60-min budget → stop this source (all its buckets), next source.
                    if Date() >= connectorDeadline {
                        Log("IterativeRun: \(connector.kind) hit the \(Int(Self.sourceTimeCapSeconds))s cap after \(processedThisConnector) items — moving to next source")
                        CrashReporting.captureEvent("source.hit_time_cap", level: .warning,
                            tags: ["source": connector.kind.rawValue],
                            extra: ["processed": String(processedThisConnector),
                                    "cap_seconds": String(Int(Self.sourceTimeCapSeconds))])
                        finished = false
                        break bucketLoop
                    }
                    if sinceReload >= Self.preemptiveReloadEvery { await reloadEngine() }

                    p.lastPath = w.item.metadata["displayPath"] ?? w.item.metadata["name"]
                    p.lastFilePath = w.item.metadata["path"]

                    var (ok, draft) = await attempt(w.item, connector: connector)
                    if !ok {
                        consecutiveFailures += 1
                        if consecutiveFailures >= Self.failuresBeforeReload {
                            guard reloadsWithoutProgress < Self.maxReloadsWithoutProgress else {
                                Log("IterativeRun: engine not recovering after \(reloadsWithoutProgress) reloads — stopping.")
                                finished = false; break runLoop
                            }
                            await reloadEngine(); reloadsWithoutProgress += 1; consecutiveFailures = 0
                            (ok, draft) = await attempt(w.item, connector: connector)
                        }
                    }
                    if ok { consecutiveFailures = 0; reloadsWithoutProgress = 0 } else { p.failed += 1; draft = nil }

                    // ONE atomic store write per item: optional survivor note + marker advance — no gap
                    // for a crash to land in. Iterative climbs the mark; initial sinks the floor.
                    switch effective {
                    case .iterative: await store.advance(bucketKey: bucket.key, note: draft, to: w.key)
                    case .initial:   await store.sinkFloor(bucketKey: bucket.key, note: draft, top: top!, floor: w.key)
                    case .auto:      break
                    }
                    sinceReload += 1; p.done += 1; processedThisConnector += 1
                    onProgress(p)
                }

                // First run reached the bottom → collapse the floor into the normal high-water mark.
                if effective == .initial, finished, top != nil {
                    await store.collapseFloor(bucket.key)
                }
            }
        }
        await engine.unload()
        return p
    }
}
