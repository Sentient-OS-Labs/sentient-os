// Value types and persistent non-secret account metadata for Sentient-hosted cloud connections.
// Account UUIDs and generations are independent of subscription connectors and local OAuth grants.
// Doc: Connectors/Documentation - Connectors (Direct MCP).md
import Foundation
import os

nonisolated struct HostedConnectorAccount: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let service: String
    let generation: Int
    let label: String
    let status: String
    var slug: String { "hosted-" + id.uuidString.lowercased() }
    var taskTarget: String { slug + "@" + String(generation) }
    var connected: Bool { status == "active" }
    var displayName: String { (ConnectorRegistry.packs.first { $0.slug == service }?.displayName ?? service) + " · " + label }
    var taskDescription: String {
        switch service {
        case "gmail": "search and read Gmail; send and reply with plain text; no attachments or mailbox changes"
        case "google-calendar", "outlook-calendar": "read the primary calendar and create single timed events with explicit offsets; no all-day events, recurrence, secondary calendars or existing-event changes"
        case "google-drive": "search Drive metadata, read small Google Docs and text files, create new plain-text files in My Drive; no binary content, existing-file edits or sharing changes"
        case "slack": "search and read workspace messages and threads, resolve users and existing conversations, send messages and replies; no new DM creation, uploads, edits or deletions"
        case "outlook-mail": "read the primary Outlook mailbox, send and reply with plain text; no attachments, forwarding, shared mailboxes or mailbox changes"
        default: ""
        }
    }
    var detected: ConnectorCensus.DetectedConnector {
        .init(slug: slug, displayName: displayName, origin: .sentient, serverURL: nil, catalogID: nil,
              iconPath: nil, healthy: connected, lastSeen: .now)
    }
}

nonisolated enum HostedConnectorStore {
    static let key = "connectors.sentient.accounts.v1"
    static let managementUsedKey = "connectors.sentient.management-used.v1"
    static let services: Set<String> = ["gmail", "google-calendar", "google-drive", "slack", "outlook-mail", "outlook-calendar"]
    static let changed = Notification.Name("HostedConnectorAccountsChanged")
    private struct Snapshot: Codable { let revision: Int; let accounts: [HostedConnectorAccount] }
    private static let saving = OSAllocatedUnfairLock(initialState: ())
    static func accounts() -> [HostedConnectorAccount] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        let accounts = (try? JSONDecoder().decode(Snapshot.self, from: data).accounts)
            ?? (try? JSONDecoder().decode([HostedConnectorAccount].self, from: data)) ?? []
        return accounts.filter { services.contains($0.service) && $0.generation > 0 }
    }
    static func account(_ target: String) -> HostedConnectorAccount? {
        let parts = target.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2, let account = accounts().first(where: { $0.slug == parts[0] }) else { return nil }
        if parts.count == 2, Int(parts[1]) != account.generation { return nil }
        return account
    }
    static func save(_ accounts: [HostedConnectorAccount], revision: Int) throws {
        let data = try JSONEncoder().encode(Snapshot(revision: revision, accounts: accounts))
        let applied = saving.withLock { _ in
            if let previous = UserDefaults.standard.data(forKey: key),
               let snapshot = try? JSONDecoder().decode(Snapshot.self, from: previous), snapshot.revision >= revision { return false }
            UserDefaults.standard.set(data, forKey: key); return true
        }
        if applied { NotificationCenter.default.post(name: changed, object: nil) }
    }
}

nonisolated enum HostedConnectorFailure: Error, LocalizedError, Sendable {
    case connectionChanged, invalidResponse, authorizationExpired, unsupportedFile, incompleteRead, writeUncertain, revocationPending
    var errorDescription: String? {
        switch self {
        case .connectionChanged: "This connected account changed. Start a new task with the intended account."
        case .invalidResponse: "The connected service returned an unreadable response. Your selection and saved progress are unchanged."
        case .authorizationExpired: "Sign-in was cancelled or expired. Connect again when you’re ready."
        case .unsupportedFile: "This file cannot be read through the hosted connection yet."
        case .incompleteRead: "The read reached its limit. Saved progress will resume on the next analysis."
        case .writeUncertain: "The service may have completed this action. Check the service before trying again; Sentient will not repeat it automatically."
        case .revocationPending: "Sentient has blocked access, but removal of the saved connection is still pending. Retry cleanup once the connection returns."
        }
    }
}

/// Sendable JSON for gateway-owned tool schemas and payloads. No untyped values cross actors.
nonisolated enum ConnectorJSON: Codable, Sendable, Equatable {
    case object([String: ConnectorJSON]), array([ConnectorJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> Self? { if case .object(let v) = self { return v[key] }; return nil }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var array: [Self]? { if case .array(let v) = self { return v }; return nil }
    var object: [String: Self]? { if case .object(let v) = self { return v }; return nil }
    func data() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(self) }
    var text: String { (try? data()).map { String(decoding: $0, as: UTF8.self) } ?? "null" }
}
