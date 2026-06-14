//
//  FileRun.swift
//  Sentient OS macOS
//
//  The files-iterative on-device orchestrator — what the dev UI's "start on device" buttons call.
//  Reuses Engine + Triage + FilesSource (eligibleFiles + load), writing survivor summaries and the
//  per-folder high-water mark into FileStore. Two directions:
//
//   • runInitial   (top→bottom): clear the root, walk the eligible files newest→oldest, then on
//                   completion set the mark = newest. The user watches it understand NOW first.
//                   (Interrupted ⇒ mark stays unset ⇒ iterative says "run initial first".)
//   • runIterative (bottom→top): take only files NEWER than the mark, walk oldest→newest, and
//                   climb the mark up per item (so a stopped run resumes, not skips). No mark yet
//                   ⇒ "run initial first", skipped.
//
//  Survivors write a FileNote; junk/sensitive store nothing (zero trace). GPU-wedge resilience
//  mirrors Pipeline's policy.
//

import Foundation

struct FileRun {
    let modelPath: String
    var store: FileStore = .shared

    enum Mode { case initial, iterative }

    // Engine-wedge resilience (identical policy to Pipeline.run).
    private static let preemptiveReloadEvery = 40
    private static let failuresBeforeReload = 3
    private static let maxReloadsWithoutProgress = 4

    @discardableResult
    func runInitial(roots: [FileRoot],
                    onProgress: @Sendable @escaping (PipelineProgress) -> Void = { _ in }) async -> PipelineProgress {
        await run(roots: roots, mode: .initial, onProgress: onProgress)
    }

    @discardableResult
    func runIterative(roots: [FileRoot],
                      onProgress: @Sendable @escaping (PipelineProgress) -> Void = { _ in }) async -> PipelineProgress {
        await run(roots: roots, mode: .iterative, onProgress: onProgress)
    }

    private func fileKey(_ c: Candidate) -> FileKey {
        FileKey(dateAdded: c.itemDate, path: c.metadata["path"] ?? c.id)
    }

    private func run(roots: [FileRoot], mode: Mode,
                     onProgress: @Sendable @escaping (PipelineProgress) -> Void) async -> PipelineProgress {
        var p = PipelineProgress()
        let engine = Engine(modelPath: modelPath, maxNumTokens: 4096)   // files KV cache (chats need more)
        do { try await engine.load() } catch {
            Log("FileRun: engine load failed — \(error)")
            return p
        }

        var sinceReload = 0
        var consecutiveFailures = 0
        var reloadsWithoutProgress = 0

        // Reset the wedged GPU state, surfacing a brief note in the UI.
        func reloadEngine() async {
            p.lastFilePath = nil; p.lastVerdict = nil; p.lastReminder = false
            p.lastTitle = "Resetting on-device engine…"
            p.lastSummary = "The GPU runtime needs a quick reset — resuming shortly."
            onProgress(p)
            try? await engine.reload()
            sinceReload = 0
        }

        // One full attempt at one file: load → generate → decide → (survivor ⇒ recordNote).
        // Updates `p`; returns false on any failure. The interval advance happens in the caller.
        func attempt(_ cand: Candidate, source: FilesSource, rootKey: String, dateAdded: Date) async -> Bool {
            do {
                let artifact = try autoreleasepool { try source.load(cand) }
                let result = try await engine.generate(
                    prompt: Triage.prompt(for: artifact, currentDate: Date()),
                    imageData: artifact.imageData)
                let outcome = Triage.decide(result.text)
                if outcome.verdict == .survivor {
                    await store.recordNote(
                        rootKey: rootKey,
                        folder: cand.metadata["folder"] ?? "",
                        path: cand.metadata["path"] ?? cand.id,
                        dateAdded: dateAdded,
                        text: outcome.summary,
                        title: outcome.title,
                        reminderFlagged: outcome.reminder)
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

        rootLoop: for root in roots {
            if Task.isCancelled { break }
            guard let source = root.source else { continue }
            let rootKey = source.cursorKey

            // Build this root's ordered work for the chosen direction.
            let all = source.eligibleFiles().map { (cand: $0, key: fileKey($0)) }   // newest-first
            let work: [(cand: Candidate, key: FileKey)]

            switch mode {
            case .initial:
                await store.clearFolder(rootKey: rootKey)   // fresh start; the mark is set on completion
                work = all                                  // newest → oldest (top→bottom)
            case .iterative:
                guard let mark = await store.pointer(forKey: rootKey) else {
                    Log("FileRun: \(rootKey) has no pointer — run initial first; skipping.")
                    continue
                }
                work = all.filter { $0.key > mark }.sorted { $0.key < $1.key }   // oldest → newest (bottom→top)
            }

            p.total += work.count
            onProgress(p)

            var finished = true
            for w in work {
                if Task.isCancelled { finished = false; break rootLoop }
                if sinceReload >= Self.preemptiveReloadEvery { await reloadEngine() }

                p.lastPath = w.cand.metadata["displayPath"] ?? w.cand.metadata["name"]
                p.lastFilePath = w.cand.metadata["path"]

                var ok = await attempt(w.cand, source: source, rootKey: rootKey, dateAdded: w.key.dateAdded)
                if !ok {
                    consecutiveFailures += 1
                    if consecutiveFailures >= Self.failuresBeforeReload {
                        guard reloadsWithoutProgress < Self.maxReloadsWithoutProgress else {
                            Log("FileRun: engine not recovering after \(reloadsWithoutProgress) reloads — stopping.")
                            finished = false; break rootLoop
                        }
                        await reloadEngine(); reloadsWithoutProgress += 1; consecutiveFailures = 0
                        ok = await attempt(w.cand, source: source, rootKey: rootKey, dateAdded: w.key.dateAdded)
                    }
                }
                if ok { consecutiveFailures = 0; reloadsWithoutProgress = 0 } else { p.failed += 1 }

                // ITERATIVE climbs the mark up per item (ascending → everything ≤ this is now done,
                // so a stopped run resumes here, not skips). INITIAL leaves it untouched mid-run —
                // its mark is set only once the whole descent finishes (below).
                if mode == .iterative { await store.setPointer(forKey: rootKey, w.key) }
                sinceReload += 1; p.done += 1
                onProgress(p)
            }

            // INITIAL finished this root's full descent → everything ≤ newest is done → set the mark.
            // (Interrupted/aborted → break rootLoop skips this → the mark stays unset, so iterative
            // correctly says "run initial first".)
            if mode == .initial, finished, let newest = all.first?.key {
                await store.setPointer(forKey: rootKey, newest)
            }
        }
        await engine.unload()
        return p
    }
}
