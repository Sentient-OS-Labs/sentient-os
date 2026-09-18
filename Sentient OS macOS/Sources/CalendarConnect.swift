//
//  CalendarConnect.swift
//  Sentient OS macOS
//
//  Google Calendar — a CLOUD source, twin to Gmail (GmailConnect). The calendar can't be read
//  on-device, so we both FETCH and SUMMARIZE through the user's own Codex Google Calendar connector
//  (account-level `codex_apps/google_calendar.*` — get_profile / search_events / read_event, visible
//  to `codex exec` whether or not `--ignore-user-config` is passed; verified live June 21).
//
//  Connection: the user links Google on OpenAI's connector page (opened from CloudConnectSheet); we
//  confirm with `probeConnected()` through the shared ConnectorCensus (no AI read probe).
//
//  Reads (each summary is ONE ephemeral CycleNote in bucket "calendar"; the existing "tell cloud"
//  buttons fold them into the vault, same as every other source):
//   • runInitial   — the last YEAR as 12 MONTHLY `codex exec` calls, newest month first. One dense
//                    summary per month, keeping ONLY the genuinely important events (drops standups,
//                    lunches, focus-time blocks, and other routine noise).
//   • runIterative — everything since the saved high-water mark, in one call, then advance the mark.
//
//  Proactive (the one thing Gmail doesn't have): `fetchProactiveContext()` — a SEPARATE read that
//  dumps the user's LAST 7 DAYS + NEXT 24 HOURS of events (ALL of them, uncurated) as a compact text
//  block. That block is injected into BOTH proactive stages (Proactive.findActionItems and
//  ProactiveResearch.researchAndPrepare) so the engine knows what's actually on the user's calendar.
//
//  Writes (add an event) are NOT here — that's ProactiveExecutor.fireCalendar, which runs
//  sandboxed with the write tools pre-approved per run (`approveConnectorWrites`; the calendar
//  write tools are approval-gated and auto-cancel headless otherwise, exactly like Gmail's
//  send_email — verified live June 21). All reads here are read-only and need no special config.
//
//  Doc: Sources/Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation

enum CalendarConnect {

    /// The single iterative-store bucket for Calendar. Its pointer is the high-water mark (run start).
    static let bucketKey = "calendar"

    /// OpenAI's hosted Google Calendar connector page — opened from CloudConnectSheet's "Connect Calendar".
    /// Where the user links Google — engine-aware (decided 2026-08-23): OpenAI's hosted
    /// connector page on the ChatGPT backend, the claude.ai connector directory on the Claude
    /// backend. Custom backends never reach here (connectorsAvailable gates the chips).
    static var connectorURL: URL {
        ModelBackend.current == .claude
            ? URL(string: "https://claude.ai/new#settings/customize-connectors/directory/google-calendar-calendarmcp")!
            : URL(string: "https://chatgpt.com/plugins/plugin_connector_1p_f8509de903288191b14a160c6c5d20b0?q=calendar")!
    }

    /// Newest-N events per read window (a busy month rarely exceeds this; a guard against a runaway list).
    private static let eventCap = 200
    private static let initialMonths = 12

    enum CalendarError: LocalizedError {
        case dateMath
        var errorDescription: String? { "Calendar date math failed." }
    }

    /// Parsed monthly/iterative read result (from the structured codex reply).
    private struct ReadResult {
        let summary: String
        let hasActionItems: Bool
        let eventCount: Int
    }

    /// Structured progress for the dev processing UI — each date window (a month, or the iterative
    /// since-mark window) STARTING then FINISHING. `prompt` is the exact Codex ask (shown in the
    /// processing view's PROMPT pane); `summary` is nil when the window had nothing notable.
    enum Progress: Sendable {
        case windowStart(step: Int, total: Int, label: String, prompt: String)
        case windowDone(step: Int, total: Int, label: String, summary: String?, events: Int, keptSoFar: Int)
    }

    // MARK: - Connection detection

    /// Refresh the same hosted-connector census used by every other connected app.
    static func probeConnected() async -> Bool {
        await ConnectorCensus.checkConnection(slug: "google-calendar")
    }

    // MARK: - Initial read (last year → 12 monthly summaries)

