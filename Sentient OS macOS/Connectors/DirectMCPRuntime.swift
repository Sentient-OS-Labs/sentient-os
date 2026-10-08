//
// DirectMCPRuntime.swift
// Prepares an immutable direct-connection tool policy for a task and serializes each engine's
// config. Credentials are supplied by the app's header-helper entry point, never argv or files.
//
// Doc: Documentation - Connectors (Direct MCP).md

import Foundation
import os

nonisolated enum DirectMCPRuntime {
    enum Mode: Sendable { case read, action }
    struct Attachment: Codable, Sendable {
        let connection: DirectMCPConnection
        let allowed: [String]
        let deadline: Date
        var target: String? = nil
        var requestedTarget: String { target ?? connection.slug }
        var prefix: String { connection.toolPrefix }
        var denied: [String] { connection.tools.map(\.name).filter { !allowed.contains($0) }.map { prefix + $0 } }
        var allAllowed: [String] { allowed.map { prefix + $0 } }
        var payload: String {
            let lease = Lease(connectionID: connection.id, generation: connection.generation,
                providerSlug: connection.providerSlug, serverName: connection.serverName, allowed: allowed, deadline: deadline)
            return (try? JSONEncoder().encode(lease).base64EncodedString()) ?? ""
        }
        var helperCommand: String { Self.executable + " --direct-mcp-headers " + shellQuote(payload) }
        private static var executable: String { shellQuote(Bundle.main.executableURL?.path ?? CommandLine.arguments[0]) }
    }
    struct Lease: Codable, Sendable {
        let connectionID: UUID
        let generation: UUID
        let providerSlug: String
        let serverName: String
        let allowed: [String]
        let deadline: Date
        var allAllowed: [String] { allowed.map { "mcp__\(serverName)__" + $0 } }
    }
    @TaskLocal static var current: [Attachment] = []
    private static let active = OSAllocatedUnfairLock(initialState: [UUID: (Set<UUID>, @Sendable () -> Void)]())

    static func prepare(slugs: [String], mode: Mode, subset: [String]? = nil,
                        timeout: TimeInterval) async throws -> [Attachment] {
        return try await Diagnostics.boundary(.connectorFailed, phase: .setup, reason: "direct_attachment", source: "direct_connector") {
            var result: [Attachment] = []
            for slug in Set(slugs).sorted() where slug.hasPrefix("direct-") {
                guard let connection = DirectMCPStore.connection(slug) else { throw DirectMCPError.connectionChanged }
                let verified = try await DirectMCPConnections.verify(connection)
                let names: [String]
                switch mode {
                case .read: names = Array((verified.provider?.reviewedReads ?? []).intersection(Set(verified.readNames))).sorted()
                case .action: names = verified.actionNames
                }
                let allowed = subset ?? names
                guard !allowed.isEmpty, Set(allowed).isSubset(of: Set(names)) else { throw DirectMCPError.policyUnavailable }
                result.append(.init(connection: verified, allowed: allowed,
                                    deadline: Date().addingTimeInterval(min(timeout, 21_600) + 30), target: slug))
            }
            return result
        }
    }
    static func execute<T: Sendable>(_ attachments: [Attachment],
                                    operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !attachments.isEmpty else { return try await $current.withValue([], operation: operation) }
        return try await track(connectionIDs: Set(attachments.map(\.connection.id))) {
            for attachment in attachments {
                guard DirectMCPStore.connection(id: attachment.connection.id)?.generation == attachment.connection.generation else {
                    throw DirectMCPError.connectionChanged
                }
            }
            try Task.checkCancellation()
            return try await $current.withValue(attachments, operation: operation)
        }
    }

    static func executeNative<T: Sendable>(connection: DirectMCPConnection,
                                           operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await track(connectionIDs: [connection.id]) {
            try DirectMCPSession.check(connection)
            return try await $current.withValue([], operation: operation)
        }
    }

    /// Register cancellation before allowing either native or CLI work to start.
    static func track<T: Sendable>(connectionIDs: Set<UUID>,
                                  operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let id = UUID()
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            for await _ in start.stream { break }
            try Task.checkCancellation()
            return try await operation()
        }
        active.withLock { $0[id] = (connectionIDs, { task.cancel() }) }
        defer { active.withLock { _ = $0.removeValue(forKey: id) } }
        start.continuation.yield(())
        start.continuation.finish()
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func cancel(connectionID: UUID) {
        let cancellations = active.withLock { $0.values.filter { $0.0.contains(connectionID) }.map { $0.1 } }
        cancellations.forEach { $0() }
    }
    static func hasSuccessfulCall(raw: String, backend: ModelBackend, attachment: Attachment) -> Bool {
        if backend == .claude { return !MCPCallEvidence.claude(raw: raw).isDisjoint(with: Set(attachment.allAllowed)) }
        return MCPCallEvidence.codex(raw: raw).contains {
            $0.server == attachment.connection.serverName && attachment.allowed.contains($0.tool)
        }
    }

    static func codexOverrides(_ attachments: [Attachment]) -> [String] {
        guard !attachments.isEmpty else { return [] }
        var overrides: [String] = []
        for attachment in attachments {
            guard let provider = attachment.connection.provider else { continue }
            let key = "mcp_servers." + attachment.connection.serverName
            overrides += ["\(key).url=\(quoted(provider.endpoint.absoluteString))",
                "\(key).http_headers_helper=\(quoted(attachment.helperCommand))",
                "\(key).enabled_tools=[\(attachment.allowed.map(quoted).joined(separator: ","))]",
                "\(key).default_tools_approval_mode=\"approve\"", "\(key).required=true",
                "\(key).startup_timeout_sec=45", "\(key).tool_timeout_sec=120"]
        }
        return overrides
    }
    static func claudeConfig(_ attachments: [Attachment], driverJSON: String? = nil) throws -> String {
        var servers: [String: Any] = [:]
        if let driverJSON, let data = driverJSON.data(using: .utf8),
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            servers = object["mcpServers"] as? [String: Any] ?? [:]
        }
        for attachment in attachments {
            guard let provider = attachment.connection.provider else { throw DirectMCPError.unsupportedProvider }
            servers[attachment.connection.serverName] = ["type": "http", "url": provider.endpoint.absoluteString,
                                                         "headersHelper": attachment.helperCommand]
        }
        return String(decoding: try DirectMCPHTTP.json(["mcpServers": servers]), as: UTF8.self)
    }
    /// Explicit ask rules remain in force under bypass. A PermissionRequest hook grants only
    /// the captured set. With no successful decision, a headless permission request is denied.
    static func claudeSettings(_ attachments: [Attachment], hostedURLs: [String], driver: Bool = false,
                               guardBypass: Bool = false) throws -> String {
        var entries: [[String: String]] = hostedURLs.compactMap {
            guard let url = URL(string: $0), let host = url.host, let scheme = url.scheme else { return nil }
            return ["serverUrl": "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")/*"]
        }
        if driver { entries.append(["serverName": "cua_driver"]) }
        var hooks: [[String: Any]] = []
        var asks: [String] = []
        for attachment in attachments {
            let server = attachment.connection.serverName
            entries.append(["serverName": server])
            if guardBypass { asks.append(attachment.prefix + "*") }
            let command = shellQuote(Bundle.main.executableURL?.path ?? CommandLine.arguments[0])
                + " --direct-mcp-policy " + shellQuote(attachment.payload) + " || exit 2"
            if guardBypass { hooks.append(["matcher": "^mcp__\(server)__", "hooks": [["type": "command", "command": command, "timeout": 5]]]) }
        }
        return String(decoding: try DirectMCPHTTP.json(["allowedMcpServers": entries,
            "permissions": ["ask": asks], "hooks": ["PermissionRequest": hooks]]), as: UTF8.self)
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func quoted(_ value: String) -> String {
        // JSON string literals are compatible with TOML basic strings for these generated values.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    /// Runs before SwiftUI or diagnostics initialization. stdout is a credential pipe only in
    /// header mode; errors have fixed text and can never echo a token or provider response.
    static func runHelper(arguments: [String]) async -> Int32 {
        guard arguments.count == 3, let data = Data(base64Encoded: arguments[2]), data.count < 1_000_000,
              let attachment = try? JSONDecoder().decode(Lease.self, from: data), attachment.deadline > Date(),
              attachment.allowed.allSatisfy(DirectMCPTool.validName), !attachment.allowed.isEmpty,
              attachment.serverName == "sentient_" + attachment.connectionID.uuidString.replacingOccurrences(of: "-", with: "").lowercased() else { return 2 }
        do {
            let grant = try DirectMCPStore.readGrant(attachment.connectionID)
            guard grant.generation == attachment.generation, !grant.revoked,
                  grant.providerSlug == attachment.providerSlug else { return 2 }
            if arguments[1] == "--direct-mcp-policy" {
                let input = try FileHandle.standardInput.read(upToCount: 1_000_001) ?? Data()
                guard input.count <= 1_000_000,
                      let object = try JSONSerialization.jsonObject(with: input) as? [String: Any],
                      object["hook_event_name"] as? String == "PermissionRequest",
                      let name = object["tool_name"] as? String, attachment.allAllowed.contains(name) else { return 2 }
                let result: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
                try FileHandle.standardOutput.write(contentsOf: DirectMCPHTTP.json(result))
                return 0
            }
            guard arguments[1] == "--direct-mcp-headers" else { return 2 }
            let token = try await DirectMCPAuth.accessToken(id: grant.connectionID, generation: grant.generation, refresh: true)
            try FileHandle.standardOutput.write(contentsOf: DirectMCPHTTP.json(["Authorization": "Bearer " + token]))
            return 0
        } catch {
            #if DEBUG
            let reason: String
            if case DirectMCPError.keychain(let code) = error { reason = "Keychain status \(code)" }
            else if let issue = error as? DirectMCPError { reason = String(describing: issue) }
            else { reason = "helper failed" }
            // This process's stdout is a machine-only credential channel; diagnostics use stderr.
            try? FileHandle.standardError.write(contentsOf: Data(("Direct MCP helper: " + reason + "\n").utf8))
            #endif
            return 2
        }
    }
}
