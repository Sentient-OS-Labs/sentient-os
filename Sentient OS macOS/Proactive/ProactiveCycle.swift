//
//  ProactiveCycle.swift
//  Sentient OS macOS  ·  Proactive/
//
//  The shared TAIL of a full processing cycle, run AFTER the on-device read leg (IterativeRun +
//  Gmail/Calendar) has filled CycleStore with this cycle's survivor summaries. One ordered chain,
//  reused by the home's real-mode Analyze Now and (later) the overnight 3am scheduler — so the
//  sequencing lives in exactly one place:
//
//    1. file the summaries into the knowledge base (VaultCloud: create first time, else update)
//    2. push the MCP mirror (no-op if it's off)
//    3. PROACTIVE — decide (Proactive) → research + prepare (ProactiveResearch) → persisted `latest`
//       (skipped entirely in knowledge-base-only mode — free/go plans have no quota for it)
//    4. WIPE the summaries (CycleStore) — the knowledge base is the durable memory now
//
//  The read leg itself stays with the caller (ProcessingView's takeover UI / the scheduler's keep-
//  awake loop). The wipe happens ONLY on a fully successful chain — a failure leaves the summaries in
//  place so a retry can pick up where it stopped. `progress` carries human-readable phases for the UI;
//  `onLine` streams codex's live play-by-play (the takeover's thought line — unused by the 3am run).
//
//  Key method: run(progress:) → CycleFailure?  (nil = cycle completed; else the step that failed,
//  classified so the UI can offer the right fix)
//

import Foundation

/// A human-facing phase of the proactive tail, surfaced to the takeover UI while it runs.
enum ProactiveCyclePhase: Sendable {
    case knowledgeBase(String)   // a status line ("Building/Updating your knowledge…")
    case deciding                // PART 1 — the judge
    case researching(Int)        // PART 2 — verifying + preparing N items
    case done(ready: Int)        // finished; N ready-to-fire cards await
    case failed(CycleFailure)    // a step errored; summaries were kept for retry
}

/// A failed cycle step. `kind` is the verified, user-actionable reason (codex signed out ·
/// offline · usage limit) when one could be established — nil means show `message` as-is.
struct CycleFailure: Sendable, Equatable {
    let message: String
    let kind: OvernightCaution.Kind?
}

