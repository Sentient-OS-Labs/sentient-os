//
//  GmailConnect.swift
//  Sentient OS macOS
//
//  Gmail — the first CLOUD source (Google Calendar is the second, same shape — see CalendarConnect.swift).
//  Gmail can't be read on-device, so we both FETCH and SUMMARIZE through the user's own Codex Gmail
//  connector (account-level `codex_apps/gmail.*`, visible to `codex exec` even under
//  `--ignore-user-config` — measured live June 15, no CodexCLI change needed).
//
//  Connection: the user links Google on OpenAI's connector page (opened from CloudConnectSheet); we
//  confirm with `probeConnected()` through the shared ConnectorCensus (no AI read probe).
//
//  Reads (each summary is ONE ephemeral CycleNote in bucket "gmail"; the existing "tell cloud"
//  buttons add them to the vault, same as every other source):
//   • runInitial   — the last month as 4 WEEKLY `codex exec` calls, fired IN PARALLEL (one per
//                    week). Weekly chunking keeps each context window bounded (a heavy inbox
//                    measured at ~430 threads/week; one month in a single call would blow GPT-5.5's
//                    400k input cap); running the four concurrently makes the initial read ~4× faster.
//   • runIterative — everything since the saved high-water mark, in one call, then advance the mark.
//
//  The weekly prompt is DELIBERATELY disciplined: a naive "summarize this week" cost 220k tokens for
//  a mere count in testing (codex over-reads). It searches on metadata/snippets, caps at the newest
//  300 threads, and only opens the handful of threads that look genuinely important.
//
//  Doc: Sources/Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation

enum GmailConnect {

    /// The single iterative-store bucket for Gmail. Its pointer is the high-water mark (run start).
    static let bucketKey = "gmail"

    /// OpenAI's hosted Gmail connector page — opened from CloudConnectSheet's "Connect Gmail".
    /// Where the user links Google — engine-aware (decided 2026-08-23): OpenAI's hosted
    /// connector page on the ChatGPT backend, the claude.ai connector directory on the Claude
    /// backend. Custom backends never reach here (connectorsAvailable gates the chips).
    static var connectorURL: URL {
        ModelBackend.current == .claude
            ? URL(string: "https://claude.ai/new#settings/customize-connectors/directory/gmail-gmailmcp")!
            : URL(string: "https://chatgpt.com/plugins/plugin_connector_1p_95d39881713c8191931482a62d6edff9?q=gmail")!
    }

    /// Newest-N threads per read (the connector-limits doc's cap; a heavy week exceeds it).
    private static let threadCap = 300
    private static let initialWeeks = 4

    enum GmailError: LocalizedError {
        case dateMath
        var errorDescription: String? { "Gmail date math failed." }
    }

    /// Parsed weekly/iterative read result (from the structured codex reply).
    private struct ReadResult: Sendable {
        let summary: String
        let hasActionItems: Bool
        let threadCount: Int
    }

    /// One initial-run weekly window: its display label, the exact codex prompt, and the date the
    /// resulting CycleNote is stamped with (the window's last day).
    private struct Window: Sendable {
        let label: String
        let prompt: String
        let itemDate: Date
    }

    /// A finished window paired with its read (nil ⇒ nothing notable) — what each parallel task returns.
    private struct WindowResult: Sendable {
        let window: Window
        let result: ReadResult?
    }

    /// Structured progress for the dev processing UI. The initial run fires all windows in PARALLEL,
    /// so events arrive in completion order, not week order: `completed` (windows finished so far,
    /// 1...total) drives the bar; `keptSoFar` is how many produced a summary. `prompt` is the exact
    /// Codex ask (shown in the processing view's PROMPT pane); `summary` is nil when nothing notable.
    enum Progress: Sendable {
        case windowStart(total: Int, label: String, prompt: String)
        case windowDone(total: Int, label: String, summary: String?, threads: Int,
                        completed: Int, keptSoFar: Int)
    }

    // MARK: - Connection detection

    /// Refresh the same hosted-connector census used by every other connected app.
    static func probeConnected() async -> Bool {
        await ConnectorCensus.checkConnection(slug: "gmail")
    }

    // MARK: - Initial read (last month → 4 weekly summaries)

