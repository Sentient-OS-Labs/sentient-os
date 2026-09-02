//
//  MCPSource.swift
//  Sentient OS macOS  ·  Sources/
//
//  The generic connector KB read engine — GmailConnect/CalendarConnect, generalized to any
//  hosted connector whose "Use for knowledge base" toggle is on (`mcp.<slug>.kb`). Each
//  connector gets one bucket (`mcp.<slug>`) whose pointer is the high-water mark set to run
//  start (a little overlap next run beats a boundary gap), and every read rides the
//  unattended-read recipe (`Invocation.mcpReadConnectors`) on the light model tier. Reads are
//  all-or-nothing per connector: a failure leaves the mark untouched, so the next night's
//  iterative naturally covers the gap (no resume tokens).
//
//  Key methods:
//   - runInitial(slug:)    → first read, windowed per the pack's KBAdapter (.generic = ONE
//                            "last month" call; weekly/monthly drivers built for Step 3)
//   - runIterative(slug:)  → everything since the mark, one call; falls back to initial
//   - runAll(onEvent:)     → the per-cycle loop over kbEnabledConnectors() both chain drivers
//                            (ProcessingView + OvernightScheduler) share; a usage limit skips
//                            the remaining connectors
//   - kbSlugs()            → the enabled slugs (the chain's detect step)
//   - MCPReadActivity      → the toggle-ON moment-of-connection read (SourcesPane popover)
//
//  Doc: Sources/Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation
import Observation
import os

enum MCPSource {

    /// One iterative-store bucket per connector. Dot-joined (matching the `mcp.<slug>.kb`
    /// key family); slugs are directory/brand names, never user content, so the full key is
    /// safe to log.
    static func bucketKey(_ slug: String) -> String { "mcp.\(slug)" }

    /// The prompt's deep-open budgets: the initial read covers a month, the nightly window is
    /// usually a day, so iterative halves the cap (15/2, floor).
    private static let initialOpenCap = 15
    private static let iterativeOpenCap = 7

    enum MCPError: LocalizedError {
        /// The slug resolves to no server, or (Claude) has neither curated nor classified read
        /// tools — the unattended-read recipe would refuse it, so refuse cleanly up front.
        case noReadSurface(slug: String)
        case dateMath

        var errorDescription: String? {
            switch self {
            case .noReadSurface(let slug):
                return "The \(ConnectorRegistry.displayName(slug: slug)) connector has no verified read tools yet."
            case .dateMath:
                return "Connector read date math failed."
            }
        }
    }

    /// Parsed read result (from the structured reply).
    private struct ReadResult: Sendable {
        let summary: String
        let hasActionItems: Bool
        let itemCount: Int
    }

    /// Structured progress for the processing UI — CalendarConnect's sequential shape (one
    /// window STARTING then FINISHING), plus `.failed`, which `runAll` emits so the takeover
    /// can render a per-connector failure card without a second callback.
    enum Progress: Sendable {
        case windowStart(step: Int, total: Int, label: String, prompt: String)
        case windowDone(step: Int, total: Int, label: String, summary: String?, items: Int, keptSoFar: Int)
        case failed(label: String, message: String)
    }

    // MARK: - The per-cycle loop (both chain drivers call this)

    /// The KB-enabled slugs for the live backend (empty on a custom endpoint — the registry is
    /// backend-scoped and detection-filtered, so a stale toggle for an unlinked app never runs).
    static func kbSlugs() -> [String] { ConnectorRegistry.kbEnabledConnectors().map(\.slug) }

    /// One connector's night: "ok", or the closed-vocabulary reason it failed/skipped.
    struct LegOutcome: Sendable {
        let slug: String
        let result: String
    }

