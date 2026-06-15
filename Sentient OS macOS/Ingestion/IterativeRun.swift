//
//  IterativeRun.swift
//  Sentient OS macOS
//
//  The connector-agnostic on-device orchestrator — what the dev "start on device" buttons call.
//  Drives any Connector:
//   • runInitial   (top→bottom): per bucket, clear it, walk items newest→oldest, then on completion
//                  set the bucket's mark = newest. (Interrupted ⇒ mark unset ⇒ iterative says "run
//                  initial first".)
//   • runIterative (bottom→top): per bucket, take items past the mark, walk oldest→newest, climbing
//                  the mark per item (so a stopped run resumes). No mark yet ⇒ skipped.
//  Reuses Engine + Triage + the GPU-wedge resilience. Survivors → CycleNote; junk/sensitive store
//  nothing (zero trace).
//

import Foundation

struct IterativeRun {
    let modelPath: String
    var store: CycleStore = .shared

    enum Mode { case initial, iterative }

    /// DEV-ONLY hook: surfaces the EXACT prompt per item and STREAMS the raw model response token by
    /// token. When this is `nil` (the product processing path), generation uses the fast one-shot
    /// `Engine.generate()` — no streaming, no per-item prompt capture. Streaming is dev-only by
    /// construction: only DevProcessingView passes a DevObserver.
    struct DevObserver: Sendable {
        /// New item STARTING — its exact prompt + display path + abs file path. Fires before the
        /// response streams, so the view can show the CURRENT item immediately (footer + a placeholder
        /// card) instead of lagging on the previous item. Resets the response pane.
        var onItemStart: @Sendable (_ prompt: String, _ displayPath: String?, _ filePath: String?) -> Void
        var onToken: @Sendable (String) -> Void    // one streamed chunk of the raw response
        /// Item fully parsed — swap the placeholder for the real summary card (progress now holds it).
        var onItemDone: @Sendable () -> Void = {}
        /// Awaited AFTER each item's response is delivered — the dev "pause between items" throttle
        /// (the view sleeps here when its checkbox is on, so you can read the response). Default: no-op.
        var afterItem: @Sendable () async -> Void = {}
    }

    private static let preemptiveReloadEvery = 40
    private static let failuresBeforeReload = 3
    private static let maxReloadsWithoutProgress = 4

    @discardableResult
    func runInitial(_ connectors: [any Connector], dev: DevObserver? = nil,
                    onProgress: @Sendable @escaping (PipelineProgress) -> Void = { _ in }) async -> PipelineProgress {
        await run(connectors, mode: .initial, dev: dev, onProgress: onProgress)
    }

    @discardableResult
    func runIterative(_ connectors: [any Connector], dev: DevObserver? = nil,
                      onProgress: @Sendable @escaping (PipelineProgress) -> Void = { _ in }) async -> PipelineProgress {
        await run(connectors, mode: .iterative, dev: dev, onProgress: onProgress)
    }

    /// Runs each connector's buckets through ONE engine (sized to the biggest connector). The dev
    /// buttons pass every selected source at once; per-connector load + kind ride along per bucket.
    private func run(_ connectors: [any Connector], mode: Mode, dev: DevObserver? = nil,
                     onProgress: @Sendable @escaping (PipelineProgress) -> Void) async -> PipelineProgress {
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
            p.lastFilePath = nil; p.lastVerdict = nil; p.lastReminder = false
            p.lastTitle = "Resetting on-device engine…"
            p.lastSummary = "The GPU runtime needs a quick reset — resuming shortly."
            onProgress(p)
            try? await engine.reload()
            sinceReload = 0
        }

        // One full attempt at one item: load → generate → decide → (survivor ⇒ recordNote).
        func attempt(_ cand: Candidate, connector: any Connector, bucketKey: String) async -> Bool {
            do {
                let artifact = try autoreleasepool { try connector.load(cand) }
                let prompt = Triage.prompt(for: artifact, currentDate: Date())
                // Streaming is DEV-ONLY: only when a DevObserver is attached. Production → generate().
                let result: Engine.Result
                if let dev {
                    dev.onItemStart(prompt, cand.metadata["displayPath"] ?? cand.metadata["name"], cand.metadata["path"])
                    result = try await engine.generateStream(prompt: prompt, imageData: artifact.imageData) {
                        dev.onToken($0)
                    }
                } else {
                    result = try await engine.generate(prompt: prompt, imageData: artifact.imageData)
                }
                let outcome = Triage.decide(result.text)
                if outcome.verdict == .survivor {
                    await store.recordNote(
                        bucketKey: bucketKey, kind: connector.kind, sourceID: cand.id,
                        folder: cand.metadata["folder"] ?? "", itemDate: cand.itemDate,
                        text: outcome.summary, title: outcome.title, reminderFlagged: outcome.reminder)
                }
                LifetimeStats.bump(outcome.verdict)
                switch outcome.verdict {
                case .survivor:  p.survivors += 1
                case .junk:      p.junk += 1
                case .sensitive: p.sensitive += 1
                }
                if outcome.reminder { p.reminders += 1 }
                p.lastTitle = outcome.title
                p.lastSummary = outcome.summary.isEmpty ? nil : outcome.summary
                p.lastVerdict = outcome.verdict
                p.lastReminder = outcome.reminder
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

        // Initial wants everything (we clear + reprocess) → pass [:]. Iterative passes the real
        // marks so connectors can query efficiently; the run still filters/advances authoritatively.
        let marks = mode == .initial ? [:] : await store.allPointers()

        runLoop: for connector in connectors {
            if Task.isCancelled { break }
            let buckets: [Bucket]
            do { buckets = try connector.buckets(since: marks) }
            catch { Log("IterativeRun: buckets() failed for \(connector.kind) — \(error)"); continue }

            for bucket in buckets {
                if Task.isCancelled { break runLoop }
                let work: [(key: ItemKey, item: Candidate)]
                switch mode {
                case .initial:
                    await store.clearBucket(bucket.key)
                    work = bucket.items                                            // newest → oldest
                case .iterative:
                    guard let mark = await store.pointer(bucket.key) else {
                        Log("IterativeRun: \(bucket.key) has no pointer — run initial first; skipping.")
                        continue
                    }
                    work = bucket.items.filter { $0.key > mark }.sorted { $0.key < $1.key }   // oldest → newest
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

                    if mode == .iterative { await store.setPointer(bucket.key, w.key) }   // climb per item
                    sinceReload += 1; p.done += 1
                    onProgress(p)
                    if let dev {
                        dev.onItemDone()         // placeholder → real summary card (progress holds it now)
                        await dev.afterItem()    // dev throttle: pause between items when on
                    }
                }

                // INITIAL completed this bucket's full descent → everything ≤ newest done → set mark.
                if mode == .initial, finished, let newest = bucket.items.first?.key {
                    await store.setPointer(bucket.key, newest)
                }
            }
        }
        await engine.unload()
        return p
    }
}
