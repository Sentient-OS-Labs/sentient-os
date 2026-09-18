//
// DirectMCPModels.swift
// Value types for provider identity, per-account connections, OAuth grants and tool policy.
// Direct connection slugs are UUID-based; they never alias a hosted account's service slug.
//
// Doc: Documentation - Connectors (Direct MCP).md

import Foundation
import CryptoKit
import Security

nonisolated enum DirectMCPError: Error, LocalizedError {
    case invalidMetadata, unsupportedProvider, unsupportedRegistration, invalidCallback
    case authorizationDenied, timedOut, reconnectRequired, registrationExpired, accountSetupRequired, connectionChanged, noTools, policyUnavailable
    case keychain(OSStatus), network, http(Int), invalidResponse, tooLarge, busy, duplicateLabel, unconfirmedAction

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: "The service returned invalid login information."
        case .unsupportedProvider: "This server isn't supported for direct connections yet."
        case .unsupportedRegistration: "This service needs a different login method."
        case .invalidCallback: "The login response couldn't be verified. Please reconnect."
        case .authorizationDenied: "Access wasn't granted."
        case .timedOut: "The connection timed out. Please try again."
        case .reconnectRequired: "Sign in again to reconnect this account."
        case .registrationExpired: "This app connection needs a fresh sign-in. Please reconnect."
        case .accountSetupRequired: "Sign in with the email used by your Granola account. If you haven't created one, finish setting up Granola first."
        case .connectionChanged: "The connection changed. Please start the task again."
        case .noTools: "This connection hasn't made any tools available."
        case .policyUnavailable: "Sentient couldn't verify usable tools for this connection."
        case .keychain: "Sentient couldn't access the connection in Keychain. Unlock your Mac and try again."
        case .network: "The service couldn't be reached. Please try again."
        case .http(let code): code == 429 ? "The service is busy. Please try again later." : "The service couldn't complete the connection."
        case .invalidResponse: "The service returned a response Sentient couldn't verify."
        case .tooLarge: "The service's response exceeded the connection limit."
        case .busy: "This connection is already being updated. Please try again."
        case .duplicateLabel: "Choose a different label so you can tell these accounts apart."
        case .unconfirmedAction: "There is no confirmed result from the app. Check whether the action happened before trying again."
        }
    }
}

nonisolated enum DirectMCPConnectPhase: Sendable, Equatable {
    case openingBrowser, waitingForBrowser, verifyingAccount, checkingTools
}

nonisolated struct DirectMCPProvider: Sendable, Equatable {
    let slug: String
    let name: String
    let endpoint: URL
    /// Exact HTTPS origins that may serve this provider's public OAuth metadata and credentials.
    let trustedOrigins: Set<String>
    let offlineScope: String?
    /// Reviewed read names. A live inventory must contain these before KB access is eligible.
    let reviewedReads: Set<String>
    /// Enable only after the provider's bounded content reader passes its live curation check.
    var kbVerified = false

    /// Operations whose full argument surface cannot be permitted by a name-only policy.
    var destructiveTools: Set<String> {
        guard slug == "notion" else { return [] }
        return ["notion-update-page", "notion-update-data-source", "notion-update-folder",
                "notion-spawn-session", "notion-send-message-to-session", "notion-stop-session"]
    }
    /// Native knowledge plans can constrain arguments before any result reaches a model.
    /// These names are never added to the general MCP read attachment automatically.
    var nativeKnowledgeReads: Set<String> {
        switch slug {
        case "notion": ["notion-fetch", "notion-search", "notion-ai-search", "notion-list-recent-pages"]
        case "granola": ["get_account_info", "list_meetings", "get_meetings"]
        default: []
        }
    }

    static let granola = Self(slug: "granola", name: "Granola",
        endpoint: URL(string: "https://mcp.granola.ai/mcp")!,
        trustedOrigins: ["https://mcp.granola.ai", "https://mcp-auth.granola.ai"],
        offlineScope: "offline_access", reviewedReads: ["list_meetings", "get_meetings"], kbVerified: false)
    static let notion = Self(slug: "notion", name: "Notion",
        endpoint: URL(string: "https://mcp.notion.com/mcp")!,
        trustedOrigins: ["https://mcp.notion.com"], offlineScope: nil,
        reviewedReads: ["notion-fetch", "notion-list-recent-pages"], kbVerified: true)

    static var catalog: [Self] { ConnectorRegistry.packs.compactMap(\.directProvider) }
    static func find(_ slug: String) -> Self? {
        #if DEBUG
        if slug == "fixture", let value = ProcessInfo.processInfo.environment["SENTIENT_DIRECT_MCP_FIXTURE_URL"],
           let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1", url.port != nil {
            return Self(slug: "fixture", name: "Fixture", endpoint: url, trustedOrigins: [], offlineScope: nil, reviewedReads: ["read_item"])
        }
        #endif
        return catalog.first { $0.slug == slug }
    }

    func validate(_ url: URL) throws {
        #if DEBUG
        if slug == "fixture", url.scheme == "http", url.host == "127.0.0.1", url.port == endpoint.port,
           url.user == nil, url.password == nil, url.fragment == nil { return }
        #endif
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.user == nil, c.password == nil, c.fragment == nil,
              let host = c.host, !host.isEmpty,
              trustedOrigins.contains("https://\(host.lowercased())\(c.port.map { ":\($0)" } ?? "")") else {
            throw DirectMCPError.invalidMetadata
        }
    }
}