    /// Read four weekly windows concurrently, staging every summary before replacing notes
    /// and checkpoint in one save. Failed or cancelled reads preserve the previous bucket.
    @discardableResult
    static func runInitial(onProgress: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> Int {
        try await ModelBackend.$runOverride.withValue(ModelBackend.current) {
            try await readInitial(onProgress: onProgress, replaceNotes: true)
        }
    }

    private static func readInitial(onProgress: @Sendable @escaping (Progress) -> Void, replaceNotes: Bool) async throws -> Int {
        let runStart = Date()
        let cal = Calendar.current
        let today = cal.startOfDay(for: runStart)
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: today) else { throw GmailError.dateMath }

        // Build all 4 weekly windows up front: [tomorrow − 7·(week+1), tomorrow − 7·week) —
        // contiguous, no overlap. Their order is now cosmetic; the reads all run together.
        var windows: [Window] = []
        for week in 0..<initialWeeks {
            guard let upper = cal.date(byAdding: .day, value: -7 * week, to: tomorrow),
                  let lower = cal.date(byAdding: .day, value: -7 * (week + 1), to: tomorrow) else {
                throw GmailError.dateMath
            }
            let weekLabel = "week of \(label(lower))"
            let query = "after:\(qDate(lower)) before:\(qDate(upper))"
            let itemDate = cal.date(byAdding: .day, value: -1, to: upper) ?? lower
            windows.append(Window(label: weekLabel,
                                  prompt: weeklyPrompt(query: query, label: weekLabel),
                                  itemDate: itemDate))
        }

        // Announce every window starting — they all kick off now (parallel fan-out).
        for w in windows { onProgress(.windowStart(total: initialWeeks, label: w.label, prompt: w.prompt)) }

        // Fan out: one codex exec per window, all concurrent. Collect AS each finishes, then record +
        // report serially here in the parent — so the counters and the progress box see no races.
        var recorded = 0, completed = 0
        var pending: [NoteDraft] = []
        try await withThrowingTaskGroup(of: WindowResult.self) { group in
            for w in windows {
                group.addTask { WindowResult(window: w, result: try await read(prompt: w.prompt)) }
            }
            for try await done in group {
                completed += 1
                if let r = done.result {
                    pending.append(draft(r, itemDate: done.window.itemDate, label: done.window.label))
                    recorded += 1
                    onProgress(.windowDone(total: initialWeeks, label: done.window.label,
                                           summary: r.summary, threads: r.threadCount,
                                           completed: completed, keptSoFar: recorded))
                } else {
                    onProgress(.windowDone(total: initialWeeks, label: done.window.label,
                                           summary: nil, threads: 0,
                                           completed: completed, keptSoFar: recorded))
                }
            }
        }

        // High-water mark = run start. Iterative reads everything after it (a few hours of overlap
        // is harmless — the cloud updater synthesizes — and beats a boundary gap).
        try await GoogleSourceRead.commit(bucket: bucketKey, notes: pending, through: runStart, replace: replaceNotes)
        Log("GmailConnect.runInitial: ✅ \(recorded)/\(initialWeeks) weekly summaries recorded (parallel); pointer → \(runStart)")
        return recorded
    }

    // MARK: - Iterative read (since the high-water mark)

