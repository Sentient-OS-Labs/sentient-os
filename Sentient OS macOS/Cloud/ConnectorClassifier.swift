//
//  ConnectorClassifier.swift
//  Sentient OS macOS
//
//  The three-way tool classifier (read / write / destructive) for detected connectors — the
//  safety inventory the ACTION recipes consume (destructive denies for user-fired and
//  computer-use runs, the fired-task gate; KB reads are curated-only and never ride the
//  classifier). Claude engine only: on codex, safety is structural (catalog-id strips + the
//  read-only sandbox), so classification is unnecessary there and this is a clean no-op.
//
//  Key methods:
//   - ensureClassified(_:)  → the production entry: no-op off the Claude backend, cache-fresh
//                             check against the managed CLI version AND a weekly TTL (server-
//                             side surfaces drift on their own), else classify + persist.
//   - sweepActionConnectors() → the idle-tick sweep over chips + detected connectors,
//                             so the computer-use attach set is classified on real machines.
//   - classify(slug:)       → one model run: the connector walled in alone, zero tool calls,
//                             structured JSON out. Fail-closed: anything that won't parse leaves
//                             the connector UNCLASSIFIED (no read allows anywhere).
//   - listTools(slug:)      → the lab's inventory probe (same recipe, names only).
//
//  Step D seam: the classification CORE (the categories, the rules text, the cache shape,
//  ensureClassified's contract) is separate from its INPUT SOURCE (today: the tools visible in
//  a Claude run's own context). Step D feeds the same core a natively fetched tools/list JSON
//  as prompt text, which works on any engine including BYOM. One core, two feeders.
//
//  Doc: Sources/Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation
import os

