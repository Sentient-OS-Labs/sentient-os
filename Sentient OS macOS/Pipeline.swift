//
//  Pipeline.swift
//  Sentient OS macOS
//
//  The loop that ties Sources + Engine + Store together (Arch §2.1). Fetches the pointer map,
//  scans each source for items PAST its pointers, and processes them in scan order (the
//  pointer contract, DataSource.swift: incremental keys ascend; a key's FIRST run is a
//  newest-first backfill descent): load content → Engine.generate → Triage.decide →
//  Store.record (summary version for survivors + the pointer advance, one transaction).
//  Initial run and incremental run are the SAME code path — a missing pointer simply means
//  "backfill everything, newest first" (connector caps still apply inside each source's scan).
//  Finished backfills reported by the scan collapse to plain pointers before processing.
//
//  Failure policy (pointer architecture, June 11): a failed item is retried ONCE on a fresh
//  engine when its failure triggered a reactive reload; an item that still fails is given up —
//  its pointer is not advanced by it, so it's retried next run only if nothing newer in its
//  pointer key succeeds (no failure bookkeeping anywhere, by design). Engine-wedge resilience
//  (preemptive + reactive reloads) is unchanged.
//

import Foundation

struct PipelineProgress: Sendable {
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

actor Pipeline {
    private let engine: Engine
    private let store: Store

    init(engine: Engine, store: Store) {
        self.engine = engine
        self.store = store
    }

    /// Process up to `limit` items past `source`'s pointers. `onProgress` fires after each item.
    @discardableResult
    func run<S: DataSource & Sendable>(
        source: S,
        currentDate: Date,
        limit: Int? = nil,
        onProgress: @Sendable (PipelineProgress) -> Void = { _ in }
    ) async throws -> PipelineProgress {
        let cursors = await store.cursors()
        let scan = try source.scan(since: cursors)
        // Backfills the scan found to be finished collapse to plain pointers first, so this
        // run's candidates (if any) write against the collapsed state the scan assumed.
        for (key, value) in scan.completions {
            try await store.advanceCursor(value, forKey: key)
        }
        var todo = scan.candidates
        if let limit, todo.count > limit { todo = Array(todo.prefix(limit)) }

        var p = PipelineProgress(total: todo.count)
        onProgress(p)

        // Resilience against LiteRT-LM's GPU executor wedging on long runs: under sustained
        // inference it can leave a GPU buffer in a bad state ("[Buffer] already has an outstanding
        // map pending"), after which EVERY generate() fails forever. We (a) PREEMPTIVELY reload the
        // engine every N items so the GPU state never accumulates to that point, and (b) REACTIVELY
        // reload after a burst of failures — giving up only if reloading stops making progress.
        let preemptiveReloadEvery = 40
        let failuresBeforeReload = 3
        let maxReloadsWithoutProgress = 4
        var consecutiveFailures = 0
        var reloadsWithoutProgress = 0
        var sinceReload = 0

        // Reset the on-device engine's GPU state, surfacing a brief note in the UI.
        func reloadEngine() async {
            p.lastFilePath = nil; p.lastVerdict = nil
            p.lastTitle = "Resetting on-device engine…"
            p.lastSummary = "The GPU runtime needs a quick reset — resuming shortly."
            onProgress(p)
            try? await engine.reload()
            sinceReload = 0
        }

        // One full attempt at one candidate: load → generate → decide → record (which also
        // advances the candidate's pointer, durably). Returns false on any failure.
        func attempt(_ cand: Candidate) async -> Bool {
            do {
                // Drain transient extraction buffers (image/PDF/AppKit) every file so RAM
                // doesn't creep across a long batch.
                let artifact = try autoreleasepool { try source.load(cand) }
                let result = try await engine.generate(
                    prompt: Triage.prompt(for: artifact, currentDate: currentDate),
                    imageData: artifact.imageData
                )
                let outcome = Triage.decide(result.text)
                #if DEBUG
                Log("• \(cand.metadata["displayPath"] ?? cand.id)\n  → \(outcome.verdict) | \(result.text.replacingOccurrences(of: "\n", with: " "))")
                #endif
                try await store.record(artifact: artifact, verdict: outcome.verdict, summary: outcome.draft)
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
                return true
            } catch {
                p.lastSummary = "(skipped: \(error))"
                return false
            }
        }

        for cand in todo {
            if Task.isCancelled { break }   // "Stop Analysis" — halt after the current item

            if sinceReload >= preemptiveReloadEvery { await reloadEngine() }

            p.lastPath = cand.metadata["displayPath"] ?? cand.metadata["name"]
            p.lastFilePath = cand.metadata["path"]

            var ok = await attempt(cand)
            if !ok {
                consecutiveFailures += 1
                if consecutiveFailures >= failuresBeforeReload {
                    guard reloadsWithoutProgress < maxReloadsWithoutProgress else {
                        #if DEBUG
                        Log("⛔️ Engine not recovering after \(reloadsWithoutProgress) reloads — stopping this pass.")
                        #endif
                        break   // reloading isn't helping — stop hammering a dead engine
                    }
                    await reloadEngine()
                    reloadsWithoutProgress += 1
                    consecutiveFailures = 0
                    ok = await attempt(cand)   // the wedge ate this item's first try — retry it once
                }
            }
            if ok {
                consecutiveFailures = 0
                reloadsWithoutProgress = 0   // we processed an item → the engine is healthy
            } else {
                p.failed += 1
            }
            sinceReload += 1
            p.done += 1
            onProgress(p)
        }
        return p
    }
}
