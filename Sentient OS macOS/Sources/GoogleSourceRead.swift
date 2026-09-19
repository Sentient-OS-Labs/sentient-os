// GoogleSourceRead.swift
// Validates the dedicated Google readers' summaries and commits complete windows atomically.
// Malformed output and failed storage preserve the previous notes and checkpoint.
// Doc: Documentation - Sources - Cloud (Gmail, Calendar).md
import Foundation

enum GoogleSourceRead {
    struct Summary: Sendable {
        let text: String
        let hasActionItems: Bool
        let count: Int
    }

    enum Failure: LocalizedError {
        case invalidResponse
        case storage
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The connected source returned an incomplete result. Your previous progress is saved; try analysis again."
            case .storage: return "The source summaries could not be saved. Your previous progress is preserved."
            }
        }
    }

    static func parse(_ text: String, countKey: String, cap: Int) throws -> Summary? {
        struct Payload: Decodable {
            let notable: Bool
            let summary: String
            let has_action_items: Bool
            let thread_count: Int?
            let event_count: Int?
        }
        let span: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            span = String(text[start...end])
        } else { span = text }
        guard let data = span.data(using: .utf8), let value = try? JSONDecoder().decode(Payload.self, from: data),
              let count = countKey == "thread_count" ? value.thread_count : value.event_count,
              (0...cap).contains(count) else { throw Failure.invalidResponse }
        let summary = value.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.notable else {
            guard summary.isEmpty, !value.has_action_items else { throw Failure.invalidResponse }
            return nil
        }
        guard count > 0, !summary.isEmpty else { throw Failure.invalidResponse }
        if PIIScan.containsHighRiskPII(summary) { return nil }
        return Summary(text: summary, hasActionItems: value.has_action_items, count: count)
    }

    static func validateDiscovery(_ envelope: CodexCLI.Envelope, slug: String, calendarWindow: DateInterval? = nil) throws {
        let names: Set<String>
        if ModelBackend.current == .claude {
            names = slug == "gmail" ? ["mcp__claude_ai_Gmail__search_threads"]
                : ["mcp__claude_ai_Google_Calendar__list_events", "mcp__claude_ai_Google_Calendar__search_events"]
        } else {
            names = slug == "gmail" ? ["gmail.search_emails", "gmail.search_email_ids"]
                : ["gcal.search_events", "gcal.search", "google_calendar.search_events", "google_calendar.search"]
        }
        let calls = MCPCallEvidence.receipts(raw: envelope.raw, backend: ModelBackend.current)
            .filter { $0.status == .succeeded && names.contains($0.tool) && !oversizedNotice($0.output) }
        guard !calls.isEmpty else { throw Failure.invalidResponse }
        if let window = calendarWindow {
            let parser = ISO8601DateFormatter()
            var visibleFullWindow = false
            for (index, call) in calls.enumerated() {
                guard let data = call.arguments,
                      let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
                let claude = ModelBackend.current == .claude
                guard !claude || call.tool == "mcp__claude_ai_Google_Calendar__list_events",
                      let lowerText = args[claude ? "startTime" : "time_min"] as? String,
                      let upperText = args[claude ? "endTime" : "time_max"] as? String,
                      let lower = parser.date(from: lowerText), let upper = parser.date(from: upperText),
                      lower <= upper, lower.timeIntervalSince(window.start) > -1,
                      upper.timeIntervalSince(window.end) < 1 else { throw Failure.invalidResponse }
                let fullWindow = abs(lower.timeIntervalSince(window.start)) < 1
                    && abs(upper.timeIntervalSince(window.end)) < 1
                if index == 0, !fullWindow { throw Failure.invalidResponse }
                if fullWindow, visibleCalendarPayload(call.output) { visibleFullWindow = true }
                for key in ["calendar_id", "calendarId"] {
                    if let value = args[key], !(value is NSNull) {
                        guard value as? String == "primary" else { throw Failure.invalidResponse }
                    }
                }
                if let query = args["query"], !(query is NSNull) {
                    guard let text = query as? String, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw Failure.invalidResponse
                    }
                }
            }
            // A CLI's oversized-result notice can have a successful call status while the
            // model receives only a file path. It does not establish a visible calendar read.
            guard visibleFullWindow else { throw Failure.invalidResponse }
        }
    }

    private static func oversizedNotice(_ data: Data?) -> Bool {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let texts = (root["content"] as? String).map { [$0] }
            ?? (root["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        return texts.contains {
            $0.hasPrefix("Error: result") && $0.contains("exceeds maximum allowed tokens")
                && $0.contains("Output has been saved")
        }
    }

    private static func visibleCalendarPayload(_ data: Data?) -> Bool {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        var objects = [root]
        for key in ["structured_content", "structuredContent"] {
            if let object = root[key] as? [String: Any] { objects.append(object) }
        }
        let texts = (root["content"] as? String).map { [$0] }
            ?? (root["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        for text in texts {
            if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { objects.append(object) }
        }
        return objects.contains { object in
            if object["events"] is [Any] { return true }
            // Claude's native Calendar list omits `events` for an empty result. Require
            // its observed calendar metadata, and no unfinished page or error, before
            // accepting that omission as empty rather than malformed output.
            guard ModelBackend.current == .claude, object["events"] == nil, object["error"] == nil,
                  Set(object.keys).isSubset(of: ["accessRole", "defaultReminders", "summary", "description",
                                                "timeZone", "updated", "nextPageToken", "nextSyncToken", "etag", "kind"]),
                  let role = object["accessRole"] as? String, ["owner", "writer", "reader"].contains(role),
                  (object["defaultReminders"] == nil || object["defaultReminders"] is [Any]), object["summary"] is String,
                  let zone = object["timeZone"] as? String, TimeZone(identifier: zone) != nil,
                  let updated = object["updated"] as? String, !updated.isEmpty else { return false }
            return object["nextPageToken"] == nil || object["nextPageToken"] is NSNull
                || object["nextPageToken"] as? String == ""
        }
    }

    static func read(_ invocation: CodexCLI.Invocation, slug: String, countKey: String, cap: Int,
                     calendarWindow: DateInterval? = nil) async throws -> Summary? {
        var request = invocation
        request.connectorOnlyRead = true
        request.webSearch = false
        let discovery = slug == "gmail" ? "search_threads on Claude, or search_emails on Codex"
            : "list_events/search_events on Claude, or search_events on Codex"
        request.prompt += "\nA real discovery call is required, even for an empty window: use \(discovery). If the connector is still connecting, use WaitForMcpServers when available. Do not report a quiet result without actually checking the requested window."
        if let window = calendarWindow {
            let formatter = ISO8601DateFormatter()
            request.prompt += "\nCalendar discovery must use exactly these instants: \(formatter.string(from: window.start)) through \(formatter.string(from: window.end)). On Claude use list_events with startTime/endTime and pageSize at most 50; on Codex use search_events with time_min/time_max. Use the primary calendar and no keyword query. The first successful discovery must cover this whole window and return a native structured calendar response. Claude may omit events entirely for a genuine empty response that contains accessRole, defaultReminders, summary, timeZone and updated with no nextPageToken; accept that as empty and stop. A saved-to-file or oversized-result notice is not a readable result: retry the same full bounds with a smaller page size. Prefer the same bounds for supported pagination; any narrower follow-up must remain entirely inside this original interval. An empty successful result is valid: do not broaden the window, search other times, or use search_events on Claude to second-guess it."
        }
        request.prompt += "\nIf the connector is missing, disconnected, or requires sign-in, return tool_failure=auth, no summary, zero items, and false for both flags. Use tool_failure=other for other tool errors, and an empty tool_failure on success."
        for attempt in 1...2 {
            try Task.checkCancellation()
            let result = try await FrontierRun.run(request)
            do {
                try ConnectorReadFailure.validate(result, slug: slug)
                if let data = result.jsonResult.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["tool_failure"] as? String == "other" {
                    throw MCPSource.MCPError.toolFailure(slug: slug)
                }
                let summary = try parse(result.result, countKey: countKey, cap: cap)
                try validateDiscovery(result, slug: slug, calendarWindow: calendarWindow)
                return summary
            } catch Failure.invalidResponse {
                if attempt == 2 { throw Failure.invalidResponse }
                Log("Google source read: incomplete result; retrying once")
                request.prompt += "\nThe previous attempt had invalid output or no successful discovery receipt. Wait for the connector if necessary, then perform the actual bounded search. Return all required fields with their exact types. Never invent an empty result when tools are unavailable."
            }
        }
        throw Failure.invalidResponse
    }

    static func commit(bucket: String, notes: [NoteDraft], through date: Date, replace: Bool = false) async throws {
        try Task.checkCancellation()
        let result = await CycleStore.shared.commitMCPRead(bucketKey: bucket, notes: notes,
            through: ItemKey(order: date.timeIntervalSince1970, tiebreak: ""),
            origin: origin(bucket: bucket), replaceNotes: replace)
        if result == .diskFull { throw CocoaError(.fileWriteOutOfSpace) }
        guard result == .saved else { throw Failure.storage }
    }

    static func origin(bucket: String) -> String {
        ConnectorRegistry.readOrigin(slug: bucket == "calendar" ? "google-calendar" : "gmail", backend: ModelBackend.current)
    }
}