    /// Read every KB-enabled connector, iterative each (initial when unread) — ONE call per
    /// connector per night on `.generic`. Per-connector all-or-nothing; a usage-limit error
    /// skips the remaining connectors (their marks didn't move, so next night covers the gap).
    /// `onEvent` gets `(slug, index, count, event)` so the takeover can map windows onto its
    /// bar; the scheduler ignores it and reads the outcomes.
    static func runAll(
        onEvent: @Sendable @escaping (String, Int, Int, Progress) -> Void = { _, _, _, _ in }
    ) async -> (outcomes: [LegOutcome], hitUsageLimit: Bool) {
        let slugs = kbSlugs()
        var outcomes: [LegOutcome] = []
        var hitUsageLimit = false
        for (index, slug) in slugs.enumerated() {
            if hitUsageLimit {
                outcomes.append(LegOutcome(slug: slug, result: "skipped"))
                continue
            }
            do {
                _ = try await runIterative(slug: slug) { event in
                    onEvent(slug, index, slugs.count, event)
                }
                outcomes.append(LegOutcome(slug: slug, result: "ok"))
            } catch {
                if case CodexCLI.CLIError.usageLimit = error { hitUsageLimit = true }
                let reason = CodexFailureReason.classify(error).rawValue
                Log("MCPSource.runAll(\(slug)): ✗ \(ErrorLabel(error)) — \(reason)")
                outcomes.append(LegOutcome(slug: slug, result: reason))
                onEvent(slug, index, slugs.count,
                        .failed(label: ConnectorRegistry.displayName(slug: slug),
                                message: (error as? LocalizedError)?.errorDescription ?? "The read failed."))
            }
        }
        return (outcomes, hitUsageLimit)
    }

    // MARK: - Initial read (windowed per the pack's KBAdapter)

