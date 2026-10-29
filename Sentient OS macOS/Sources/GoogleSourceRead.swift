// GoogleSourceRead.swift
// Parses the dedicated Google readers' summaries and commits complete windows atomically.
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

    static func parse(_ text: String, countKey: String) throws -> Summary? {
        enum ToolFailure: String, Decodable { case success = "", auth, other }
        struct Payload: Decodable {
            let notable: Bool
            let summary: String
            let has_action_items: Bool
            let thread_count: Int?
            let event_count: Int?
            let tool_failure: ToolFailure?
        }
        let span: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            span = String(text[start...end])
        } else { span = text }
        guard let data = span.data(using: .utf8), let value = try? JSONDecoder().decode(Payload.self, from: data),
              let count = countKey == "thread_count" ? value.thread_count : value.event_count,
              count >= 0 else { throw Failure.invalidResponse }
        let summary = value.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.notable else {
            guard summary.isEmpty, !value.has_action_items else { throw Failure.invalidResponse }
            return nil
        }
        guard count > 0, !summary.isEmpty else { throw Failure.invalidResponse }
        if PIIScan.containsHighRiskPII(summary) { return nil }
        return Summary(text: summary, hasActionItems: value.has_action_items, count: count)
    }

    static func read(_ invocation: CodexCLI.Invocation, slug: String, countKey: String) async throws -> Summary? {
        var request = invocation
        request.connectorOnlyRead = true
        request.webSearch = false
        request.prompt += "\nRead the requested source and date window. If the connector is still connecting, use WaitForMcpServers when available. If it is missing, disconnected, or requires sign-in, return tool_failure=auth, no summary, zero items, and false for both flags. Use tool_failure=other for an unresolved source read failure. Include every schema field, with an empty tool_failure on success."
        if slug == "gmail" {
            request.prompt += "\nIf a Gmail read fails transiently, retry it once within the original date query and thread cap. You may use smaller batches or individual reads. Stop for missing sign-in or account usage limits, and do not invent unread content."
        }
        for attempt in 1...2 {
            try Task.checkCancellation()
            var result: CodexCLI.Envelope?
            do {
                // A recoverable runtime attempt stays observable without marking the
                // parent analysis failed. The caller reports any exhausted final error.
                let response = try await Diagnostics.withOperation("google_read_attempt", propagatesFailure: false) {
                    try await FrontierRun.run(request)
                }
                try Task.checkCancellation()
                result = response
                try ConnectorReadFailure.validate(response, slug: slug)
                return try parse(response.result, countKey: countKey)
            } catch {
                try Task.checkCancellation()
                let gmailRetry = slug == "gmail" ? ConnectorReadFailure.gmailRetry(error) : nil
                guard (error as? Failure) == .invalidResponse || ConnectorReadFailure.isOutputValidationFailure(error)
                        || gmailRetry != nil else { throw error }
                if attempt == 2 {
                    // A real source failure keeps its type. Do not misreport it as malformed JSON.
                    if gmailRetry != nil { throw error }
                    Diagnostics.report(.modelOutputInvalid, phase: .parse, reason: "google_response", source: slug,
                                       counts: [.bytes: result?.result.utf8.count ?? 0, .retries: attempt - 1], flags: [.previousStateRetained: true])
                    throw Failure.invalidResponse
                }
                if let gmailRetry {
                    if case .timeout = gmailRetry {
                        Log("Gmail source read: retrying the same window once after a runtime timeout")
                        request.prompt += "\nThe previous window attempt timed out before it completed. Make one fresh attempt for the SAME original date query and thread cap. Actually discover and read that window; do not broaden dates or reuse an incomplete result. Return a summary only after the required reads succeed."
                        continue
                    }
                    Log("Gmail source read: retrying the same window once after a source failure")
                    if case .rateLimited = gmailRetry { try await Task.sleep(for: .seconds(1)) }
                    request.prompt += "\nThe previous window attempt contained an unresolved Gmail read. Make one fresh attempt for the SAME original date query and thread cap. Actually discover and read that window; do not broaden dates or treat the previous failed result as source data. Return a summary only after the required reads succeed."
                    continue
                }
                Log("Google source read: incomplete result; retrying once")
                request.prompt += "\nThe previous response could not be decoded as the requested summary. Return all required fields with their exact types at the structured-output tool's root. Keep the original source, date window, and item cap. Report any unresolved source failure with tool_failure; do not invent missing content."
            }
        }
        throw Failure.invalidResponse
    }

    /// Keep the connection generation captured before reading. Opening provider settings may
    /// invalidate it during a read or while the store actor is busy; neither may consume the
    /// new generation's backfill by stamping an older read with the latest origin.
    static func commit(bucket: String, notes: [NoteDraft], through date: Date,
                       origin expectedOrigin: String, replace: Bool = false) async throws {
        try Task.checkCancellation()
        guard origin(bucket: bucket) == expectedOrigin else { throw MCPSource.MCPError.connectionChanged }
        let result = await CycleStore.shared.commitMCPRead(bucketKey: bucket, notes: notes,
            through: ItemKey(order: date.timeIntervalSince1970, tiebreak: ""),
            origin: expectedOrigin, replaceNotes: replace)
        if result == .diskFull { throw CocoaError(.fileWriteOutOfSpace) }
        guard result == .saved else { throw Failure.storage }
    }

    static func origin(bucket: String) -> String {
        ConnectorRegistry.readOrigin(slug: bucket == "calendar" ? "google-calendar" : "gmail", backend: ModelBackend.current)
    }
}