nonisolated struct DirectMCPConnection: Codable, Sendable, Identifiable, Equatable {
    enum State: String, Codable, Sendable { case verifying, connected, ready, unavailable, reconnect, policyRequired }
    let id: UUID
    let providerSlug: String
    var label: String
    var generation: UUID
    var state: State
    var verifiedAt: Date?
    var tools: [DirectMCPTool] = []
    var policy: [String: DirectMCPTool.Category] = [:]
    var policyFingerprint: String?
    var policyRevision: Int?
    var accountFingerprint: String?
    var accountLabel: String?

    var slug: String { "direct-" + id.uuidString.lowercased() }
    /// A prepared task must fail after relinking, rather than act on the replacement grant.
    var taskTarget: String { slug + "@" + generation.uuidString.lowercased() }
    var serverName: String { "sentient_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    var toolPrefix: String { "mcp__\(serverName)__" }
    var provider: DirectMCPProvider? { DirectMCPProvider.find(providerSlug) }
    var displayName: String { "\(provider?.name ?? providerSlug) · \(label)" }
    var policyValid: Bool {
        (policyRevision ?? 1) == Self.currentPolicyRevision && !tools.isEmpty && Set(policy.keys) == Set(tools.map(\.name))
            && policyFingerprint == DirectMCPTool.fingerprint(tools)
    }
    static let currentPolicyRevision = 1
    /// An authenticated account can be selected before its tools are prepared for a task.
    var connected: Bool { state == .connected || usable }
    var usable: Bool { state == .ready && policyValid && !actionNames.isEmpty }
    var readNames: [String] {
        guard policyValid else { return [] }
        return tools.filter { category(for: $0) == .read }.map(\.name).sorted()
    }
    var actionNames: [String] {
        guard policyValid else { return [] }
        return tools.filter { category(for: $0) != .destructive }.map(\.name).sorted()
    }
    /// Apply reviewed exclusions to old caches as well as freshly classified inventories.
    /// Vendor hints can narrow a policy, never grant a capability on their own.
    func category(for tool: DirectMCPTool) -> DirectMCPTool.Category {
        if provider?.destructiveTools.contains(tool.name) == true || tool.destructiveHint { return .destructive }
        return policy[tool.name] ?? .destructive
    }
    var kbEligible: Bool {
        guard provider?.kbVerified == true else { return false }
        // Opt-in is available after login; the native reader verifies policy before reading.
        return (state == .connected && provider?.reviewedReads.isEmpty == false) || kbPolicyReady
    }
    /// Curation can test this policy in an isolated store before enabling the production reader.
    var kbPolicyReady: Bool {
        guard usable, let reviewed = provider?.reviewedReads, !reviewed.isEmpty else { return false }
        var required = providerSlug == "notion" ? reviewed.union(["notion-search"]) : reviewed
        if providerSlug == "granola" {
            guard accountFingerprint != nil else { return false }
            required.insert("get_account_info")
        }
        return required.isSubset(of: Set(readNames))
            && tools.filter { required.contains($0.name) }.allSatisfy(\.readOnlyHint)
    }
    var detected: ConnectorCensus.DetectedConnector {
        .init(slug: slug, displayName: displayName, origin: .direct, serverURL: provider?.endpoint.absoluteString,
              catalogID: nil, iconPath: nil, healthy: connected, lastSeen: verifiedAt ?? .distantPast)
    }
}

nonisolated struct DirectMCPTool: Codable, Sendable, Equatable {
    enum Category: String, Codable, Sendable { case read, write, destructive }
    let name: String
    let description: String
    /// Canonically serialized complete tool metadata, including schema and annotations.
    let definition: Data

    var annotations: [String: Any] {
        let value = try? JSONSerialization.jsonObject(with: definition) as? [String: Any]
        return value?["annotations"] as? [String: Any] ?? [:]
    }
    var destructiveHint: Bool { annotations["destructiveHint"] as? Bool == true }
    var readOnlyHint: Bool { annotations["readOnlyHint"] as? Bool == true && !destructiveHint }

    static func fingerprint(_ tools: [Self]) -> String {
        let bytes = tools.sorted { $0.name < $1.name }.reduce(into: Data()) { result, tool in
            result.append(tool.definition); result.append(0)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func validName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil
    }
}

nonisolated struct DirectMCPGrant: Codable, Sendable {
    let connectionID: UUID
    let generation: UUID
    let providerSlug: String
    let issuer: URL
    let resource: URL
    let tokenEndpoint: URL
    let revocationEndpoint: URL?
    let clientID: String
    let clientSecret: String?
    let authenticationMethod: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var issuedAt: Date
    var scopes: [String]
    var revoked = false
    var registrationValid: Bool?
}

nonisolated enum DirectMCPCrypto {
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DirectMCPError.invalidResponse
        }
        return base64url(Data(bytes))
    }
    static func challenge(_ verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func base64url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