actor ProactiveCycle {

    static let shared = ProactiveCycle()

    /// When the last full cycle finished (UserDefaults) — drives the Analysis popover's real
    /// "Last run: …" stamp.
    static let lastCycleKey = "proactive.lastCycleAt"

    /// Wipe every persisted trace of the proactive layer — the decide-stage decisions, the prepared
    /// cards, the welcome "gift", and the "Last run: …" stamp — so the home's "For You" deck comes
    /// back empty. Used by the dev "Reset everything", alongside the cycle-store + knowledge-base wipe.
    static func resetAll() {
        Proactive.clear()
        ProactiveResearch.clear()
        GiftLetter.clear()
        UserDefaults.standard.removeObject(forKey: lastCycleKey)
    }

    /// Run the post-read tail (knowledge base → mirror → proactive → wipe). Returns nil on a fully
    /// successful cycle (summaries wiped), or the classified failure if a step errored (summaries
    /// kept). Never throws — every failure is ALSO reported through `progress(.failed(…))` for the
    /// live UI. Every failure classifies (OvernightCaution.classify — signed out · offline · usage
    /// limit); `scheduled` marks the UNATTENDED 3am run, which additionally persists the kind as
    /// the morning-after caution (the home's banner) — a watched Analyze Now instead shows it live
    /// on the takeover's failed screen.
    /// `onLine` streams codex's humanized play-by-play (reasoning · commands · tool calls) from
    /// every cloud stage — the takeover's live thought line. nil (the 3am run) streams nothing.
    @discardableResult
    func run(scheduled: Bool = false,
             progress: @escaping @Sendable (ProactiveCyclePhase) -> Void,
             onLine: (@Sendable (String) -> Void)? = nil) async -> CycleFailure? {
        PipelineActivity.begin()                 // Settings' Reset is disabled while the tail runs
        defer { PipelineActivity.end() }
        let notes = await CycleStore.shared.notes().map(CloudNote.init)
        guard !notes.isEmpty else {                          // nothing new this cycle — harmless no-op
            UserDefaults.standard.set(Date(), forKey: Self.lastCycleKey)
            progress(.done(ready: ProactiveResearch.latest()?.ready.count ?? 0))
            return nil
        }

        // 1) Knowledge base — create first time, else a surgical update. 2) Push the mirror.
        let exists = FileManager.default.fileExists(atPath: VaultGenerator.vaultRoot.path)
        progress(.knowledgeBase(exists ? "Updating your knowledge…"
                                       : "Creating your perfect knowledge base from everything we've analyzed…"))
        do {
            if exists { _ = try await VaultCloud.shared.update(notes: notes, onLine: onLine) }
            else      { _ = try await VaultCloud.shared.create(notes: notes, onLine: onLine) }
            Analytics.signal(exists ? "KnowledgeBase.updated" : "KnowledgeBase.built",
                             parameters: ["newSummaries": "\(notes.count)"])
        } catch {
            Analytics.signal("KnowledgeBase.failed", parameters: ["phase": exists ? "update" : "build"])
            // half-edited vault isn't dirty; summaries kept
            return await Self.fail("Knowledge base: \(Self.msg(error))", error: error,
                                   scheduled: scheduled, progress: progress)
        }
        await VaultCloud.pushIfDirty()                       // no-op if the mirror is off

        // 2.5) The welcome "gift" — write it ONCE, the first time a knowledge base exists to read.
        //      Best-effort: it's a delight, never load-bearing, so a failure never fails the cycle.
        //      A gift that ALREADY existed before this cycle has had its day-one morning — it retires
        //      when this cycle's proactive stage replaces the deck (kb-only mode has no replace, so
        //      the free home's lone envelope lives on).
        let giftPreexisted = GiftLetter.latest() != nil
        if !giftPreexisted {
            progress(.knowledgeBase("Writing your welcome…"))
            do { _ = try await GiftLetter.shared.generate(onLine: onLine) }
            catch { Log("GiftLetter: welcome skipped — \(ErrorLabel(error))") }   // type only: msg() embeds raw codex output → Sentry breadcrumb
        }

        // 3) Proactive — decide, then research + prepare. Inject the live calendar when connected.
        //    Knowledge-base-only mode (free/go plan) skips the whole stage: no quota for it, and
        //    no Gmail/Calendar to ground it — the knowledge base + mirror + gift ARE the product.
        if CodexAuth.knowledgeBaseOnly {
            ProactiveResearch.saveLatest(ReadyResult(ready: [], dropped: []))   // never leave stale cards
        } else {
            var calCtx: String?
            if UserDefaults.standard.bool(forKey: "dbg.calendar.connected") {
                calCtx = await CalendarConnect.fetchProactiveContext()
            }

            progress(.deciding)
            let items: [ActionItem]
            do {
                items = try await Proactive.shared.findActionItems(from: notes, calendarContext: calCtx, onLine: onLine)
            } catch Proactive.ProError.noRecent {
                items = []                                   // nothing recent enough — clear cards, still success
            } catch {
                return await Self.fail("Deciding: \(Self.msg(error))", error: error,
                                       scheduled: scheduled, progress: progress)
            }
            Analytics.signal("Proactive.decided", parameters: ["items": "\(items.count)"])

            if items.isEmpty {
                ProactiveResearch.saveLatest(ReadyResult(ready: [], dropped: []))   // clear any stale cards
            } else {
                progress(.researching(items.count))
                do {
                    let result = try await ProactiveResearch.shared.researchAndPrepare(items: items, notes: notes, calendarContext: calCtx, onLine: onLine)
                    // Core tier; floatValue = the staged-card count, so a dashboard Sum is the
                    // "suggestions Sentient has prepared across the world" total.
                    Analytics.signal("Proactive.prepared", parameters: [
                        "ready": "\(result.ready.count)", "dropped": "\(result.dropped.count)"],
                        floatValue: Double(result.ready.count), tier: .core)
                } catch {
                    return await Self.fail("Preparing: \(Self.msg(error))", error: error,
                                           scheduled: scheduled, progress: progress)
                }
            }
            // The deck was replaced (new cards or a clean empty) — a pre-existing gift's day is done.
            if giftPreexisted { GiftLetter.clear() }
        }

        // 4) Wipe this cycle's summaries — the knowledge base is the durable memory now. Success only.
        await CycleStore.shared.wipeAllNotes()
        OvernightCaution.clear()                             // a full success retires any morning-after banner
        UserDefaults.standard.set(Date(), forKey: Self.lastCycleKey)
        OvernightScheduler.noteFirstCycleCompleted()   // "initial processing ended" → start the 14h auto-enable clock (once)
        progress(.done(ready: ProactiveResearch.latest()?.ready.count ?? 0))
        return nil
    }

    private static func msg(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }

    /// The one shape every catch site shares: classify the failure, persist the caution on the
    /// unattended run, surface it to the live UI, and hand it back for the caller's return.
    private static func fail(_ message: String, error: Error, scheduled: Bool,
                             progress: @Sendable (ProactiveCyclePhase) -> Void) async -> CycleFailure {
        let failure = CycleFailure(message: message, kind: await OvernightCaution.classify(error))
        if scheduled { OvernightCaution.record(failure.kind) }   // the morning-after banner
        progress(.failed(failure))
        return failure
    }
}
