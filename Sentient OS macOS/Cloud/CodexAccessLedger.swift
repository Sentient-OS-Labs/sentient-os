//
//  CodexAccessLedger.swift
//  Sentient OS macOS
//
//  A content-free local audit trail for Codex data access. It records capability names and
//  lifecycle only — never prompts, arguments, queries, results, paths, or raw JSONL.
//

import Foundation

nonisolated struct CodexAccessObservation: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable { case web, hostedApp, unknownMCP, computerUse }
    enum Lifecycle: String, Codable, Sendable { case started, completed, failed, unavailable }

    let kind: Kind
    let app: CodexDataAccessPolicy.HostedApp?
    let tool: CodexDataAccessPolicy.HostedTool?
    let lifecycle: Lifecycle

    static func web(_ lifecycle: Lifecycle) -> Self {
        .init(kind: .web, app: nil, tool: nil, lifecycle: lifecycle)
    }

    static func hosted(app: CodexDataAccessPolicy.HostedApp,
                       tool: CodexDataAccessPolicy.HostedTool,
                       lifecycle: Lifecycle) -> Self {
        .init(kind: .hostedApp, app: app, tool: tool, lifecycle: lifecycle)
    }

    static func unknown(_ lifecycle: Lifecycle) -> Self {
        .init(kind: .unknownMCP, app: nil, tool: nil, lifecycle: lifecycle)
    }

    static let computerUseUnavailable = Self(kind: .computerUse, app: nil, tool: nil,
                                              lifecycle: .unavailable)

    /// Canonicalize a public Codex JSONL item without retaining its query, arguments, results,
    /// or unknown raw identifiers.
    static func canonical(item: [String: Any], eventType: String) -> Self? {
        let itemType = item["type"] as? String ?? ""
        var lifecycle: Lifecycle = eventType == "item.started" ? .started : .completed
        if (item["status"] as? String) == "failed" || item["error"] != nil { lifecycle = .failed }
        if itemType == "web_search" || itemType == "web_search_call" {
            return .web(lifecycle)
        }
        guard itemType == "mcp_tool_call" || itemType == "tool_call" || itemType == "function_call" else {
            return nil
        }

        let server = (item["server"] as? String ?? "").lowercased()
        let rawTool = ((item["tool"] as? String) ?? (item["name"] as? String) ?? "").lowercased()
        let toolName = rawTool.split(separator: ".").last.map(String.init) ?? rawTool
        guard let tool = CodexDataAccessPolicy.HostedTool(rawValue: toolName) else {
            return .unknown(lifecycle)
        }

        func identifies(_ hostedApp: CodexDataAccessPolicy.HostedApp) -> Bool {
            let name = hostedApp.rawValue
            let toolPrefix = hostedApp == .calendar ? "google_calendar." : name + "."
            let hostedServer = server.isEmpty || server == "codex_apps" || server == "codex-apps"
                || server == name || (hostedApp == .calendar && server == "google_calendar")
                || server == hostedApp.connectorID
            let namedTool = rawTool.hasPrefix(name + ".") || rawTool.hasPrefix(toolPrefix)
                || rawTool.contains(hostedApp.connectorID)
                || server == name || (hostedApp == .calendar && server == "google_calendar")
                || server == hostedApp.connectorID
            return hostedServer && namedTool
        }
        let app: CodexDataAccessPolicy.HostedApp?
        switch tool {
        case .searchEmails, .readEmail, .readEmailThread, .sendEmail:
            app = identifies(.gmail) ? .gmail : nil
        case .searchEvents, .readEvent, .createEvent, .updateEvent:
            app = identifies(.calendar) ? .calendar : nil
        case .getProfile:
            if identifies(.gmail) {
                app = .gmail
            } else if identifies(.calendar) {
                app = .calendar
            } else {
                app = nil
            }
        }
        guard let app else { return .unknown(lifecycle) }
        return .hosted(app: app, tool: tool, lifecycle: lifecycle)
    }

}

extension CodexDataAccessPolicy {
    func allows(_ observation: CodexAccessObservation) -> Bool {
        switch observation.kind {
        case .web:
            return web == .live
        case .hostedApp:
            guard let app = observation.app, let tool = observation.tool else { return false }
            return allows(app: app, tool: tool)
        case .computerUse:
            return userInitiatedComputerUse
        case .unknownMCP:
            return false
        }
    }
}

nonisolated struct CodexAccessReceipt: Codable, Sendable, Identifiable, Equatable {
    enum Outcome: String, Codable, Sendable {
        case succeeded, failed, cancelled, policyViolation
    }

    let id: UUID
    let timestamp: Date
    let policyVersion: Int
    let policyFingerprint: String
    let feature: CodexDataAccessPolicy.Purpose
    let declaredCapabilities: [CodexDataAccessPolicy.Capability]
    let observations: [CodexAccessObservation]
    let outcome: Outcome
    let session: CodexDataAccessPolicy.SessionPersistence
}

actor CodexAccessLedger {
    static let shared = CodexAccessLedger()
    static let retentionLimit = 250

    private static let fileURL = URL.sentientSupport.appendingPathComponent("codex-access-ledger-v1.json")
    private var receipts: [CodexAccessReceipt]

    init() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? decoder.decode([CodexAccessReceipt].self, from: data) {
            receipts = Array(decoded.suffix(Self.retentionLimit))
        } else {
            receipts = []
        }
    }

    func record(policy: CodexDataAccessPolicy,
                observations: [CodexAccessObservation],
                outcome: CodexAccessReceipt.Outcome,
                at timestamp: Date = Date()) {
        let safeObservations = Array(Set(observations)).sorted {
            ($0.kind.rawValue, $0.app?.rawValue ?? "", $0.tool?.rawValue ?? "", $0.lifecycle.rawValue)
                < ($1.kind.rawValue, $1.app?.rawValue ?? "", $1.tool?.rawValue ?? "", $1.lifecycle.rawValue)
        }
        receipts.append(CodexAccessReceipt(
            id: UUID(), timestamp: timestamp, policyVersion: policy.version,
            policyFingerprint: policy.fingerprint, feature: policy.purpose,
            declaredCapabilities: policy.declaredCapabilities,
            observations: safeObservations, outcome: outcome, session: policy.session
        ))
        if receipts.count > Self.retentionLimit {
            receipts.removeFirst(receipts.count - Self.retentionLimit)
        }
        persist()
    }

    func snapshot() -> [CodexAccessReceipt] {
        receipts.sorted { $0.timestamp > $1.timestamp }
    }

    func lastSuccessfulAccess(to source: SourceSelection.CloudSource) -> Date? {
        receipts.reversed().first { receipt in
            guard receipt.outcome == .succeeded else { return false }
            return receipt.declaredCapabilities.contains(source == .gmail ? .gmailRead : .calendarRead)
                || receipt.declaredCapabilities.contains(source == .gmail ? .gmailWrite : .calendarWrite)
        }?.timestamp
    }

    func clear(source: SourceSelection.CloudSource) {
        let capabilities: Set<CodexDataAccessPolicy.Capability> = source == .gmail
            ? [.gmailRead, .gmailWrite] : [.calendarRead, .calendarWrite]
        receipts.removeAll { receipt in
            receipt.declaredCapabilities.contains(where: capabilities.contains)
        }
        persist()
    }

    func reset() {
        receipts = []
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(receipts) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