    /// Fresh start: wipe the bucket, read per the adapter, set the mark to run start once ALL
    /// windows land (any window failing aborts — mark unset, a retry re-runs from scratch).
    @discardableResult
    static func runInitial(slug: String,
                           onProgress: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> Int {
        try requireReadable(slug)
        guard claim(slug) else {
            Log("MCPSource.runInitial(\(slug)): a read is already in flight — skipping")
            return 0
        }
        defer { release(slug) }
        return try await initialCore(slug: slug, onProgress: onProgress)
    }

    // MARK: - Iterative read (since the high-water mark)

    /// One summary covering everything since the saved mark, then advance the mark. Falls back
    /// to a full initial read if the connector has never been read on this Mac.
    @discardableResult
    static func runIterative(slug: String,
                             onProgress: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> Int {
        try requireReadable(slug)
        guard claim(slug) else {
            Log("MCPSource.runIterative(\(slug)): a read is already in flight — skipping")
            return 0
        }
        defer { release(slug) }
        guard let mark = await CycleStore.shared.pointer(bucketKey(slug)) else {
            return try await initialCore(slug: slug, onProgress: onProgress)   // never read → initial
        }
        let since = Date(timeIntervalSince1970: mark.order)
        let runStart = Date()
        let name = ConnectorRegistry.displayName(slug: slug)
        let label = "since \(shortLabel(since))"
        let prompt = readPrompt(name: name,
                                window: "everything new or changed since \(fullLabel(since))",
                                openCap: iterativeOpenCap)
        onProgress(.windowStart(step: 1, total: 1, label: label, prompt: prompt))
        var recorded = 0
        if let r = try await read(slug: slug, prompt: prompt) {
            await record(r, slug: slug, name: name, itemDate: runStart, label: label)
            recorded = 1
            onProgress(.windowDone(step: 1, total: 1, label: label,
                                   summary: r.summary, items: r.itemCount, keptSoFar: 1))
        } else {
            onProgress(.windowDone(step: 1, total: 1, label: label,
                                   summary: nil, items: 0, keptSoFar: 0))
        }
        await CycleStore.shared.setPointer(bucketKey(slug),
                                           ItemKey(order: runStart.timeIntervalSince1970, tiebreak: ""))
        Log("MCPSource.runIterative(\(slug)): ✅ \(recorded) summary since \(since); pointer → \(runStart)")
        return recorded
    }

    // MARK: - Cores (unclaimed — the public entries above hold the per-slug in-flight lock)

    private static func initialCore(slug: String,
                                    onProgress: @Sendable @escaping (Progress) -> Void) async throws -> Int {
        await CycleStore.shared.clearBucket(bucketKey(slug))
        let runStart = Date()
        let name = ConnectorRegistry.displayName(slug: slug)
        let adapter = ConnectorRegistry.pack(forSlug: slug)?.kbAdapter ?? .generic
        let recorded: Int
        switch adapter {
        case .generic:
            recorded = try await readGenericInitial(slug: slug, name: name,
                                                    runStart: runStart, onProgress: onProgress)
        case .windowedWeekly:
            recorded = try await readWindowed(slug: slug, name: name, runStart: runStart,
                                              weekly: true, onProgress: onProgress)
        case .windowedMonthly:
            recorded = try await readWindowed(slug: slug, name: name, runStart: runStart,
                                              weekly: false, onProgress: onProgress)
        }
        await CycleStore.shared.setPointer(bucketKey(slug),
                                           ItemKey(order: runStart.timeIntervalSince1970, tiebreak: ""))
        Log("MCPSource.runInitial(\(slug)): ✅ \(recorded) summary(ies) recorded (\(adapter.rawValue)); pointer → \(runStart)")
        return recorded
    }

    /// `.generic` (every connector in Step 1): ONE call, roughly the last month.
    private static func readGenericInitial(slug: String, name: String, runStart: Date,
                                           onProgress: @Sendable @escaping (Progress) -> Void) async throws -> Int {
        let label = "last month"
        let prompt = readPrompt(name: name,
                                window: "roughly the last month, newest first",
                                openCap: initialOpenCap)
        onProgress(.windowStart(step: 1, total: 1, label: label, prompt: prompt))
        var recorded = 0
        if let r = try await read(slug: slug, prompt: prompt) {
            await record(r, slug: slug, name: name, itemDate: runStart, label: label)
            recorded = 1
            onProgress(.windowDone(step: 1, total: 1, label: label,
                                   summary: r.summary, items: r.itemCount, keptSoFar: 1))
        } else {
            onProgress(.windowDone(step: 1, total: 1, label: label,
                                   summary: nil, items: 0, keptSoFar: 0))
        }
        return recorded
    }

    /// The windowed drivers for Step 3's curated packs — Gmail's math for weekly (4 contiguous
    /// weeks, fired in PARALLEL, results in completion order) and Calendar's for monthly (12
    /// months, newest first, sequential). Only `.generic` is exercised in Step 1; the Step 3
    /// chats supply tuned prompts through `readPrompt`'s window seam.
    private static func readWindowed(slug: String, name: String, runStart: Date, weekly: Bool,
                                     onProgress: @Sendable @escaping (Progress) -> Void) async throws -> Int {
        struct Window: Sendable {
            let step: Int
            let label: String
            let prompt: String
            let itemDate: Date
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: runStart)
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: today) else { throw MCPError.dateMath }
        let count = weekly ? 4 : 12

        // Contiguous windows against end-of-today, newest first, no overlap (the Gmail/Calendar
        // boundary math: [tomorrow − unit·(i+1), tomorrow − unit·i)).
        var windows: [Window] = []
        for i in 0..<count {
            let upper = weekly ? cal.date(byAdding: .day, value: -7 * i, to: tomorrow)
                               : cal.date(byAdding: .month, value: -i, to: tomorrow)
            let lower = weekly ? cal.date(byAdding: .day, value: -7 * (i + 1), to: tomorrow)
                               : cal.date(byAdding: .month, value: -(i + 1), to: tomorrow)
            guard let upper, let lower,
                  let upperDay = cal.date(byAdding: .day, value: -1, to: upper) else {
                throw MCPError.dateMath
            }
            windows.append(Window(
                step: i + 1,
                label: "\(shortLabel(lower)) – \(shortLabel(upperDay))",
                prompt: readPrompt(name: name,
                                   window: "between \(fullLabel(lower)) and \(fullLabel(upperDay)), newest first",
                                   openCap: initialOpenCap),
                itemDate: upperDay))
        }

        var recorded = 0
        if weekly {
            // Parallel fan-out (independent windows, independent subprocesses); collect as each
            // finishes. Any window failing aborts the run — mark unset, a retry re-runs all.
            for w in windows { onProgress(.windowStart(step: w.step, total: count, label: w.label, prompt: w.prompt)) }
            var completed = 0
            try await withThrowingTaskGroup(of: (Window, ReadResult?).self) { group in
                for w in windows {
                    group.addTask { (w, try await read(slug: slug, prompt: w.prompt)) }
                }
                for try await (w, r) in group {
                    completed += 1
                    if let r {
                        await record(r, slug: slug, name: name, itemDate: w.itemDate, label: w.label)
                        recorded += 1
                    }
                    onProgress(.windowDone(step: completed, total: count, label: w.label,
                                           summary: r?.summary, items: r?.itemCount ?? 0,
                                           keptSoFar: recorded))
                }
            }
        } else {
            for w in windows {
                onProgress(.windowStart(step: w.step, total: count, label: w.label, prompt: w.prompt))
                let r = try await read(slug: slug, prompt: w.prompt)
                if let r {
                    await record(r, slug: slug, name: name, itemDate: w.itemDate, label: w.label)
                    recorded += 1
                }
                onProgress(.windowDone(step: w.step, total: count, label: w.label,
                                       summary: r?.summary, items: r?.itemCount ?? 0,
                                       keptSoFar: recorded))
            }
        }
        return recorded
    }

    // MARK: - One read (a single frontier call on the unattended-read recipe)

    private static func read(slug: String, prompt: String) async throws -> ReadResult? {
        var lastError: Error = MCPError.noReadSurface(slug: slug)
        for attempt in 1...2 {
            do {
                var inv = CodexCLI.Invocation(prompt: prompt)
                inv.feature = "mcp-read"
                inv.model = .gpt56luna               // light tier (haiku on the Claude engine)
                inv.effort = .medium
                inv.sandbox = .readOnly
                inv.webSearch = false                // the connector is the only source this needs
                inv.outputSchema = readSchema
                inv.timeout = 600
                inv.mcpReadConnectors = [slug]       // the unattended-read recipe, this server only
                let started = Date()
                let env = try await FrontierRun.run(inv)
                Log("MCPSource.read(\(slug)): \(env.result.count) chars in \(Int(Date().timeIntervalSince(started)))s"
                    + " · tokens in=\(env.inputTokens ?? 0) cached=\(env.cachedInputTokens ?? 0) out=\(env.outputTokens ?? 0)")
                return parse(env.result, slug: slug)
            } catch {
                // A usage limit won't resolve within the night and a recipe refusal is
                // deterministic — propagate both. Anything else gets ONE retry: the session's
                // first spawn occasionally never attaches the connector (field-found 2026-08-30).
                if case CodexCLI.CLIError.usageLimit = error { throw error }
                if case CodexCLI.CLIError.notAvailable = error { throw error }
                lastError = error
                if attempt == 1 {
                    Log("MCPSource.read(\(slug)): attempt 1 failed (\(ErrorLabel(error))) — one retry")
                }
            }
        }
        throw lastError
    }

    private static func record(_ r: ReadResult, slug: String, name: String,
                               itemDate: Date, label: String) async {
        await CycleStore.shared.recordNote(
            bucketKey: bucketKey(slug), kind: .mcp,
            sourceID: "mcp:\(slug):\(Int(itemDate.timeIntervalSince1970))",   // unique per window
            folder: name, itemDate: itemDate, text: r.summary,
            title: "\(name) · \(label)", reminderFlagged: r.hasActionItems)
    }

    /// Fail-closed precondition, engine-symmetric: an unknown slug resolves to no server, and
    /// on the Claude engine a connector with neither curated nor classified reads has no allow
    /// list (the recipe builder would throw mid-spawn; refusing here is the clean version).
    private static func requireReadable(_ slug: String) throws {
        guard ConnectorRegistry.server(for: slug) != nil else { throw MCPError.noReadSurface(slug: slug) }
        if ModelBackend.current == .claude, ConnectorRegistry.readToolNames(slug: slug).isEmpty {
            throw MCPError.noReadSurface(slug: slug)
        }
    }

    // MARK: - In-flight guard (a toggle-time read and a chain read must never overlap on one slug)

    private static let busy = OSAllocatedUnfairLock(initialState: Set<String>())

    private static func claim(_ slug: String) -> Bool {
        busy.withLock { $0.insert(slug).inserted }
    }

    private static func release(_ slug: String) {
        busy.withLock { _ = $0.remove(slug) }
    }

    // MARK: - Parse (tolerant; mirrors the Gmail/Calendar shape-mismatch discipline)

    /// SHAPE MISMATCH (no JSON, or the required `notable` key absent despite the output schema)
    /// is an engine/schema regression → event, slug as a tag. A QUIET period (`notable: false` /
    /// empty summary) is normal → silent nil.
    private static func parse(_ result: String, slug: String) -> ReadResult? {
        guard let span = jsonSpan(result),
              let data = span.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            shapeMismatch(slug: slug, missing: "json", len: result.count)
            return nil
        }
        guard let notable = obj["notable"] as? Bool else {
            shapeMismatch(slug: slug, missing: "notable", len: result.count)   // key names only — never values
            return nil
        }
        guard notable, let summary = obj["summary"] as? String,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ReadResult(summary: summary,
                          hasActionItems: obj["has_action_items"] as? Bool ?? false,
                          itemCount: obj["item_count"] as? Int ?? 0)
    }

