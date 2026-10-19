// Legacy last-15 history migration and the intentionally narrow diagnostic export.
// New history is owned by SidekickConversationStore; this defaults key is no longer a writer.
import Foundation

@MainActor enum SidekickHistory {
    static let key = "sidekick.history"
    private struct Completion: Codable { let outcome: String; let notchMessage: String }
    private struct Entry: Codable {
        let text: String
        let card: Bool
        let at: Date
        var outcome: String?
        let id: UUID?
        var result: Completion?
        var lastRecoveryError: String?
    }
    struct DiagnosticEntry: Encodable, Sendable {
        let at: Date
        let request: String
        let source: String
        let outcome: String
        let finalResponse: String?
        let lastRecoveryError: String?
        let legacySummary: String?
    }

    static func legacyEvents(defaults: UserDefaults = .standard) throws -> [SidekickConversationEvent] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries.flatMap { entry in
            let id = entry.id ?? UUID()
            let source = entry.card ? "proactive_card" : "command"
            var events: [SidekickConversationEvent] = [
                .init(id: "legacy-start:\(id)", taskID: id, kind: .taskStarted, text: entry.text, createdAt: entry.at, source: source),
                .init(id: "legacy-request:\(id)", taskID: id, kind: .userMessage, text: entry.text, createdAt: entry.at, source: source)
            ]
            if let error = entry.lastRecoveryError {
                events.append(.init(taskID: id, kind: .checkpoint, text: "Last reported blocker: " + error, createdAt: entry.at))
            }
            let outcome: SidekickConversationEvent.Outcome
            if let saved = entry.result?.outcome, let value = SidekickConversationEvent.Outcome(rawValue: saved) { outcome = value }
            else if entry.outcome == "you completed it" { outcome = .success }
            else if entry.outcome == "I stopped you before it finished" { outcome = .stopped }
            else if entry.outcome?.hasPrefix("you couldn't finish it (") == true { outcome = .failed }
            else { outcome = .interrupted }
            events.append(.init(id: "legacy-end:\(id)", taskID: id, kind: .taskFinished,
                text: entry.result?.notchMessage ?? entry.outcome ?? "Interrupted; no final result was recorded.",
                createdAt: entry.at, outcome: outcome))
            return events
        }
    }

    /// Retain the prior export's 15 requests, 300-char prompts and final status only.
    /// Never expand diagnostics into the full new conversation, answers or tool transcript.
    static func diagnosticEntries(defaults: UserDefaults = .standard) throws -> [DiagnosticEntry] {
        guard let store = SidekickConversation.shared.store else { throw SidekickConversation.Failure.unavailable }
        let records = try store.contextRecords(taskLimit: 15, limit: 500)
        let requests = records.filter { $0.event.kind == .userMessage }
        return requests.reversed().map { request in
            let end = records.last { $0.event.taskID == request.event.taskID && $0.event.kind == .taskFinished }
            return DiagnosticEntry(at: request.event.createdAt,
                request: CrashReporting.scrub(text: String(request.event.text.prefix(300))),
                source: request.event.source == "proactive_card" ? "suggestion_card" : "user_request",
                outcome: end?.event.outcome?.rawValue ?? "unfinished",
                finalResponse: end.map { CrashReporting.scrub(text: String($0.event.text.prefix(600))) },
                lastRecoveryError: nil, legacySummary: nil)
        }
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: "sidekick.errors")
    }
}