    /// One summary covering everything since the saved mark, then advance the mark. Falls back to a
    /// full initial read if Gmail has never been read on this Mac.
    @discardableResult
    static func runIterative(onProgress: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> Int {
        try await ModelBackend.$runOverride.withValue(ModelBackend.current) {
            try await readIterative(onProgress: onProgress)
        }
    }

    private static func readIterative(onProgress: @Sendable @escaping (Progress) -> Void) async throws -> Int {
        guard let checkpoint = try await CycleStore.shared.mcpCheckpoint(bucketKey),
              checkpoint.origin == GoogleSourceRead.origin(bucket: bucketKey) else {
            return try await readInitial(onProgress: onProgress, replaceNotes: false)
        }
        let mark = checkpoint.mark
        let since = Date(timeIntervalSince1970: mark.order)
        let runStart = Date()
        guard mark.order <= runStart.timeIntervalSince1970 else { throw MCPSource.MCPError.clockMovedBackwards }
        let sinceLabel = "since \(label(since))"
        // Gmail's `after:` accepts an epoch-seconds boundary — precise, no day-rounding.
        let query = "after:\(Int(since.timeIntervalSince1970))"
        let prompt = weeklyPrompt(query: query, label: sinceLabel)
        onProgress(.windowStart(total: 1, label: sinceLabel, prompt: prompt))
        var recorded = 0
        var pending: [NoteDraft] = []
        if let r = try await read(prompt: prompt) {
            pending.append(draft(r, itemDate: runStart, label: sinceLabel))
            recorded = 1
            onProgress(.windowDone(total: 1, label: sinceLabel,
                                   summary: r.summary, threads: r.threadCount, completed: 1, keptSoFar: 1))
        } else {
            onProgress(.windowDone(total: 1, label: sinceLabel,
                                   summary: nil, threads: 0, completed: 1, keptSoFar: 0))
        }
        try await GoogleSourceRead.commit(bucket: bucketKey, notes: pending, through: runStart)
        Log("GmailConnect.runIterative: ✅ \(recorded) summary since \(since); pointer → \(runStart)")
        return recorded
    }

    // MARK: - One read (a single codex exec over a date window)

    private static func read(prompt: String) async throws -> ReadResult? {
        var inv = CodexCLI.Invocation(prompt: prompt)
        inv.feature = "gmail"
        inv.model = .gpt56luna               // light model for the high-volume Gmail reads
        inv.effort = .medium                 // gpt-5.6-luna → medium
        inv.sandbox = .readOnly              // we only read Gmail + return text (no file writes)
        inv.outputSchema = weeklySchema
        inv.timeout = 900                    // a heavy window with a few deep reads can run long
        inv.mcpReadConnectors = ["gmail"]    // Claude engine: the unattended-read recipe
        guard let result = try await GoogleSourceRead.read(inv, slug: "gmail", countKey: "thread_count", cap: threadCap) else { return nil }
        return ReadResult(summary: result.text, hasActionItems: result.hasActionItems, threadCount: result.count)
    }

    private static func draft(_ r: ReadResult, itemDate: Date, label: String) -> NoteDraft {
        NoteDraft(kind: .gmail, sourceID: "gmail:\(Int(itemDate.timeIntervalSince1970))", folder: "Gmail",
            itemDate: itemDate, text: r.summary, title: "Email · \(label)", reminderFlagged: r.hasActionItems)
    }

    // MARK: - Date helpers

    private static func qDate(_ d: Date) -> String {     // Gmail query date: yyyy/MM/dd
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"; f.timeZone = .current
        return f.string(from: d)
    }
    private static func label(_ d: Date) -> String {     // display: "Jun 8"
        let f = DateFormatter(); f.dateFormat = "MMM d"; f.timeZone = .current
        return f.string(from: d)
    }

    // MARK: - Prompts

    /// The structured reply contract — one dense weekly summary plus the flags Sentient keys on.
    private static let weeklySchema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "thread_count":{"type":"integer"},\
    "notable":{"type":"boolean"},\
    "has_action_items":{"type":"boolean"},\
    "summary":{"type":"string"}},\
    "required":["thread_count","notable","has_action_items","summary"]}
    """

    private static func weeklyPrompt(query: String, label: String) -> String {
        """
        You are the Gmail intelligence pass for Sentient OS, a privacy-first personal-AI app. \
        Summarize ONE window of the user's email (\(label)) into a single dense summary that feeds \
        two things: the user's personal knowledge base, and a PROACTIVE engine that surfaces things \
        needing the user's attention. Finding what genuinely matters is the whole job.

        ## Fetch — be efficient, the inbox is heavy
        - Use `gmail.search_emails` with EXACTLY this query: `\(query)`
        - Consider at most the newest \(threadCap) threads in that window; if there are more, take the \
        newest \(threadCap).
        - Work from subjects, senders, and snippets. Open a thread with `gmail.read_email` ONLY when it \
        looks genuinely important — a real request directed at the user, a deadline, a booking/renewal \
        window, or a personal/financial/work matter. DO NOT open newsletters, marketing, receipts, or \
        automated notifications, and DO NOT read every email. Over-reading wastes the budget.

        ## Produce ONE summary (third person — "the user")
        - Lead with a short overview of what actually mattered this window.
        - Then a clear section **Action items / awaiting the user / deadlines / commitments**: each as \
        `who · what · by when`. Only real, still-actionable ones; skip anything stale or trivial.
        - Then: key people and threads, and anything else genuinely important about the user's life, \
        work, money, plans, or relationships.

        ## Rules
        - Curate RUTHLESSLY. Skip spam, newsletters, marketing, promotions, and automated noise unless \
        truly important. A quiet window with nothing worth keeping → `notable: false`, `summary: ""`.
        - PII-light: NEVER include full card/account numbers, passwords, verification/2FA codes, or \
        verbatim sensitive medical or financial figures. Summarize, never transcribe such details.
        - Truth & attribution: an email FROM someone else is THEIR words, not the user's. Never assert \
        something about the user the email doesn't support.

        ## Output
        Return ONLY the JSON object matching the schema: `thread_count` (threads you considered, after \
        the cap), `notable` (anything worth a knowledge-base note?), `has_action_items` (anything the \
        proactive engine should weigh?), and `summary` (the dense text; empty string when not notable).
        """
    }
}
