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
//  trust their confirmation. Connection problems are handled by the actual processing read.
//
//  During first analysis, interrupted imports replay all windows within their original bounds.
//  Reads save each validated window with durable coverage in CycleStore. Initial imports cover
//  four weeks with at most two concurrent reads; retries resume only unfinished windows. Everyday
//  reads use a fixed range since the last fully covered watermark. Saved notes can reach the
//  knowledge base while another week remains retryable.
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
        ConnectorLinks.page(for: "gmail")
    }

    /// Newest-N threads per read (the connector-limits doc's cap; a heavy week exceeds it).
    nonisolated private static let threadCap = 300

    enum GmailError: LocalizedError {
        case incomplete(failed: Int, saved: Int)
        var errorDescription: String? {
            switch self {
            case .incomplete(_, let saved):
                if saved > 0 {
                    return "Gmail saved \(saved) email summar\(saved == 1 ? "y" : "ies"). Retry analysis to finish the remaining reads."
                }
                return "Gmail could not finish reading your email. Retry analysis to continue."
            }
        }
    }

    /// Parsed weekly/iterative read result (from the structured codex reply).
    private struct ReadResult: Sendable {
        let summary: String
        let hasActionItems: Bool
        let threadCount: Int
    }

    /// Each worker reports its own outcome so a failed week does not cancel successful siblings.
    private struct WindowResult: Sendable {
        let index: Int
        let result: Result<ReadResult?, Error>
    }

    /// Counts include only summaries committed during this attempt. A resumed import schedules
    /// only its unfinished windows, even when earlier summaries have already reached the vault.
    enum Progress: Sendable {
        case windowStart(total: Int, label: String, prompt: String)
        case windowDone(total: Int, label: String, summary: String?, threads: Int,
                        completed: Int, keptSoFar: Int)
    }

    @discardableResult
    static func runInitial(onProgress: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> Int {
        try await ModelBackend.$runOverride.withValue(ModelBackend.current) {
            try Task.checkCancellation()
            HostedConnectorSetup.processingStarted(slug: "gmail")
            return try await readInitial(onProgress: onProgress, replaceNotes: true)
        }
    }

    private static func readInitial(onProgress: @Sendable @escaping (Progress) -> Void, replaceNotes: Bool) async throws -> Int {
        let proposed = GmailReadState.initial(origin: GoogleSourceRead.origin(bucket: bucketKey),
                                              through: Date(), replaceNotes: replaceNotes)
        let state = try await CycleStore.shared.beginGmailRead(proposed)
        return try await readWindows(state, onProgress: onProgress)
    }

    @discardableResult
    static func runIterative(onProgress: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> Int {
        try await ModelBackend.$runOverride.withValue(ModelBackend.current) {
            try Task.checkCancellation()
            HostedConnectorSetup.processingStarted(slug: "gmail")
            return try await readIterative(onProgress: onProgress)
        }
    }

    private static func readIterative(onProgress: @Sendable @escaping (Progress) -> Void) async throws -> Int {
        let origin = GoogleSourceRead.origin(bucket: bucketKey)
        if InitialAnalysisRecovery.replayCloudStages {
            let pending = try await CycleStore.shared.gmailReadState()
            let completed = try await CycleStore.shared.mcpCheckpoint(bucketKey)
            // A whole completed stage is retained. An unfinished stage starts all its windows
            // again; beginGmailRead retires its partial notes and preserves the original bounds.
            if pending == nil, let completed, completed.origin == origin, completed.mark.order > 0 {
                guard completed.mark.order <= Date().timeIntervalSince1970 else { throw MCPSource.MCPError.clockMovedBackwards }
                return 0
            }
            return try await readInitial(onProgress: onProgress, replaceNotes: false)
        }
        // Resume coverage before consulting the global watermark, which deliberately does not
        // advance over gaps. The stored bounds never move with the retry's date or time zone.
        if let state = try await CycleStore.shared.gmailReadState(), state.origin == origin {
            return try await readWindows(state, onProgress: onProgress)
        }
        guard let checkpoint = try await CycleStore.shared.mcpCheckpoint(bucketKey),
              checkpoint.origin == origin else {
            return try await readInitial(onProgress: onProgress, replaceNotes: false)
        }
        let now = Date()
        guard checkpoint.mark.order <= now.timeIntervalSince1970 else { throw MCPSource.MCPError.clockMovedBackwards }
        // Gmail accepts whole seconds. Don't create a zero-length read when retried immediately.
        guard floor(now.timeIntervalSince1970) > checkpoint.mark.order else { return 0 }
        let proposed = GmailReadState.incremental(origin: origin,
            since: Date(timeIntervalSince1970: checkpoint.mark.order), through: now)
        let state = try await CycleStore.shared.beginGmailRead(proposed)
        return try await readWindows(state, onProgress: onProgress)
    }

    private static func readWindows(_ state: GmailReadState,
                                    onProgress: @Sendable @escaping (Progress) -> Void) async throws -> Int {
        try Task.checkCancellation()
        guard state.through <= Date() else { throw MCPSource.MCPError.clockMovedBackwards }
        guard GoogleSourceRead.origin(bucket: bucketKey) == state.origin else { throw MCPSource.MCPError.connectionChanged }
        let pending = state.pending
        let total = pending.count
        var saved = 0, completed = 0, failed = 0
        try await withThrowingTaskGroup(of: WindowResult.self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let window = state.windows[index]
                let windowLabel = state.windows.count == 1 ? "since \(label(window.start))" : "week of \(label(window.start))"
                let prompt = weeklyPrompt(query: window.query, label: windowLabel)
                onProgress(.windowStart(total: total, label: windowLabel, prompt: prompt))
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return WindowResult(index: index, result: .success(try await read(prompt: prompt)))
                    } catch { return WindowResult(index: index, result: .failure(error)) }
                }
            }
            // Bound account pressure, including each worker's retry. Successful workers can
            // finish and persist even when another window exhausts its read attempts.
            while next < min(2, total) { enqueue(pending[next]); next += 1 }
            for try await done in group {
                try Task.checkCancellation()
                guard GoogleSourceRead.origin(bucket: bucketKey) == state.origin else { throw MCPSource.MCPError.connectionChanged }
                switch done.result {
                case .success(let result):
                    let window = state.windows[done.index]
                    let windowLabel = state.windows.count == 1 ? "since \(label(window.start))" : "week of \(label(window.start))"
                    let note = result.map { draft($0, itemDate: window.end, label: windowLabel,
                                                  sourceID: state.sourceID(for: done.index)) }
                    // The store checks cancellation again after actor admission. Publish progress
                    // only after the note and completion receipt have both reached disk.
                    if try await CycleStore.shared.commitGmailWindow(stateID: state.id, origin: state.origin,
                                                                     index: done.index, note: note) {
                        completed += 1
                        if result != nil { saved += 1 }
                        onProgress(.windowDone(total: total, label: windowLabel, summary: result?.summary,
                                               threads: result?.threadCount ?? 0, completed: completed, keptSoFar: saved))
                    }
                case .failure(let error):
                    if Diagnostics.isCancellation(error) || ConnectorReadFailure.isConnectionFailure(error)
                        || (error as? ConnectorReadFailure.GmailFailure) == .accountLimit || CodexFailureReason.classify(error) == .usageLimit {
                        throw error
                    }
                    failed += 1
                    Diagnostics.report(.sourceReadFailed, phase: .read, reason: "gmail_window", error: error,
                                       source: "gmail", counts: [.failed: 1])
                }
                if next < total { enqueue(pending[next]); next += 1 }
            }
        }
        if failed > 0 { throw GmailError.incomplete(failed: failed, saved: saved) }
        return saved
    }

    // MARK: - One read (a single codex exec over a date window)

    private static func read(prompt: String) async throws -> ReadResult? {
        var inv = CodexCLI.Invocation(prompt: prompt)
        inv.feature = "gmail"
        inv.model = .gpt6luna               // light model for the high-volume Gmail reads
        inv.effort = .medium                 // gpt-6-luna → medium
        inv.sandbox = .readOnly              // we only read Gmail + return text (no file writes)
        inv.outputSchema = weeklySchema
        inv.timeout = 900                    // a heavy window with a few deep reads can run long
        inv.mcpReadConnectors = ["gmail"]    // Claude engine: the unattended-read recipe
        guard let result = try await GoogleSourceRead.read(inv, slug: "gmail", countKey: "thread_count") else { return nil }
        return ReadResult(summary: result.text, hasActionItems: result.hasActionItems, threadCount: result.count)
    }

    private static func draft(_ r: ReadResult, itemDate: Date, label: String, sourceID: String) -> NoteDraft {
        NoteDraft(kind: .gmail, sourceID: sourceID, folder: "Gmail",
            itemDate: itemDate, text: r.summary, title: "Email · \(label)", reminderFlagged: r.hasActionItems)
    }

    // MARK: - Date helpers

    nonisolated private static func label(_ d: Date) -> String {     // display: "Jun 8"
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
    "summary":{"type":"string"},\
    "tool_failure":{"type":"string","enum":["","auth","other"]}},\
    "required":["thread_count","notable","has_action_items","summary","tool_failure"]}
    """

    nonisolated private static func weeklyPrompt(query: String, label: String) -> String {
        """
        You are the Gmail intelligence pass for Sentient OS, a privacy-first personal-AI app. \
        Summarize ONE window of the user's email (\(label)) into a single dense summary that feeds \
        two things: the user's personal knowledge base, and a PROACTIVE engine that surfaces things \
        needing the user's attention. Finding what genuinely matters is the whole job.

        ## Fetch — be efficient, the inbox is heavy
        - Search with EXACTLY this query: `\(query)`. On Claude use `search_threads`; on Codex use
          `search_emails`. Start with a page size of 25 and use the connector's returned pagination.
        - Consider at most the newest \(threadCap) threads in that window; if there are more, take the \
        newest \(threadCap).
        - Work from subjects, senders, and snippets. Open a thread with `get_thread` on Claude or
          `read_email` on Codex ONLY when it \
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
        proactive engine should weigh?), `summary` (the dense text; empty string when not notable),
        and `tool_failure` ("" on success, "auth" for missing sign-in, "other" for an unresolved
        Gmail tool error). Include all five fields at the root of the structured-output tool.
        A repaired StructuredOutput validation error is not a Gmail tool failure.
        """
    }
}