    private static func shapeMismatch(slug: String, missing: String, len: Int) {
        CrashReporting.captureEvent("mcp.parse.shape_mismatch", level: .warning,
            tags: ["source": "mcp", "slug": slug],
            extra: ["missing": missing, "result_len": String(len)],
            fingerprint: ["mcp", "parse", "shape_mismatch"])
    }

    /// Widest `{ … }` span in a possibly-fenced reply.
    private static func jsonSpan(_ result: String) -> String? {
        if let s = result.firstIndex(of: "{"), let e = result.lastIndex(of: "}"), s < e {
            return String(result[s...e])
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Date helpers

    private static func shortLabel(_ d: Date) -> String {     // display: "Jun 8"
        let f = DateFormatter(); f.dateFormat = "MMM d"; f.timeZone = .current
        return f.string(from: d)
    }

    private static func fullLabel(_ d: Date) -> String {      // prompt boundary: "Jun 8, 2026"
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    // MARK: - Prompt + schema

    /// The structured reply contract — one dense summary plus the flags Sentient keys on.
    private static let readSchema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "item_count":{"type":"integer"},\
    "notable":{"type":"boolean"},\
    "has_action_items":{"type":"boolean"},\
    "summary":{"type":"string"}},\
    "required":["item_count","notable","has_action_items","summary"]}
    """

    /// The generic read prompt. `window` is the one seam the iterative read and the Step 3
    /// windowed packs vary; `openCap` is the deep-open budget (initial 15, iterative 7).
    private static func readPrompt(name: String, window: String, openCap: Int) -> String {
        """
        You are building a private knowledge base about the user. Using ONLY the \
        "\(name)" connector's read tools, look at the user's recent and important \
        content there (\(window)).

        DISCIPLINE (strict):
        - Search and list first; open at most \(openCap) individual items, only those that \
        look genuinely significant.
        - Skip anything automated, promotional, or trivial.
        - Never call a tool that creates, modifies, sends, or deletes. You are \
        read-only.

        Summarize what actually matters about the user's life or work as seen through \
        \(name): projects, commitments, deadlines, relationships, plans. Write in third \
        person ("the user ..."). Include an ACTION ITEMS section only when something \
        clearly needs doing. No em dashes.

        Reply with JSON matching the schema:
        {"item_count": <items considered>, "notable": true|false,
         "has_action_items": true|false, "summary": "<empty when notable is false>"}
        """
    }
}

// MARK: - The toggle-ON read (the SourcesPane popover's moment-of-connection read)

/// Owns the first read a just-enabled KB toggle kicks off, so the popover can be dismissed and
/// reopened without losing the progress line (the read itself continues either way). Skips when
/// the bucket was already read once (a re-toggle never re-reads; the nightly iterative covers
/// it) or while a pipeline run is active (a mid-cycle note could be wiped by the cycle's tail
/// after the mark advanced — the next chain's `.auto` fallback reads it safely instead).
@MainActor
@Observable
final class MCPReadActivity {
    static let shared = MCPReadActivity()
    private init() {}

    enum Phase: Equatable { case reading, done, failed }
    private(set) var phases: [String: Phase] = [:]

    func phase(for slug: String) -> Phase? { phases[slug] }

    func beginInitialIfNeeded(slug: String) {
        guard phases[slug] != .reading else { return }
        guard !PipelineActivity.shared.isRunning else {
            Log("MCPReadActivity(\(slug)): pipeline mid-run — the next analysis reads it")
            return
        }
        phases[slug] = .reading
        Task {
            if await CycleStore.shared.pointer(MCPSource.bucketKey(slug)) != nil {
                phases[slug] = nil          // already read once — nothing to do
                return
            }
            do {
                _ = try await MCPSource.runInitial(slug: slug)
                phases[slug] = .done
            } catch {
                Log("MCPReadActivity(\(slug)): ✗ \(ErrorLabel(error)) — the nightly read retries")
                phases[slug] = .failed
            }
        }
    }
}
