//
// OutlookCalendarToolPolicy.swift
// Argument checks for default-calendar reads and single-event creation. The shared Outlook
// hook dispatches here so Mail and Calendar compose without approving unrelated suite tools.
// Doc: Documentation - Cloud - CodexCLI (the codex exec spine).md
//

import Foundation

nonisolated enum OutlookCalendarToolPolicy {
    struct Context: Codable, Sendable {
        let operation: OutlookCalendarConnector.Operation
        var purpose: String? = nil
        var lower: Double? = nil
        var upper: Double? = nil
        var expectedCreationHash: String? = nil
        var accountFingerprint: String? = nil
        var intentHash: String? = nil

        init(operation: OutlookCalendarConnector.Operation,
             purpose: OutlookCalendarConnector.ReadPurpose? = nil, window: MCPSource.Window? = nil,
             expectedCreationHash: String? = nil, accountFingerprint: String? = nil, intentHash: String? = nil) {
            self.operation = operation; self.purpose = purpose?.rawValue
            lower = window?.lower.timeIntervalSince1970; upper = window?.upper.timeIntervalSince1970
            self.expectedCreationHash = expectedCreationHash
            self.accountFingerprint = accountFingerprint; self.intentHash = intentHash
        }
        var window: MCPSource.Window? {
            guard let lower, let upper, lower.isFinite, upper.isFinite, lower < upper else { return nil }
            return .init(lower: Date(timeIntervalSince1970: lower), upper: Date(timeIntervalSince1970: upper), label: "")
        }
        var valid: Bool {
            let bounded = purpose != nil
            return (bounded ? (operation == .read && OutlookCalendarConnector.ReadPurpose(rawValue: purpose!) != nil && window != nil)
                            : (lower == nil && upper == nil))
                && (operation == .read || (Self.isHash(accountFingerprint) && Self.isHash(intentHash)))
                && (expectedCreationHash == nil || (operation == .create && expectedCreationHash!.range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil))
        }
        private static func isHash(_ value: String?) -> Bool {
            value?.range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil
        }
        var encoded: String { (try? JSONEncoder().encode(self).base64EncodedString()) ?? "invalid" }
        static func decode(_ text: String) -> Context? {
            guard text.utf8.count <= 2_048, let data = Data(base64Encoded: text),
                  let context = try? JSONDecoder().decode(Context.self, from: data), context.valid else { return nil }
            return context
        }
        var discoveryCap: Int { purpose == "iterative" ? 4 : 8 }
        var detailCap: Int { purpose == "context" ? 8 : (purpose == "iterative" ? 4 : 8) }
    }
    // Reservations contain no event text, account addresses or IDs. They survive an uncertain
    // process result; only independent confirmation or the user's full reset removes them.
    static var pendingDirectory: URL { URL.sentientSupport.appending(path: "OutlookCalendarPending", directoryHint: .isDirectory) }
    static func reserve(_ creation: Creation, context: Context) -> Bool {
        guard context.valid, let account = context.accountFingerprint, let intent = context.intentHash else { return false }
        do { try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return false }
        let event = pendingDirectory.appending(path: account + "-event-" + creation.signature)
        guard HostedToolPolicy.claim(event) else { return false }
        let task = pendingDirectory.appending(path: account + "-intent-" + intent)
        guard HostedToolPolicy.claim(task) else {
            try? FileManager.default.removeItem(at: event)
            return false
        }
        return true
    }
    static func clearConfirmed(_ creation: Creation, account: String, intent: String) {
        try? FileManager.default.removeItem(at: pendingDirectory.appending(path: account + "-event-" + creation.signature))
        try? FileManager.default.removeItem(at: pendingDirectory.appending(path: account + "-intent-" + intent))
    }

    static let pageSize = 25

    /// Shared profile/resource names belong to Calendar only when their arguments identify
    /// its permitted resource. Unknown names still fail through the complete suite policy.
    static func handles(_ name: String, input: [String: Any], backend: ModelBackend) -> Bool {
        guard let bare = OutlookCalendarConnector.bareName(name, backend: backend) else { return false }
        if backend == .chatgpt { return true }
        if bare == "read_resource" { return (input["uri"] as? String).flatMap(OutlookCalendarConnector.eventID) != nil }
        return OutlookCalendarConnector.actionTools(backend, operation: .create).contains(bare)
            && !["get_me", "get_granted_scopes"].contains(bare)
    }

    static func allowed(name: String, input: [String: Any], backend: ModelBackend, context: Context) -> Bool {
        guard context.valid, let bare = OutlookCalendarConnector.bareName(name, backend: backend),
              OutlookCalendarConnector.actionTools(backend, operation: context.operation).contains(bare),
              OutlookMailSource.absent(input, "calendarOwnerEmail"), OutlookMailSource.absent(input, "calendarName"),
              OutlookMailSource.absent(input, "calendar_id"), OutlookMailSource.absent(input, "calendarId") else { return false }
        if ["get_me", "get_granted_scopes", "get_profile", "get_mailbox_settings"].contains(bare) {
            return context.purpose == nil && input.isEmpty
        }
        if bare == "read_resource" {
            guard Set(input.keys) == ["uri"], let uri = input["uri"] as? String,
                  OutlookCalendarConnector.eventID(uri) != nil else { return false }
        }
        if bare == "fetch_event" {
            guard Set(input.keys).isSubset(of: ["event_id", "calendar_id"]), let id = input["event_id"] as? String,
                  OutlookCalendarConnector.validID(id) else { return false }
        }
        if bare == OutlookCalendarConnector.createTool(backend) {
            guard context.operation == .create, context.purpose == nil,
                  let event = Creation(input: input, backend: backend) else { return false }
            return context.expectedCreationHash == nil || event.signature == context.expectedCreationHash
        }
        if let window = context.window {
            guard OutlookCalendarConnector.knowledgeTools(backend).contains(bare) else { return false }
            if bare == "outlook_calendar_search" {
                return Set(input.keys).isSubset(of: ["query", "afterDateTime", "beforeDateTime", "limit", "offset", "order"])
                    && input["query"] as? String == "*"
                    && input["afterDateTime"] as? String == MCPSource.timestamp(window.lower.addingTimeInterval(-0.001))
                    && input["beforeDateTime"] as? String == MCPSource.timestamp(window.upper)
                    && input["order"] as? String == "newest"
                    && integer(input["limit"], in: 1...pageSize) && integer(input["offset"] ?? 0, in: 0...1000)
            }
            if bare == "list_events" {
                return Set(input.keys).isSubset(of: ["start_datetime", "end_datetime", "top", "order_by", "calendar_id"])
                    && input["start_datetime"] as? String == MCPSource.timestamp(window.lower)
                    && input["end_datetime"] as? String == MCPSource.timestamp(window.upper)
                    && integer(input["top"], in: 1...OutlookCalendarSource.eventCap)
                    && input["order_by"] as? String == "start/dateTime desc"
            }
            return context.detailCap > 0
        }
        return true
    }

    static func integer(_ value: Any?, in range: ClosedRange<Int>) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else { return false }
        return range.contains(number.intValue)
    }

    struct Creation: Codable, Equatable, Sendable {
        let subject: String
        let start: Double
        let end: Double
        let attendees: [String]
        let body: String
        let location: String

        init?(input: [String: Any], backend: ModelBackend) {
            let keys: Set<String> = backend == .claude
                ? ["subject", "start", "end", "attendees", "body", "bodyType", "location", "sensitivity", "calendarId", "isOnlineMeeting"]
                : ["subject", "start", "end", "attendees", "body_content", "body_content_type", "location", "calendar_id", "recurrence"]
            guard Set(input.keys).isSubset(of: keys), let subject = input["subject"] as? String,
                  !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, subject.count <= 255,
                  let start = CalendarEventTime.date(input["start"]), let end = CalendarEventTime.date(input["end"]), end > start,
                  OutlookMailSource.absent(input, "recurrence"), OutlookMailSource.absent(input, "calendar_id"),
                  OutlookMailSource.absent(input, "calendarId"),
                  input["isOnlineMeeting"] == nil || input["isOnlineMeeting"] as? Bool == false,
                  input["sensitivity"] == nil || ["normal", "personal", "private", "confidential"].contains(input["sensitivity"] as? String ?? "") else { return nil }
            let bodyKey = backend == .claude ? "body" : "body_content"
            let typeKey = backend == .claude ? "bodyType" : "body_content_type"
            guard input[typeKey] == nil || input[typeKey] as? String == (backend == .claude ? "text" : "Text"),
                  input[bodyKey] == nil || input[bodyKey] is NSNull || input[bodyKey] is String,
                  input["location"] == nil || input["location"] is NSNull || input["location"] is String else { return nil }
            let body = input[bodyKey] as? String ?? "", location = input["location"] as? String ?? ""
            guard body.utf8.count <= 12_000, location.count <= 512 else { return nil }
            let values: [[String: Any]]
            if OutlookMailSource.absent(input, "attendees") { values = [] }
            else if let entries = input["attendees"] as? [[String: Any]], entries.count <= 50 { values = entries }
            else { return nil }
            var recipients: [String] = []
            var addresses = Set<String>()
            for attendee in values {
                guard Set(attendee.keys).isSubset(of: backend == .claude ? ["email", "name", "type"] : ["emailAddress", "type"]),
                      attendee["type"] == nil || ["required", "optional"].contains(attendee["type"] as? String ?? "") else { return nil }
                let address = backend == .claude ? attendee["email"] as? String
                    : (attendee["emailAddress"] as? [String: Any])?["address"] as? String
                guard let address, address.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil,
                      addresses.insert(address.lowercased()).inserted else { return nil }
                recipients.append(address.lowercased() + ":" + (attendee["type"] as? String ?? "required"))
            }
            guard Set(recipients).count == recipients.count else { return nil }
            self.subject = subject; self.start = start.timeIntervalSince1970; self.end = end.timeIntervalSince1970
            attendees = recipients.sorted(); self.body = body; self.location = location
        }
        var signature: String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return OutlookToolPolicy.hash(String(data: try! encoder.encode(self), encoding: .utf8)!)
        }
    }
}
