//
//  ProactiveCycle.swift
//  Sentient OS macOS  ·  Ingestion/
//
//  The shared TAIL of a full processing cycle, run AFTER the on-device read leg (IterativeRun +
//  Gmail/Calendar) has filled CycleStore with this cycle's survivor summaries. One ordered chain,
//  reused by the home's real-mode Analyze Now and (later) the overnight 3am scheduler — so the
//  sequencing lives in exactly one place:
//
//    1. file the summaries into the knowledge base (VaultCloud: create first time, else update)
//    2. push the MCP mirror (no-op if it's off)
//    3. PROACTIVE — decide (Proactive) → research + prepare (ProactiveResearch) → persisted `latest`
//    4. WIPE the summaries (CycleStore) — the knowledge base is the durable memory now
//
//  The read leg itself stays with the caller (ProcessingView's takeover UI / the scheduler's keep-
//  awake loop). The wipe happens ONLY on a fully successful chain — a failure leaves the summaries in
//  place so a retry can pick up where it stopped. `progress` carries human-readable phases for the UI.
//
//  Key method: run(progress:) → Bool  (true = cycle completed; false = a step failed, summaries kept)
//

import Foundation

/// A human-facing phase of the proactive tail, surfaced to the takeover UI while it runs.
enum ProactiveCyclePhase: Sendable {
    case knowledgeBase(String)   // a status line ("Building/Updating your knowledge…")
    case deciding                // PART 1 — the judge
    case researching(Int)        // PART 2 — verifying + preparing N items
    case done(ready: Int)        // finished; N ready-to-fire cards await
    case failed(String)          // a step errored; summaries were kept for retry
}

actor ProactiveCycle {

    static let shared = ProactiveCycle()

    /// Run the post-read tail (knowledge base → mirror → proactive → wipe). Returns true on a fully
    /// successful cycle (summaries wiped), false if a step failed (summaries kept). Never throws — every
    /// failure is reported through `progress(.failed(…))` so the caller can just render it.
    @discardableResult
    func run(progress: @escaping @Sendable (ProactiveCyclePhase) -> Void) async -> Bool {
        let notes = await CycleStore.shared.notes().map(CloudNote.init)
        guard !notes.isEmpty else {                          // nothing new this cycle — harmless no-op
            progress(.done(ready: ProactiveResearch.latest()?.ready.count ?? 0))
            return true
        }

        // 1) Knowledge base — create first time, else a surgical update. 2) Push the mirror.
        let exists = FileManager.default.fileExists(atPath: VaultGenerator.vaultRoot.path)
        progress(.knowledgeBase(exists ? "Updating your knowledge…" : "Building your knowledge…"))
        do {
            if exists { _ = try await VaultCloud.shared.update(notes: notes) }
            else      { _ = try await VaultCloud.shared.create(notes: notes) }
        } catch {
            progress(.failed("Knowledge base — \(Self.msg(error))"))
            return false                                     // half-edited vault isn't dirty; summaries kept
        }
        await VaultCloud.pushIfDirty()                       // no-op if the mirror is off

        // 3) Proactive — decide, then research + prepare. Inject the live calendar when connected.
        var calCtx: String?
        if UserDefaults.standard.bool(forKey: "dbg.calendar.connected") {
            calCtx = await CalendarConnect.fetchProactiveContext()
        }

        progress(.deciding)
        let items: [ActionItem]
        do {
            items = try await Proactive.shared.findActionItems(from: notes, calendarContext: calCtx)
        } catch Proactive.ProError.noRecent {
            items = []                                       // nothing recent enough — clear cards, still success
        } catch {
            progress(.failed("Deciding — \(Self.msg(error))"))
            return false
        }

        if items.isEmpty {
            ProactiveResearch.saveLatest(ReadyResult(ready: [], dropped: []))   // clear any stale cards
        } else {
            progress(.researching(items.count))
            do {
                _ = try await ProactiveResearch.shared.researchAndPrepare(items: items, calendarContext: calCtx)
            } catch {
                progress(.failed("Preparing — \(Self.msg(error))"))
                return false
            }
        }

        // 4) Wipe this cycle's summaries — the knowledge base is the durable memory now. Success only.
        await CycleStore.shared.wipeAllNotes()
        progress(.done(ready: ProactiveResearch.latest()?.ready.count ?? 0))
        return true
    }

    private static func msg(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }
}
