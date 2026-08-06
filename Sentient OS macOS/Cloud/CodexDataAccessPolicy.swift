//
//  CodexDataAccessPolicy.swift
//  Sentient OS macOS
//
//  The default-deny contract for every `codex exec` run. Callers select one of the
//  named policies below; only this file translates that declaration into Codex config.
//  No prompt or result content is represented here.
//

import Foundation
import CryptoKit

nonisolated struct CodexDataAccessPolicy: Codable, Sendable, Equatable {
    static let currentVersion = 1

    enum Purpose: String, Codable, Sendable, CaseIterable {
        case validation
        case gmailProbe = "gmail-probe"
        case gmailImport = "gmail-import"
        case calendarProbe = "calendar-probe"
        case calendarImport = "calendar-import"
        case calendarProactive = "calendar-proactive"
        case vault
        case proactiveJudge = "proactive-judge"
        case proactiveResearch = "proactive-research"
        case giftLetter = "gift-letter"
        case gmailAction = "gmail-action"
        case calendarAction = "calendar-action"
        case computerUse = "computer-use"
    }

    enum WebAccess: String, Codable, Sendable { case denied, live }
    enum SessionPersistence: String, Codable, Sendable { case ephemeral, resumable }
    enum Capability: String, Codable, Sendable, CaseIterable {
        case web
        case gmailRead = "gmail-read"
        case gmailWrite = "gmail-write"
        case calendarRead = "calendar-read"
        case calendarWrite = "calendar-write"
        case computerUse = "computer-use"
        case memoryRead = "codex-memory-read"
        case memoryWrite = "codex-memory-write"
        case userMCP = "user-mcp"
    }

    enum HostedApp: String, Codable, Sendable {
        case gmail, calendar

        var connectorID: String {
            switch self {
            case .gmail: "connector_2128aebfecb84f64a069897515042a44"
            case .calendar: "connector_947e0d954944416db111db556030eea6"
            }
        }
    }

    enum HostedTool: String, Codable, Sendable, CaseIterable {
        case getProfile = "get_profile"
        case searchEmails = "search_emails"
        case readEmail = "read_email"
        case readEmailThread = "read_email_thread"
        case sendEmail = "send_email"
        case searchEvents = "search_events"
        case readEvent = "read_event"
        case createEvent = "create_event"
        case updateEvent = "update_event"

        var isWrite: Bool {
            switch self {
            case .sendEmail, .createEvent, .updateEvent: true
            default: false
            }
        }
    }

    struct HostedAppGrant: Codable, Sendable, Equatable {
        let app: HostedApp
        let tools: [HostedTool]

        init(app: HostedApp, tools: [HostedTool]) {
            self.app = app
            self.tools = Array(Set(tools)).sorted { $0.rawValue < $1.rawValue }
        }
    }

    let version: Int
    let purpose: Purpose
    let web: WebAccess
    let hostedApps: [HostedAppGrant]
    let allowUserMCP: Bool
    let allowMemoryUse: Bool
    let allowMemoryGeneration: Bool
    let session: SessionPersistence
    let userInitiatedComputerUse: Bool

    private init(purpose: Purpose,
                 web: WebAccess = .denied,
                 hostedApps: [HostedAppGrant] = [],
                 allowUserMCP: Bool = false,
                 allowMemoryUse: Bool = false,
                 allowMemoryGeneration: Bool = false,
                 session: SessionPersistence = .ephemeral,
                 userInitiatedComputerUse: Bool = false) {
        self.version = Self.currentVersion
        self.purpose = purpose
        self.web = web
        self.hostedApps = hostedApps.sorted { $0.app.rawValue < $1.app.rawValue }
        self.allowUserMCP = allowUserMCP
        self.allowMemoryUse = allowMemoryUse
        self.allowMemoryGeneration = allowMemoryGeneration
        self.session = session
        self.userInitiatedComputerUse = userInitiatedComputerUse
    }

    static let validation = CodexDataAccessPolicy(purpose: .validation)
    static let gmailProbe = CodexDataAccessPolicy(
        purpose: .gmailProbe,
        hostedApps: [.init(app: .gmail, tools: [.getProfile])]
    )
    static let gmailImport = CodexDataAccessPolicy(
        purpose: .gmailImport,
        hostedApps: [.init(app: .gmail, tools: [.searchEmails, .readEmail])]
    )
    static let calendarProbe = CodexDataAccessPolicy(
        purpose: .calendarProbe,
        hostedApps: [.init(app: .calendar, tools: [.getProfile])]
    )
    static let calendarImport = CodexDataAccessPolicy(
        purpose: .calendarImport,
        hostedApps: [.init(app: .calendar, tools: [.searchEvents, .readEvent])]
    )
    static let calendarProactive = CodexDataAccessPolicy(
        purpose: .calendarProactive,
        hostedApps: [.init(app: .calendar, tools: [.searchEvents])]
    )
    static let vault = CodexDataAccessPolicy(purpose: .vault, session: .resumable)
    static let proactiveJudge = CodexDataAccessPolicy(purpose: .proactiveJudge)
    static let giftLetter = CodexDataAccessPolicy(purpose: .giftLetter)
    static let gmailAction = CodexDataAccessPolicy(
        purpose: .gmailAction,
        hostedApps: [.init(app: .gmail, tools: [.sendEmail])]
    )
    static func calendarAction(_ tool: HostedTool) -> CodexDataAccessPolicy {
        precondition(tool == .createEvent || tool == .updateEvent,
                     "Calendar actions may enable exactly one write tool")
        return CodexDataAccessPolicy(
            purpose: .calendarAction,
            hostedApps: [.init(app: .calendar, tools: [tool])]
        )
    }
    static func proactiveResearch(gmailAuthorized: Bool) -> CodexDataAccessPolicy {
        CodexDataAccessPolicy(
            purpose: .proactiveResearch,
            web: .live,
            hostedApps: gmailAuthorized
                ? [.init(app: .gmail, tools: [.searchEmails, .readEmail, .readEmailThread])]
                : []
        )
    }
    static let computerUse = CodexDataAccessPolicy(
        purpose: .computerUse,
        userInitiatedComputerUse: true
    )

    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var declaredCapabilities: [Capability] {
        var values: Set<Capability> = []
        if web == .live { values.insert(.web) }
        if allowUserMCP { values.insert(.userMCP) }
        if allowMemoryUse { values.insert(.memoryRead) }
        if allowMemoryGeneration { values.insert(.memoryWrite) }
        if userInitiatedComputerUse { values.insert(.computerUse) }
        for grant in hostedApps {
            let writes = grant.tools.contains(where: \.isWrite)
            switch (grant.app, writes) {
            case (.gmail, false): values.insert(.gmailRead)
            case (.gmail, true): values.insert(.gmailWrite)
            case (.calendar, false): values.insert(.calendarRead)
            case (.calendar, true): values.insert(.calendarWrite)
            }
        }
        return values.sorted { $0.rawValue < $1.rawValue }
    }

    func allows(app: HostedApp, tool: HostedTool) -> Bool {
        hostedApps.contains { $0.app == app && $0.tools.contains(tool) }
    }

    /// Exact, strict per-run overrides. The user's config is ignored separately by CodexCLI;
    /// these values explicitly shut every inherited data plane even if Codex defaults change.
    func configurationOverrides() -> [String] {
        var values = [
            userInitiatedComputerUse ? "" : #"approval_policy="never""#,
            "web_search=\"\(web == .live ? "live" : "disabled")\"",
            "memories.use_memories=\(allowMemoryUse)",
            "memories.generate_memories=\(allowMemoryGeneration)",
            "apps._default.enabled=false",
            allowUserMCP ? "" : "mcp_servers={}",
            "plugins={}",
        ].filter { !$0.isEmpty }

        for grant in hostedApps {
            let key = "apps.\(grant.app.connectorID)"
            values += [
                "\(key).enabled=true",
                "\(key).default_tools_enabled=false",
                "\(key).open_world_enabled=\(grant.tools.contains(where: \.isWrite))",
                "\(key).destructive_enabled=false",
            ]
            for tool in grant.tools {
                values.append("\(key).tools.\(tool.rawValue).enabled=true")
                if tool.isWrite {
                    values.append("\(key).tools.\(tool.rawValue).approval_mode=\"approve\"")
                }
            }
        }

        if userInitiatedComputerUse {
            let source = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/.tmp/bundled-marketplaces/openai-bundled").path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            values += [
                "marketplaces.openai-bundled.source_type=\"local\"",
                "marketplaces.openai-bundled.source=\"\(source)\"",
                "plugins.\"computer-use@openai-bundled\".enabled=true",
            ]
        }
        return values
    }
}
