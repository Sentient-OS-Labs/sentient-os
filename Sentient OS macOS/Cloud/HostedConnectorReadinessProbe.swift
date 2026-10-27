// Explicit, model-free hosted connection verification. Reads only native connection/tool
// metadata; no content tools, model prompts, OAuth changes or contact collection are performed.
import Foundation

nonisolated enum HostedConnectorReadinessProbe {
    enum Failure: Error { case unavailable, unverified, invalidInventory }
    #if DEBUG
    @TaskLocal static var onMetadataShape: (@Sendable ([String: Bool]) -> Void)?
    #endif

    static func verify(slug: String, backend: ModelBackend) async throws -> ConnectorCensus.DetectedConnector {
        guard let pack = ConnectorRegistry.pack(forSlug: slug) else { throw Failure.unverified }
        if backend == .claude { return try await verifyClaude(slug: slug, pack: pack) }
        guard backend == .chatgpt, let binary = CodexCLI.locateBinary(),
              let reviewedReads = pack.codexReadTools, !reviewedReads.isEmpty else { throw Failure.unavailable }
        #if DEBUG
        let shapeObserver = onMetadataShape // GCD does not inherit Swift TaskLocal values.
        #endif
        let session = MailProbeProcess()
        return try await withTaskCancellationHandler {
            let record: ConnectorCensus.DetectedConnector = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    defer { session.stop() }
                    do {
                        try session.start(binary: binary,
                            arguments: ["app-server", "-c", "features.apps=true", "-c", "mcp_servers={}"], extraEnvironment: [:])
                        _ = try session.request(["method": "initialize", "params": [
                            "clientInfo": ["name": "sentient_connection_check", "version": "1.0"]]])
                        try session.send(["method": "initialized", "params": [:]])
                        // Apps may attach after initialize. Poll metadata only, within the
                        // transport's fixed deadline, and require complete pagination.
                        for attempt in 0..<8 {
                            var pages: [[String: Any]] = [], cursor: String?
                            for page in 0..<20 {
                                var params: [String: Any] = ["detail": "toolsAndAuthOnly", "limit": 100]
                                if let cursor { params["cursor"] = cursor }
                                let result = try session.request(["method": "mcpServerStatus/list", "params": params])
                                guard result["data"] is [[String: Any]] else { throw Failure.invalidInventory }
                                pages.append(result)
                                cursor = result["nextCursor"] as? String
                                if cursor == nil { break }
                                if page == 19 { throw Failure.invalidInventory }
                            }
                            let catalogID = pack.codexCatalogID ?? ConnectorRegistry.server(for: slug)?.codexCatalogID
                            #if DEBUG
                            shapeObserver?(codexShape(pages: pages, slug: slug, expectedCatalogID: catalogID, reviewedReads: Set(reviewedReads)))
                            #endif
                            if let identifier = codexLinkedCatalog(pages: pages, slug: slug,
                                expectedCatalogID: catalogID, reviewedReads: Set(reviewedReads)) {
                                continuation.resume(returning: .init(slug: slug, displayName: pack.displayName,
                                    origin: .chatgpt, serverURL: nil, catalogID: identifier, iconPath: nil,
                                    healthy: true, lastSeen: .now, readinessVerified: true))
                                return
                            }
                            if attempt < 7 { try session.pause() }
                        }
                        throw Failure.unverified
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return record
        } onCancel: { session.stop() }
    }

    private static func verifyClaude(slug: String, pack: ConnectorRegistry.CuratedConnector) async throws -> ConnectorCensus.DetectedConnector {
        guard let binary = ClaudeCLI.locateBinary(), let url = pack.claudeServerURL,
              let reads = pack.readTools, !reads.isEmpty else { throw Failure.unavailable }
        #if DEBUG
        let shapeObserver = onMetadataShape
        #endif
        let settings = String(decoding: try JSONSerialization.data(withJSONObject: [
            "allowedMcpServers": [["serverUrl": url]], "disableAllHooks": true]), as: UTF8.self)
        let session = MailProbeProcess()
        return try await withTaskCancellationHandler {
            let record: ConnectorCensus.DetectedConnector = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    defer { session.stop() }
                    do {
                        try session.start(binary: binary, arguments: ["-p", "--input-format", "stream-json",
                            "--output-format", "stream-json", "--verbose", "--no-session-persistence",
                            "--setting-sources", "", "--disable-slash-commands", "--tools", "",
                            "--permission-mode", "dontAsk", "--settings", settings], extraEnvironment: ClaudeCLI.baseEnv)
                        _ = try session.request(["subtype": "initialize", "hooks": [:]], claude: true)
                        for attempt in 0..<15 {
                            let status = try session.request(["subtype": "mcp_status"], claude: true)
                            #if DEBUG
                            shapeObserver?(claudeShape(status: status, expectedURL: url, reviewedReads: Set(reads)))
                            #endif
                            if claudeLinkedSource(status: status, expectedURL: url, reviewedReads: Set(reads)) {
                                continuation.resume(returning: .init(slug: slug, displayName: pack.displayName,
                                    origin: .claude, serverURL: url, catalogID: nil, iconPath: nil,
                                    healthy: true, lastSeen: .now, readinessVerified: true))
                                return
                            }
                            if attempt < 14 { try session.pause() }
                        }
                        throw Failure.unverified
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return record
        } onCancel: { session.stop() }
    }

    static func claudeLinkedSource(status: [String: Any], expectedURL: String, reviewedReads: Set<String>) -> Bool {
        (status["mcpServers"] as? [[String: Any]] ?? []).contains { server in
            guard server["status"] as? String == "connected", let config = server["config"] as? [String: Any],
                  config["url"] as? String == expectedURL,
                  let link = config["id"] as? String, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  link.count <= 256 else { return false }
            return (server["tools"] as? [[String: Any]] ?? []).contains {
                ($0["name"] as? String).map(reviewedReads.contains) == true
            }
        }
    }

    /// Link metadata is supplied by the native provider, never by a model. A catalog listing,
    /// an unrelated service, or tools without linked-account evidence cannot certify readiness.
    static func codexLinkedCatalog(pages: [[String: Any]], slug: String, expectedCatalogID: String?,
                                   reviewedReads: Set<String>) -> String? {
        var matches = Set<String>()
        for page in pages {
            for server in page["data"] as? [[String: Any]] ?? [] where server["name"] as? String == "codex_apps" {
                for tool in (server["tools"] as? [String: [String: Any]] ?? [:]).values {
                    guard let meta = tool["_meta"] as? [String: Any],
                          let identifier = meta["connector_id"] as? String,
                          ConnectorRegistry.isValidCodexCatalogID(identifier),
                          let link = meta["link_id"] as? String, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, link.count <= 256 else { continue }
                    let sourceMatches = expectedCatalogID.map { $0 == identifier }
                        ?? metadataName(meta["connector_name"] as? String, matches: slug)
                    guard let wireName = tool["name"] as? String, !wireName.isEmpty else { continue }
                    let toolName = tool["title"] as? String
                        ?? wireName.split(separator: ".").last.map(String.init)
                    guard sourceMatches, let toolName, reviewedReads.contains(toolName) else { continue }
                    matches.insert(identifier)
                }
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    #if DEBUG
    /// Structure only. Never return the raw inventory, account identity, link ID, email or tool payload.
    private static func codexShape(pages: [[String: Any]], slug: String, expectedCatalogID: String?, reviewedReads: Set<String>) -> [String: Bool] {
        let servers = pages.flatMap { $0["data"] as? [[String: Any]] ?? [] }.filter { $0["name"] as? String == "codex_apps" }
        let tools = servers.flatMap { Array(($0["tools"] as? [String: [String: Any]] ?? [:]).values) }
        let matched = tools.filter { tool in
            guard let meta = tool["_meta"] as? [String: Any], let identifier = meta["connector_id"] as? String else { return false }
            return expectedCatalogID.map { $0 == identifier } ?? metadataName(meta["connector_name"] as? String, matches: slug)
        }
        return ["server_present": !servers.isEmpty, "tools_dictionary_present": servers.contains { $0["tools"] is [String: [String: Any]] },
            "service_match": !matched.isEmpty,
            "link_id_string_present": matched.contains { ($0["_meta"] as? [String: Any])?["link_id"] is String },
            "linked_account_evidence": matched.contains {
                guard let link = ($0["_meta"] as? [String: Any])?["link_id"] as? String else { return false }
                return !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && link.count <= 256
            },
            "reviewed_read_tool_match": matched.contains {
                let name = $0["title"] as? String ?? ($0["name"] as? String)?.split(separator: ".").last.map(String.init)
                return name.map(reviewedReads.contains) == true
            }]
    }
    private static func claudeShape(status: [String: Any], expectedURL: String, reviewedReads: Set<String>) -> [String: Bool] {
        let servers = status["mcpServers"] as? [[String: Any]] ?? []
        let matched = servers.filter { ($0["config"] as? [String: Any])?["url"] as? String == expectedURL }
        return ["server_list_present": status["mcpServers"] is [[String: Any]], "service_match": !matched.isEmpty,
            "connected_status": matched.contains { $0["status"] as? String == "connected" },
            "linked_account_evidence": matched.contains {
                guard let link = ($0["config"] as? [String: Any])?["id"] as? String else { return false }
                return !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && link.count <= 256
            },
            "reviewed_read_tool_match": matched.contains {
                ($0["tools"] as? [[String: Any]] ?? []).contains { ($0["name"] as? String).map(reviewedReads.contains) == true }
            }]
    }
    #endif

    private static func metadataName(_ name: String?, matches slug: String) -> Bool {
        guard let name else { return false }
        let normalized = ConnectorCensus.slugify(name)
        if normalized == slug { return true }
        // These are provider service labels, not account names or model-generated guesses.
        let aliases: [String: Set<String>] = ["google-drive": ["drive"], "google-calendar": ["calendar"],
            "outlook-mail": ["outlook", "outlook-email", "microsoft-outlook-email"]]
        return aliases[slug]?.contains(normalized) == true
    }
}
