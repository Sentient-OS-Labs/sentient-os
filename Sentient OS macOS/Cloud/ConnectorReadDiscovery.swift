// Optional live routing and read-tool metadata. Discovery uses CLI control messages only.
// A failed discovery leaves the existing route usable and never changes connection state.

import Foundation

nonisolated enum ConnectorReadDiscovery {
    struct Surface: Sendable {
        var catalogID: String?
        var claudePrefix: String?
        var readTools: [String]?
    }

    @TaskLocal static var current: [String: Surface] = [:]

    static func withTools<T>(slugs: [String],
                             isolation: isolated (any Actor)? = #isolation,
                             _ operation: () async throws -> T) async rethrows -> T {
        #if DEBUG
        if FrontierRun.acceptanceRun != nil { return try await operation() }
        #endif
        let backend = ModelBackend.current
        let targets = Set(slugs.map(ConnectorRegistry.canonicalSlug)).filter {
            !$0.hasPrefix("direct-") && !$0.hasPrefix("hosted-") && current[$0] == nil
                && (backend != .chatgpt || ConnectorRegistry.server(for: $0)?.codexCatalogID?.isEmpty != false)
        }.sorted()
        guard !targets.isEmpty, ModelBackend.current.hasSubscriptionConnectors else {
            return try await operation()
        }
        let servers = targets.compactMap { ConnectorRegistry.server(for: $0) }
        let scope = targets.map { $0 + ":" + ConnectorRegistry.readOrigin(slug: $0, backend: backend) }.joined(separator: "|")
        let surfaces = await Cache.shared.resolve(scope: scope, backend: backend, servers: servers)
        let merged = current.merging(Dictionary(uniqueKeysWithValues: targets.map {
            ($0, surfaces[$0] ?? Surface())
        })) { _, live in live }
        return try await $current.withValue(merged) { try await operation() }
    }

    private actor Cache {
        static let shared = Cache()
        struct Entry {
            let expires: Date
            let task: Task<[String: Surface], Never>
        }
        var entries: [String: Entry] = [:]

        func resolve(scope: String, backend: ModelBackend,
                     servers: [ConnectorRegistry.ResolvedServer]) async -> [String: Surface] {
            if let entry = entries[scope], entry.expires > Date() { return await entry.task.value }
            entries = entries.filter { $0.value.expires > Date() }
            let task = Task { await discover(backend: backend, servers: servers) }
            entries[scope] = Entry(expires: Date().addingTimeInterval(60), task: task)
            return await task.value
        }
    }

    private static func discover(backend: ModelBackend,
                                 servers: [ConnectorRegistry.ResolvedServer]) async -> [String: Surface] {
        guard !servers.isEmpty else { return [:] }
        let binary = backend == .chatgpt ? CodexCLI.locateBinary() : ClaudeCLI.locateBinary()
        guard let binary else { return [:] }
        let process = MailProbeProcess(timeout: 15)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                defer { process.stop() }
                do {
                    let value: [String: Surface]
                    if backend == .chatgpt {
                        try process.start(binary: binary,
                            arguments: ["app-server", "-c", "features.apps=true", "-c", "mcp_servers={}"],
                            extraEnvironment: [:])
                        _ = try process.request(["method": "initialize", "params": [
                            "clientInfo": ["name": "sentient_connector_read", "version": "1.0"]]])
                        try process.send(["method": "initialized", "params": [:]])
                        var tools: [[String: Any]] = [], cursor: String?
                        for _ in 0..<20 {
                            var params: [String: Any] = ["detail": "toolsAndAuthOnly", "limit": 100]
                            if let cursor { params["cursor"] = cursor }
                            let page = try process.request(["method": "mcpServerStatus/list", "params": params])
                            for server in page["data"] as? [[String: Any]] ?? [] where server["name"] as? String == "codex_apps" {
                                tools += Array((server["tools"] as? [String: [String: Any]] ?? [:]).values)
                            }
                            cursor = page["nextCursor"] as? String
                            if cursor == nil { break }
                        }
                        value = codexSurfaces(tools, servers: servers)
                    } else {
                        let walls = servers.compactMap(\.claudeServerURL).map { ["serverUrl": $0] }
                        guard !walls.isEmpty else { continuation.resume(returning: [:]); return }
                        let settings = String(decoding: try JSONSerialization.data(withJSONObject: [
                            "allowedMcpServers": walls, "disableAllHooks": true]), as: UTF8.self)
                        try process.start(binary: binary, arguments: ["-p", "--input-format", "stream-json",
                            "--output-format", "stream-json", "--verbose", "--no-session-persistence",
                            "--setting-sources", "", "--disable-slash-commands", "--tools", "",
                            "--permission-mode", "dontAsk", "--settings", settings], extraEnvironment: ClaudeCLI.baseEnv)
                        _ = try process.request(["subtype": "initialize", "hooks": [:]], claude: true)
                        var live: [[String: Any]] = []
                        for attempt in 0..<5 {
                            let response = try process.request(["subtype": "mcp_status"], claude: true)
                            live = response["mcpServers"] as? [[String: Any]] ?? []
                            if !live.isEmpty && !live.contains(where: { $0["status"] as? String == "pending" }) { break }
                            if attempt < 4 { try process.pause() }
                        }
                        value = claudeSurfaces(live, servers: servers)
                    }
                    continuation.resume(returning: value)
                } catch {
                    Log("Connector read discovery unavailable: \(ErrorLabel(error))")
                    continuation.resume(returning: [:])
                }
            }
        }
    }

    static func codexSurfaces(_ tools: [[String: Any]], servers: [ConnectorRegistry.ResolvedServer]) -> [String: Surface] {
        var result: [String: Surface] = [:]
        for server in servers {
            var candidates = Set<String>()
            for tool in tools {
                guard let meta = tool["_meta"] as? [String: Any],
                      let id = meta["connector_id"] as? String, !id.isEmpty else { continue }
                let name = (meta["connector_name"] as? String).map(ConnectorCensus.slugify)
                if id == server.codexCatalogID || name.map(ConnectorRegistry.canonicalSlug) == server.slug {
                    candidates.insert(id)
                }
            }
            if let previous = server.codexCatalogID, candidates.contains(previous) {
                result[server.slug] = Surface(catalogID: previous)
            } else if candidates.count == 1 {
                result[server.slug] = Surface(catalogID: candidates.first)
            }
        }
        return result
    }

    static func claudeSurfaces(_ live: [[String: Any]], servers: [ConnectorRegistry.ResolvedServer]) -> [String: Surface] {
        var result: [String: Surface] = [:]
        for server in servers {
            guard let observed = live.first(where: {
                ($0["config"] as? [String: Any])?["url"] as? String == server.claudeServerURL
                    && $0["status"] as? String == "connected"
            }), let name = observed["name"] as? String,
                  let tools = observed["tools"] as? [[String: Any]], !tools.isEmpty else { continue }
            let prefix = "mcp__" + name.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression) + "__"
            let reviewed = Set(ConnectorRegistry.pack(forSlug: server.slug)?.readTools ?? [])
            let reads = tools.compactMap { tool -> String? in
                guard let name = tool["name"] as? String else { return nil }
                let hints = tool["annotations"] as? [String: Any] ?? [:]
                if hints["destructive"] as? Bool == true || hints["destructiveHint"] as? Bool == true { return nil }
                let readOnly = hints["readOnly"] as? Bool ?? hints["readOnlyHint"] as? Bool
                guard readOnly ?? reviewed.contains(name) else { return nil }
                // One Microsoft server carries independently selected Mail and Calendar sources.
                if Microsoft365Connector.contains(server.slug), !reviewed.contains(name) { return nil }
                return name.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
            }
            result[server.slug] = Surface(claudePrefix: prefix, readTools: reads)
        }
        return result
    }
}
