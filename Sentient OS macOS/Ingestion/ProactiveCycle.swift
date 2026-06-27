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
//  Key method: run(progress:) → String?  (nil = cycle completed; a message = the step that failed)
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

    /// When the last full cycle finished (UserDefaults) — drives the home's real "Synced · …" stamp.
    static let lastCycleKey = "proactive.lastCycleAt"

    /// Run the post-read tail (knowledge base → mirror → proactive → wipe). Returns nil on a fully
    /// successful cycle (summaries wiped), or the failure message if a step errored (summaries kept).
    /// Never throws — every failure is ALSO reported through `progress(.failed(…))` for the live UI.
    @discardableResult
    func run(progress: @escaping @Sendable (ProactiveCyclePhase) -> Void) async -> String? {
        let notes = await CycleStore.shared.notes().map(CloudNote.init)
        guard !notes.isEmpty else {                          // nothing new this cycle — harmless no-op
            UserDefaults.standard.set(Date(), forKey: Self.lastCycleKey)
            progress(.done(ready: ProactiveResearch.latest()?.ready.count ?? 0))
            return nil
        }

        // 1) Knowledge base — create first time, else a surgical update. 2) Push the mirror.
        let exists = FileManager.default.fileExists(atPath: VaultGenerator.vaultRoot.path)
        progress(.knowledgeBase(exists ? "Updating your knowledge…" : "Building your knowledge…"))
        do {
            if exists { _ = try await VaultCloud.shared.update(notes: notes) }
            else      { _ = try await VaultCloud.shared.create(notes: notes) }
        } catch {
            let m = "Knowledge base — \(Self.msg(error))"
            progress(.failed(m)); return m                   // half-edited vault isn't dirty; summaries kept
        }
        await VaultCloud.pushIfDirty()                       // no-op if the mirror is off

        // 2.5) The welcome "gift" — write it ONCE, the first time a knowledge base exists to read.
        //      Best-effort: it's a delight, never load-bearing, so a failure never fails the cycle.
        if GiftLetter.latest() == nil {
            progress(.knowledgeBase("Writing your welcome…"))
            do { _ = try await GiftLetter.shared.generate() }
            catch { Log("GiftLetter: welcome skipped — \(Self.msg(error))") }
        }

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
            let m = "Deciding — \(Self.msg(error))"
            progress(.failed(m)); return m
        }

        if items.isEmpty {
            ProactiveResearch.saveLatest(ReadyResult(ready: [], dropped: []))   // clear any stale cards
        } else {
            progress(.researching(items.count))
            do {
                _ = try await ProactiveResearch.shared.researchAndPrepare(items: items, notes: notes, calendarContext: calCtx)
            } catch {
                let m = "Preparing — \(Self.msg(error))"
                progress(.failed(m)); return m
            }
        }

        // 4) Wipe this cycle's summaries — the knowledge base is the durable memory now. Success only.
        await CycleStore.shared.wipeAllNotes()
        UserDefaults.standard.set(Date(), forKey: Self.lastCycleKey)
        progress(.done(ready: ProactiveResearch.latest()?.ready.count ?? 0))
        return nil
    }

    private static func msg(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }
}