nonisolated enum ConnectorClassifier {

    // MARK: The classification core

    /// The rules every input source shares — tuning happens HERE only, against the Gmail
    /// ground-truth eval (zero write-as-read across three consecutive runs).
    static let classificationRules = """
    Classify EVERY one of those tools into exactly one category, from its name and
    description and complete input schema (including optional and nested fields):
    - "read": cannot change anything anywhere; only retrieves or computes.
    - "write": creates new content, sends, shares, moves, or changes metadata, without
      any mode that removes or replaces existing content or access.
    - "destructive": deletes, trashes, cancels, revokes, or overwrites existing
      content, or plausibly could.

    Classify the whole capability, not a benign example call. An optional existing ID,
    replacement body/description, remove/delete array, revoke/unshare mode or cancel/close
    mode makes a mixed tool destructive. A confirmation UI or deprecated status does not
    remove that capability. Reversible deletion, archival and replacement are still destructive.
    Be strict: doubt between read and write means "write"; doubt between write and
    destructive means "destructive". A missing or vague description is never "read".
    """

    static func classificationSchema(inventory: [String]) throws -> String {
        guard !inventory.isEmpty, Set(inventory).count == inventory.count else {
            throw CodexCLI.CLIError.badEnvelope("invalid native classification inventory")
        }
        let item: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["name", "category"],
            "properties": ["name": ["type": "string", "enum": inventory.sorted()],
                           "category": ["type": "string", "enum": ["read", "write", "destructive"]]]]
        let entries: [String: Any] = ["type": "array", "minItems": inventory.count, "maxItems": inventory.count, "items": item]
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["tools"],
                                   "properties": ["tools": entries]]
        return String(decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
    }

    private static let listSchema = """
    {"type":"object","additionalProperties":false,"required":["tools"],"properties":{"tools":\
    {"type":"array","items":{"type":"string"}}}}
    """

    /// Synchronous policy queries only trust a version observed for the current executable.
    /// A replaced binary invalidates the stamp immediately, before the next idle refresh.
    private static let versionStamp = OSAllocatedUnfairLock(initialState: (signature: "", version: Optional<String>.none))
    static let captureTTL: TimeInterval = 7 * 24 * 3600

    private static func binarySignature() -> String? {
        guard let path = ClaudeCLI.locateBinary() else { return nil }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
        return "\(url.path):\(modified.timeIntervalSince1970):\(size)"
    }

    static var currentCLIVersion: String? {
        guard let signature = binarySignature() else { return nil }
        return versionStamp.withLock { $0.signature == signature ? $0.version : nil }
    }

    @discardableResult
    static func refreshCLIVersion() async -> String? {
        if let version = currentCLIVersion { return version }
        guard let signature = binarySignature(), let version = await ClaudeCLI.installedVersion(),
              binarySignature() == signature else { return nil }
        versionStamp.withLock { $0 = (signature, version) }
        return version
    }

    static func isFresh(_ capture: ConnectorRegistry.Classification, slug: String,
                        version: String, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(capture.capturedAt)
        guard let inventory = capture.verifiedInventory else { return false }
        return capture.cliVersion == version && age >= 0 && age < captureTTL
            && (try? validate(capture.tools, slug: slug, inventory: inventory)) != nil
    }

    /// Known reviewed categories validate captures; runtime denies still come exclusively
    /// from the full classified inventory. Drive's reviewed eleven-tool surface is required;
    /// additions or removals need another review before its action policy can activate.
    static func validate(_ tools: [ConnectorRegistry.ClassifiedTool], slug: String,
                         inventory: [String]? = nil) throws {
        if slug == "slack" { try SlackConnector.validateClassification(tools) }
        if Microsoft365Connector.contains(slug) { try Microsoft365Connector.validateClassification(tools) }
        guard let identity = ConnectorRegistry.claudeIdentity(slug: slug), !tools.isEmpty,
              tools.allSatisfy({ normalizedName($0.name, prefix: identity.toolPrefix) == $0.name }),
              Set(tools.map(\.name)).count == tools.count else {
            throw CodexCLI.CLIError.badEnvelope("classification has an invalid or duplicate inventory")
        }
        if let inventory {
            guard !inventory.isEmpty, Set(inventory).count == inventory.count,
                  Set(inventory) == Set(tools.map(\.name)) else {
                throw CodexCLI.CLIError.badEnvelope("classification does not match the observed inventory")
            }
        }
        let prefix = identity.toolPrefix
        let reads = Set(ConnectorRegistry.pack(forSlug: slug)?.readTools ?? [])
        let names = Set(tools.map { String($0.name.dropFirst(prefix.count)) })
        guard reads.isSubset(of: names) else {
            throw CodexCLI.CLIError.badEnvelope("classification omitted a curated read tool")
        }
        let knownDestructive = reviewedDestructiveTools(slug: slug)
        for tool in tools where knownDestructive.contains(String(tool.name.dropFirst(prefix.count))) {
            guard tool.category == .destructive else {
                throw CodexCLI.CLIError.badEnvelope("classification did not deny a reviewed destructive tool")
            }
        }
        guard slug == "google-drive" else { return }
        let required = reads.union(["copy_file", "create_file", "share_file", "update_file", "trash_file"])
        guard required.isSubset(of: names) else {
            throw CodexCLI.CLIError.badEnvelope("classification omitted a reviewed Drive tool")
        }
        for tool in tools {
            let name = String(tool.name.dropFirst(prefix.count))
            if reads.contains(name) {
                guard tool.category == .read else {
                    throw CodexCLI.CLIError.badEnvelope("classification disagrees with a reviewed Drive read")
                }
            } else if tool.category == .read {
                throw CodexCLI.CLIError.badEnvelope("classification contains an unreviewed Drive read")
            }
        }
    }

    /// Whole-tool exclusions from reviewed mutation modes. These also invalidate older
    /// cached classifications through isFresh; a benign argument subset cannot bypass them.
    static func reviewedDestructiveTools(slug: String) -> Set<String> {
        switch slug {
        case "google-drive": return ["trash_file", "delete_file"]
        case "gmail": return ["trash_message", "trash_thread", "delete_label", "delete_filter", "mark_message_spam", "mark_thread_spam"]
        case "google-calendar": return ["delete_event"]
        case "asana": return ["delete_task", "update_tasks", "update_project", "save_project_changes_confirm",
                              "save_task_changes_confirm", "create_project_confirm_populate"]
        case "linear": return ["delete_attachment", "delete_comment", "delete_diff_comment", "delete_status_update",
            "retire_issue_label", "retire_project_label", "unshare_issue", "merge_diff", "update_diff",
            "save_comment", "save_diff_comment", "save_document", "save_issue", "save_issue_label",
            "save_milestone", "save_project", "save_project_label", "save_release", "save_release_note", "save_status_update"]
        default: return []
        }
    }

    // MARK: The production entry

    /// Classify a connector when there is no cache, when the cached capture's CLI version
    /// differs from the installed managed CLI, or when the capture has outlived the weekly
    /// TTL. Claude engine only — codex and custom backends
    /// are a clean no-op (structural safety differs there; see the recipes table). A failed or
    /// unparseable run leaves the connector unclassified: no read allows, excluded from
    /// computer-use attachment (task 1.6's rule). Never fail open.
    /// Returns whether a fresh classification exists when the call finishes.
    @discardableResult
    static func ensureClassified(_ connector: ConnectorCensus.DetectedConnector) async -> Bool {
        await ensureClassified(slug: connector.slug)
    }

    @discardableResult
    static func ensureClassified(slug: String) async -> Bool {
        if let direct = DirectMCPStore.connection(slug) { return direct.usable }
        guard ModelBackend.current == .claude else { return false }
        guard let version = await refreshCLIVersion() else { return false }
        if let cached = ConnectorRegistry.classification(for: slug), isFresh(cached, slug: slug, version: version) {
            return true
        }
        // Retain an older record for diagnostics, but isClassified excludes it from actions.
        // One retry handles transient first-attach failures without accepting a partial surface.
        for attempt in 1...2 {
            do {
                try Task.checkCancellation()
                let inventory = try await listTools(slug: slug)
                let tools = try await classify(slug: slug, inventory: inventory)
                try validate(tools, slug: slug, inventory: inventory)
                ConnectorRegistry.saveClassification(
                    .init(tools: tools, cliVersion: version, capturedAt: Date(), verifiedInventory: inventory), for: slug)
                logCounts(slug: slug, tools: tools)
                return true
            } catch {
                if Task.isCancelled || error is CancellationError { return false }
                Log("classifier: \(ConnectorRegistry.telemetrySlug(slug)) attempt \(attempt) \(ErrorLabel(error))")
                if attempt == 1 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        return false
    }

    // MARK: The attachables sweep (task 1.6)

    /// Classify connected hosted services for dedicated Claude connector actions and cards.
    /// Runs on the idle tick; cache hits are free and a CLI update refreshes the classification.
    /// Failures remain unclassified and retry on a later tick.
    static func sweepActionConnectors() async {
        guard ModelBackend.current == .claude else { return }
        var slugs: [String] = []
        if UserDefaults.standard.bool(forKey: "dbg.gmail.connected") { slugs.append("gmail") }
        if UserDefaults.standard.bool(forKey: "dbg.calendar.connected") { slugs.append("google-calendar") }
        slugs += ConnectorCensus.cached(for: .claude)
            .filter { !ConnectorCensus.dedicatedSourceSlugs.contains($0.slug) }.map(\.slug)
        for slug in slugs { await ensureClassified(slug: slug) }
    }

    // MARK: The run (the Claude-context input source)

    /// One classification run: haiku tier, low effort, the connector's server allowlisted so
    /// ONLY its tools are in context, dontAsk with no connector allows. The readiness
    /// builtin may wait for schemas; no connector operation is executed. Structured output.
    static func classify(slug: String, inventory: [String]) async throws -> [ConnectorRegistry.ClassifiedTool] {
        guard let identity = ConnectorRegistry.claudeIdentity(slug: slug) else {
            throw CodexCLI.CLIError.badEnvelope("no claude identity for connector")
        }
        let prompt = """
        You can see tools from the "\(identity.name)" connector in your context (named
        \(identity.toolPrefix)...). Do not call any connector tool. If the server is still connecting,
        use WaitForMcpServers when available before inspecting its tools or reporting an empty list.
        Its configured server name is "claude.ai \(identity.name)"; keep that full name when waiting.
        List only actual declared tool names, never names inferred from descriptions or capabilities.

        The native connected-server inventory below is the complete name list for this run.
        Classify all \(inventory.count) names exactly once, including deprecated/UI-only tools.
        Do not replace current versioned names with aliases or names from descriptions.
        NATIVE INVENTORY: \(inventory.sorted().joined(separator: ", "))

        \(classificationRules)

        Reviewed whole-tool exclusions for this connector: \(reviewedDestructiveTools(slug: slug).sorted().joined(separator: ", ")).
        Every listed name, when present, must be destructive even if another mode only creates
        new content. Never downgrade an exclusion based on the example task or a confirmation step.

        \(slug == "gmail" ? "Reviewed Gmail policy: trash_message, trash_thread, delete_label, delete_filter, mark_message_spam and mark_thread_spam must be destructive when present. Moving mail to spam is treated like trash, even though it is reversible." : "")
        \(slug == "slack" ? SlackConnector.classificationGuidance : "")
        \(Microsoft365Connector.contains(slug) ? "Microsoft 365 clarification: outlook_update_draft replaces existing body/content and is destructive. outlook_update_event can remove attendees and send cancellations; outlook_respond_to_event includes decline/removal; sharepoint_upload_file supports replacement. All are destructive. Inspect the complete Microsoft 365 inventory, including non-mail tools." : "")

        Reply with JSON only:
        {"tools":[{"name":"<full name>","category":"read"|"write"|"destructive"}, ...]}
        Include every connector tool exactly once; exclude built-ins and other
        connectors' tools.
        """
        let envelope = try await run(prompt: prompt, schema: try classificationSchema(inventory: inventory), slug: slug)
        let tools = try parse(envelope.jsonResult, prefix: identity.toolPrefix)
        try validate(tools, slug: slug, inventory: inventory)
        return tools
    }

    /// The lab's inventory probe: the identical recipe, but only LISTS names — independent of
    /// classification quality, so a classify miss shows up as a diff against this.
    static func listTools(slug: String) async throws -> [String] {
        guard let identity = ConnectorRegistry.claudeIdentity(slug: slug) else {
            throw CodexCLI.CLIError.badEnvelope("no claude identity for connector")
        }
        let prompt = """
        You can see tools from the "\(identity.name)" connector in your context (named
        \(identity.toolPrefix)...). Do not call any connector tool. If the server is still connecting,
        use WaitForMcpServers when available before inspecting its tools or reporting an empty list.
        Its configured server name is "claude.ai \(identity.name)"; keep that full name when waiting.
        List only actual declared tool names, never names inferred from descriptions or capabilities.

        Reply with JSON only:
        {"tools":["<full name>", ...]}
        Include every connector tool's full name exactly once; exclude built-ins and
        other connectors' tools.
        """
        for _ in 0..<2 {
            let envelope = try await run(prompt: prompt, schema: listSchema, slug: slug)
            if let names = nativeInventory(raw: envelope.raw, prefix: identity.toolPrefix,
                                           serverName: "claude.ai " + identity.name) { return names }
        }
        throw CodexCLI.CLIError.badEnvelope("native connector inventory is not ready")
    }

    /// Classification must cover the CLI's actual attached surface, not another model's
    /// recollection of it. Pending or missing init snapshots cannot certify completeness.
    static func nativeInventory(raw: String, prefix: String, serverName: String) -> [String]? {
        for line in raw.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  event["type"] as? String == "system", event["subtype"] as? String == "init",
                  let servers = event["mcp_servers"] as? [[String: Any]],
                  servers.contains(where: { $0["name"] as? String == serverName && $0["status"] as? String == "connected" }),
                  let tools = event["tools"] as? [String] else { continue }
            let names = tools.filter { $0.hasPrefix(prefix) }
            guard !names.isEmpty, Set(names).count == names.count,
                  names.allSatisfy({ normalizedName($0, prefix: prefix) == $0 }) else { return nil }
            return names.sorted()
        }
        return nil
    }

    private static func run(prompt: String, schema: String,
                            slug: String) async throws -> CodexCLI.Envelope {
        var invocation = CodexCLI.Invocation(prompt: prompt)
        invocation.feature = "classify"
        invocation.model = .gpt6luna          // → haiku on the Claude tier map
        // Slack's mixed-mode tools repeatedly confused the light-tier inventory/classifier.
        // This infrequent policy check uses Sonnet; knowledge reads keep their own model tier.
        if slug == "slack" || Microsoft365Connector.contains(slug) { invocation.claudeModel = .sonnet }
        invocation.effort = .low
        invocation.sandbox = .readOnly
        invocation.webSearch = false
        invocation.timeout = 300
        invocation.mcpAttachServer = slug      // the ATTACH recipe: walled in alone, zero allows
        invocation.connectorOnlyRead = true
        invocation.outputSchema = schema
        // trigger=probe: a failed classification is a quiet retry-later, never filed as an
        // analysis failure (the census warm run's posture).
        return try await CodexTrigger.$current.withValue(.probe) {
            let result = try await FrontierRun.run(invocation)
            #if DEBUG
            if ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == "connectorlab",
               let path = ProcessInfo.processInfo.environment["LAB_CLASSIFICATION_OUTPUT"] {
                try result.raw.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            }
            #endif
            return result
        }
    }

    // MARK: Validation (fail-closed)

    /// Normalize scoped/bare MCP names, exclude other namespaces and builtins, and reject
    /// conflicting duplicate verdicts. Validation then checks the independent inventory.
    static func parse(_ json: String,
                      prefix: String) throws -> [ConnectorRegistry.ClassifiedTool] {
        struct Reply: Codable { let tools: [ConnectorRegistry.ClassifiedTool] }
        guard let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw CodexCLI.CLIError.badEnvelope("classification did not parse")
        }
        var known: [String: ConnectorRegistry.ToolCategory] = [:]
        for tool in reply.tools {
            guard let name = normalizedName(tool.name, prefix: prefix) else { continue }
            if let previous = known[name], previous != tool.category {
                throw CodexCLI.CLIError.badEnvelope("classification contains conflicting duplicate verdicts")
            }
            known[name] = tool.category
        }
        let tools = known.keys.sorted().map { ConnectorRegistry.ClassifiedTool(name: $0, category: known[$0]!) }
        guard !tools.isEmpty else { throw CodexCLI.CLIError.badEnvelope("classification has no matching names") }
        return tools
    }

    private static func normalizedName(_ name: String, prefix: String) -> String? {
        if name.hasPrefix(prefix) {
            let bare = String(name.dropFirst(prefix.count))
            return bare.range(of: "^[A-Za-z_][A-Za-z0-9_./-]*\\z", options: .regularExpression) == nil ? nil : name
        }
        // MCP's server supplies bare snake-case names. Qualifying those with the pinned
        // server prefix is lossless; never rewrite a name already in another namespace.
        guard !name.hasPrefix("mcp__"),
              name.range(of: "^[a-z][a-z0-9_]*\\z", options: .regularExpression) != nil else { return nil }
        return prefix + name
    }

    /// Counts and category totals only — never tool descriptions or reasoning.
    private static func logCounts(slug: String, tools: [ConnectorRegistry.ClassifiedTool]) {
        let reads = tools.count(where: { $0.category == .read })
        let writes = tools.count(where: { $0.category == .write })
        let destructive = tools.count(where: { $0.category == .destructive })
        Log("classifier: \(ConnectorRegistry.telemetrySlug(slug)) ok tools=\(tools.count) reads=\(reads) writes=\(writes) destructive=\(destructive)")
    }
}
