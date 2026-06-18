//
//  IterativeRun.swift
//  Sentient OS macOS
//
//  The connector-agnostic on-device orchestrator — the ONE engine path behind BOTH the home
//  "Analyze Now" takeover and the dev "start on device" buttons (both via ProcessingView). Drives
//  any Connector through ONE Engine (sized to the biggest connector), per BUCKET:
//   • .initial   (top→bottom): clear the bucket, walk items newest→oldest, then on completion set
//                  the bucket's mark = newest. (Interrupted ⇒ mark unset ⇒ iterative says "run
//                  initial first".)
//   • .iterative (bottom→top): take items past the mark, walk oldest→newest, climbing the mark per
//                  item (so a stopped run resumes). No mark yet ⇒ skipped.
//   • .auto:      per bucket — initial if it has no mark yet, else iterative. This is the home
//                  button's mode: the first run backfills, every run after just catches up, and a
//                  freshly-added folder backfills while the rest catch up — all in one pass.
//  Reuses Engine + Triage + the GPU-wedge resilience (preemptive + reactive reloads). Survivors →
//  CycleNote; junk/sensitive store nothing (zero trace). Synchronous generate() only — no streaming.
//

import Foundation

struct IterativeRun {
    let modelPath: String
    var store: CycleStore = .shared

    enum Mode { case initial, iterative, auto }

    private static let preemptiveReloadEvery = 40
    private static let failuresBeforeReload = 3
    private static let maxReloadsWithoutProgress = 4

    /// Runs each connector's buckets through ONE engine (sized to the biggest connector). The caller
    /// passes every selected source at once; per-connector load + kind ride along per bucket.
    @discardableResult
    func run(_ connectors: [any Connector], mode: Mode,
             onProgress: @Sendable @escaping (PipelineProgress) -> Void = { _ in }) async -> PipelineProgress {
        var p = PipelineProgress()
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

        // One full attempt at one item: load → generate → decide → (survivor ⇒ recordNote). The
        // exact prompt is stashed on the progress so ProcessingView's dev pane can show it.
        func attempt(_ cand: Candidate, connector: any Connector, bucketKey: String) async -> Bool {
            do {
                let artifact = try autoreleasepool { try connector.load(cand) }
                let prompt = Triage.prompt(for: artifact, currentDate: Date())
                p.lastPrompt = prompt
                let result = try await engine.generate(prompt: prompt, imageData: artifact.imageData)
                let outcome = Triage.decide(result.text)
                if outcome.verdict == .survivor {
                    await store.recordNote(
                        bucketKey: bucketKey, kind: connector.kind, sourceID: cand.id,
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
                return true
            } catch {
                p.lastSummary = "(skipped: \(error))"
                return false
            }
        }

        // Initial wants everything (we clear + reprocess) → pass [:]. Iterative/auto pass the real
        // marks so connectors can query efficiently; the run still filters/advances authoritatively.
        let marks = mode == .initial ? [:] : await store.allPointers()

        runLoop: for connector in connectors {
            if Task.isCancelled { break }
            let buckets: [Bucket]
            do { buckets = try connector.buckets(since: marks) }
            catch { Log("IterativeRun: buckets() failed for \(connector.kind) — \(error)"); continue }

            for bucket in buckets {
                if Task.isCancelled { break runLoop }

                // Per-bucket effective mode: .auto = initial when the bucket has never completed an
                // initial run (no mark), else iterative — so one "Analyze Now" backfills new buckets
                // and catches up the rest in a single pass.
                let mark = await store.pointer(bucket.key)
                let effective: Mode = (mode == .auto) ? (mark == nil ? .initial : .iterative) : mode

                let work: [(key: ItemKey, item: Candidate)]
                switch effective {
                case .initial:
                    await store.clearBucket(bucket.key)
                    work = bucket.items                                            // newest → oldest
                case .iterative:
                    guard let mark else {
                        Log("IterativeRun: \(bucket.key) has no pointer — run initial first; skipping.")
                        continue
                    }
                    work = bucket.items.filter { $0.key > mark }.sorted { $0.key < $1.key }   // oldest → newest
                case .auto:
                    continue   // resolved into .initial / .iterative above; never reached
                }

                p.total += work.count
                onProgress(p)

                var finished = true
                for w in work {
                    if Task.isCancelled { finished = false; break runLoop }
                    if sinceReload >= Self.preemptiveReloadEvery { await reloadEngine() }

                    p.lastPath = w.item.metadata["displayPath"] ?? w.item.metadata["name"]
                    p.lastFilePath = w.item.metadata["path"]

                    var ok = await attempt(w.item, connector: connector, bucketKey: bucket.key)
                    if !ok {
                        consecutiveFailures += 1
                        if consecutiveFailures >= Self.failuresBeforeReload {
                            guard reloadsWithoutProgress < Self.maxReloadsWithoutProgress else {
                                Log("IterativeRun: engine not recovering after \(reloadsWithoutProgress) reloads — stopping.")
                                finished = false; break runLoop
                            }
                            await reloadEngine(); reloadsWithoutProgress += 1; consecutiveFailures = 0
                            ok = await attempt(w.item, connector: connector, bucketKey: bucket.key)
                        }
                    }
                    if ok { consecutiveFailures = 0; reloadsWithoutProgress = 0 } else { p.failed += 1 }

                    if effective == .iterative { await store.setPointer(bucket.key, w.key) }   // climb per item
                    sinceReload += 1; p.done += 1
                    onProgress(p)
                }

                // INITIAL completed this bucket's full descent → everything ≤ newest done → set mark.
                if effective == .initial, finished, let newest = bucket.items.first?.key {
                    await store.setPointer(bucket.key, newest)
                }
            }
        }
        await engine.unload()
        return p
    }
}