    /// Read twelve monthly windows sequentially. Replace notes and checkpoint together only
    /// after every result is validated; failures preserve the previous bucket.
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
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: today) else { throw CalendarError.dateMath }

        var recorded = 0
        var pending: [NoteDraft] = []
        for month in 0..<initialMonths {
            // Window [tomorrow − 1·(month+1), tomorrow − 1·month) months: contiguous, no overlap, newest
            // first, past-only (the most recent window ends at end-of-today; future events ride the
            // proactive fetch, not the knowledge-base read).
            guard let upper = cal.date(byAdding: .month, value: -month, to: tomorrow),
                  let lower = cal.date(byAdding: .month, value: -(month + 1), to: tomorrow),
                  let upperDay = cal.date(byAdding: .day, value: -1, to: upper) else {
                throw CalendarError.dateMath
            }
            let monthLabel = "\(label(lower)) – \(label(upperDay))"
            let range = "with a start date/time on or after \(iso(lower)) and before \(iso(upper))"
            let prompt = readPrompt(range: range, label: monthLabel)
            onProgress(.windowStart(step: month + 1, total: initialMonths, label: monthLabel, prompt: prompt))
            if let r = try await read(prompt: prompt, window: DateInterval(start: lower, end: upper)) {
                let itemDate = upperDay
                pending.append(draft(r, itemDate: itemDate, label: monthLabel))
                recorded += 1
                onProgress(.windowDone(step: month + 1, total: initialMonths, label: monthLabel,
                                       summary: r.summary, events: r.eventCount, keptSoFar: recorded))
            } else {
                onProgress(.windowDone(step: month + 1, total: initialMonths, label: monthLabel,
                                       summary: nil, events: 0, keptSoFar: recorded))
            }
        }
        // High-water mark = run start. Iterative reads everything after it (a little overlap is
        // harmless — the cloud updater synthesizes — and beats a boundary gap).
        try await GoogleSourceRead.commit(bucket: bucketKey, notes: pending, through: runStart, replace: replaceNotes)
        Log("CalendarConnect.runInitial: ✅ \(recorded)/\(initialMonths) monthly summaries recorded; pointer → \(runStart)")
        return recorded
    }

    // MARK: - Iterative read (since the high-water mark)

    /// One summary covering events since the saved mark, then advance the mark. Falls back to a full
    /// initial read if Calendar has never been read on this Mac.
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
        let range = "with a start date/time on or after \(iso(since)) and before \(iso(runStart))"
        let prompt = readPrompt(range: range, label: sinceLabel)
        onProgress(.windowStart(step: 1, total: 1, label: sinceLabel, prompt: prompt))
        var recorded = 0
        var pending: [NoteDraft] = []
        if let r = try await read(prompt: prompt, window: DateInterval(start: since, end: runStart)) {
            pending.append(draft(r, itemDate: runStart, label: sinceLabel))
            recorded = 1
            onProgress(.windowDone(step: 1, total: 1, label: sinceLabel,
                                   summary: r.summary, events: r.eventCount, keptSoFar: 1))
        } else {
            onProgress(.windowDone(step: 1, total: 1, label: sinceLabel,
                                   summary: nil, events: 0, keptSoFar: 0))
        }
        try await GoogleSourceRead.commit(bucket: bucketKey, notes: pending, through: runStart)
        Log("CalendarConnect.runIterative: ✅ \(recorded) summary since \(since); pointer → \(runStart)")
        return recorded
    }

    // MARK: - Proactive context (last 7 days + next 24 hours — ALL events, uncurated)

    /// A compact, chronological text dump of the user's recent + imminent calendar, injected into BOTH
    /// proactive stages. Unlike the read above this does NOT curate — proactive wants every event
    /// (a "free" slot is as informative as a meeting). Returns nil when the connector is unavailable or
    /// the read fails (proactive then runs without calendar context). Read-only; no bypass needed.
    static func fetchProactiveContext() async -> String? {
        var inv = CodexCLI.Invocation(prompt: proactiveFetchPrompt)
        inv.feature = "calendar-proactive"
        inv.model = .gpt56luna
        inv.effort = .medium
        inv.sandbox = .readOnly
        inv.webSearch = false
        inv.outputSchema = proactiveSchema
        inv.timeout = 300
        inv.mcpReadConnectors = ["google-calendar"]   // Claude engine: the unattended-read recipe
        do {
            let env = try await FrontierRun.run(inv)
            guard let span = jsonSpan(env.result),
                  let data = span.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (obj["connected"] as? Bool) == true,
                  let text = (obj["events_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                Log("CalendarConnect.fetchProactiveContext: no calendar context (not connected / empty)")
                return nil
            }
            Log("CalendarConnect.fetchProactiveContext: ✅ \(text.count) chars of live calendar context")
            return text
        } catch {
            Log("CalendarConnect.fetchProactiveContext: ⚠️ \(ErrorLabel(error)) — proactive runs without calendar")
            return nil
        }
    }

    // MARK: - One read (a single codex exec over a date window)

    private static func read(prompt: String, window: DateInterval) async throws -> ReadResult? {
        var inv = CodexCLI.Invocation(prompt: prompt)
        inv.feature = "calendar"
        inv.model = .gpt56luna               // light model — calendar data is small + structured
        inv.effort = .medium                 // gpt-5.6-luna → medium
        inv.sandbox = .readOnly              // we only read the calendar + return text (no writes)
        inv.webSearch = false                // the calendar is the only source this needs
        inv.outputSchema = readSchema
        inv.timeout = 600
        inv.mcpReadConnectors = ["google-calendar"]   // Claude engine: the unattended-read recipe
        guard let result = try await GoogleSourceRead.read(inv, slug: "google-calendar", countKey: "event_count", cap: eventCap,
                                                         calendarWindow: window) else { return nil }
        return ReadResult(summary: result.text, hasActionItems: result.hasActionItems, eventCount: result.count)
    }

    private static func draft(_ r: ReadResult, itemDate: Date, label: String) -> NoteDraft {
        NoteDraft(kind: .calendar, sourceID: "calendar:\(Int(itemDate.timeIntervalSince1970))", folder: "Calendar",
            itemDate: itemDate, text: r.summary, title: "Calendar · \(label)", reminderFlagged: r.hasActionItems)
    }

    /// Tolerant parse of the structured read reply (output-schema makes `result` the JSON; fence-safe).
    /// Widest `{ … }` span in a possibly-fenced reply.
    private static func jsonSpan(_ result: String) -> String? {
        if let s = result.firstIndex(of: "{"), let e = result.lastIndex(of: "}"), s < e {
            return String(result[s...e])
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Date helpers

    /// ISO-8601 with timezone offset — a precise window boundary the connector can bound on.
    private static func iso(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"; f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
    private static func label(_ d: Date) -> String {     // display: "Jun 8"
        let f = DateFormatter(); f.dateFormat = "MMM d"; f.timeZone = .current
        return f.string(from: d)
    }

    // MARK: - Prompts

    /// The structured read reply — one dense window summary plus the flags Sentient keys on.
    private static let readSchema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "event_count":{"type":"integer"},\
    "notable":{"type":"boolean"},\
    "has_action_items":{"type":"boolean"},\
    "summary":{"type":"string"}},\
    "required":["event_count","notable","has_action_items","summary"]}
    """

    private static func readPrompt(range: String, label: String) -> String {
        """
        You are the Google Calendar intelligence pass for Sentient OS, a privacy-first personal-AI app. \
        Summarize ONE window of the user's calendar (\(label)) into a single dense summary that feeds \
        two things: the user's personal knowledge base, and a PROACTIVE engine that surfaces things \
        needing the user's attention. Finding what genuinely matters is the whole job.

        ## Fetch
        - Use ONLY your Google Calendar connector tools (do NOT web search). Search the user's primary \
        calendar for events \(range).
        - Consider at most the \(eventCap) most relevant events in that window. Open an event's details \
        only when it looks genuinely important.

        ## Keep ONLY what matters — curate RUTHLESSLY
        A calendar is mostly routine. KEEP the events that say something real about the user's life, \
        work, relationships, or plans — meaningful meetings, interviews, trips, appointments, \
        deadlines, events with specific people, anything with stakes. DROP the noise: recurring \
        standups, "Lunch", "Focus time"/"Do not schedule" blocks, generic holds, declined events, and \
        anything trivial or automated. A quiet window with nothing worth keeping → `notable: false`, \
        `summary: ""`.

        ## Produce ONE summary (third person — "the user")
        - Lead with a short overview of what actually mattered this window.
        - Note the key meetings/events and the people involved, and any commitments, deadlines, or \
        follow-ups they imply (each as `who · what · when`).
        - Anything else genuinely important about the user's life, work, plans, or relationships.

        ## Rules
        - Truth & attribution: a calendar event is the user's SCHEDULE, not a claim about who they are. \
        An event with other people is something they're attending — don't infer someone else's job, \
        biography, or project onto the user.
        - PII-light: summarize, never transcribe sensitive details (e.g. medical specifics, full \
        meeting-link tokens, dial-in PINs).

        ## Output
        Return ONLY the JSON object matching the schema: `event_count` (events you considered), \
        `notable` (anything worth a knowledge-base note?), `has_action_items` (anything the proactive \
        engine should weigh — an upcoming commitment, a deadline, a follow-up?), and `summary` (the \
        dense text; empty string when not notable).
        """
    }

    /// The proactive-fetch reply — a compact text dump of recent + imminent events (uncurated).
    private static let proactiveSchema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "connected":{"type":"boolean"},\
    "events_text":{"type":"string"}},\
    "required":["connected","events_text"]}
    """

    private static let proactiveFetchPrompt = """
    You are the calendar-fetch step for Sentient OS's Proactive Intelligence engine. Using ONLY your \
    Google Calendar connector tools (do NOT web search), list the user's events in TWO windows on their \
    primary calendar. List ALL of them — do NOT filter by importance; the proactive engine wants the \
    full picture (an empty slot is as useful as a meeting).

    Windows (use the account's local timezone):
    - LAST 7 DAYS: events whose start is within the last 7 days (up to now).
    - NEXT 24 HOURS: events whose start is within the next 24 hours (from now).

    For each event, one compact line: `date + start–end time · title · location (if any) · N other \
    attendees (if any) · status (if not "confirmed")`. List each window chronologically under a clear \
    heading. If a window has no events, write "(none)". Keep it tight — no commentary, just the lists.

    Return ONLY the JSON object matching the schema: `connected` (true if you could read the calendar; \
    false if the connector wasn't available) and `events_text` (the two labeled lists). If the \
    connector isn't available, set `connected: false` and `events_text: ""`.
    """
}
