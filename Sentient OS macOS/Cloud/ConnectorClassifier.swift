//
//  ConnectorClassifier.swift
//  Sentient OS macOS
//
//  The three-way tool classifier (read / write / destructive) for detected connectors — the
//  safety inventory every run recipe consumes (read allows for KB reads, destructive denies for
//  user-fired runs). Claude engine only: on codex, safety is structural (catalog-id strips + the
//  read-only sandbox), so classification is unnecessary there and this is a clean no-op.
//
//  Key methods:
//   - ensureClassified(_:)  → the production entry: no-op off the Claude backend, cache-fresh
//                             check against the managed CLI version, else classify + persist.
//   - sweepComputerUseAttachables() → the idle-tick sweep over chips + detected connectors,
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

nonisolated enum ConnectorClassifier {

    // MARK: The classification core

    /// The rules every input source shares — tuning happens HERE only, against the Gmail
    /// ground-truth eval (zero write-as-read across three consecutive runs).
    private static let classificationRules = """
    Classify EVERY one of those tools into exactly one category, from its name and
    description:
    - "read": cannot change anything anywhere; only retrieves or computes.
    - "write": creates, sends, shares, moves, or modifies content, without
      permanently destroying anything.
    - "destructive": deletes, trashes, cancels, revokes, or overwrites existing
      content, or plausibly could.

    Be strict: doubt between read and write means "write"; doubt between write and
    destructive means "destructive". A missing or vague description is never "read".
    """

    private static let classifySchema = """
    {"type":"object","additionalProperties":false,"required":["tools"],"properties":{"tools":\
    {"type":"array","items":{"type":"object","additionalProperties":false,\
    "required":["name","category"],"properties":{"name":{"type":"string"},\
    "category":{"type":"string","enum":["read","write","destructive"]}}}}}}
    """

    private static let listSchema = """
    {"type":"object","additionalProperties":false,"required":["tools"],"properties":{"tools":\
    {"type":"array","items":{"type":"string"}}}}
    """

    /// The managed CLI version, fetched once per launch (`claude --version` is a subprocess).
    /// Launch-level freshness is right: drift arrives with CLI updates, which our own daily
    /// updater performs — the same posture as ClaudeCLI's cachedVersion.
    private static let cliVersion = Task { await ClaudeCLI.installedVersion() }

    // MARK: The production entry

    /// Classify a connector when there is no cache, or when the cached capture's CLI version
    /// differs from the installed managed CLI. Claude engine only — codex and custom backends
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
        guard ModelBackend.current == .claude else { return false }
        let version = await cliVersion.value ?? "unknown"
        if let cached = ConnectorRegistry.classification(for: slug), cached.cliVersion == version {
            return true
        }
        // Two attempts: the connector's first attach to a fresh run is occasionally transient
        // (field-observed 2026-08-29: a short reply naming no connector tools, gone on the next
        // spawn). One retry is cheap on the haiku tier; failing both leaves the connector
        // unclassified — the fail-closed contract holds either way.
        for attempt in 1...2 {
            do {
                let tools = try await classify(slug: slug)
                ConnectorRegistry.saveClassification(
                    .init(tools: tools, cliVersion: version, capturedAt: Date()), for: slug)
                logCounts(slug: slug, tools: tools)
                return true
            } catch {
                Log("classifier: \(slug) attempt \(attempt) \(ErrorLabel(error))")
                if attempt == 1 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        return false
    }

    // MARK: The attachables sweep (task 1.6)

    /// Classify everything a computer-use run could attach: the connected chip connectors
    /// (census-excluded, so no other production path ever classifies them) plus every detected
    /// claude-origin connector. Rides CodexSetup's 15-minute idle tick (first fire ~90 s after
    /// launch), so on a real user's Mac the fail-closed exclusions in
    /// ConnectorRegistry.computerUseAttachments are a minutes-long transient, not a resting
    /// state. Cache hits are free — the steady state is zero model runs — and a managed-CLI
    /// update re-classifies naturally through ensureClassified's version check. Serial on the
    /// haiku tier; a failure stays unclassified (fail-closed) and retries on the next tick.
    static func sweepComputerUseAttachables() async {
        guard ModelBackend.current == .claude else { return }
        var slugs: [String] = []
        if UserDefaults.standard.bool(forKey: "dbg.gmail.connected") { slugs.append("gmail") }
        if UserDefaults.standard.bool(forKey: "dbg.calendar.connected") { slugs.append("google-calendar") }
        slugs += ConnectorCensus.cached(for: .claude).map(\.slug)
        for slug in slugs { await ensureClassified(slug: slug) }
    }

    // MARK: The run (the Claude-context input source)

    /// One classification run: haiku tier, low effort, the connector's server allowlisted so
    /// ONLY its tools are in context, dontAsk with zero allow rules (the run makes no tool
    /// calls — listing your own tools needs no approval), structured output.
    static func classify(slug: String) async throws -> [ConnectorRegistry.ClassifiedTool] {
        guard let identity = ConnectorRegistry.claudeIdentity(slug: slug) else {
            throw CodexCLI.CLIError.badEnvelope("no claude identity for connector")
        }
        let prompt = """
        You can see tools from the "\(identity.name)" connector in your context (named
        \(identity.toolPrefix)...). Do not call any tool.

        \(classificationRules)

        Reply with JSON only:
        {"tools":[{"name":"<full name>","category":"read"|"write"|"destructive"}, ...]}
        Include every connector tool exactly once; exclude built-ins and other
        connectors' tools.
        """
        let envelope = try await run(prompt: prompt, schema: classifySchema, slug: slug)
        return try parse(envelope.jsonResult, prefix: identity.toolPrefix)
    }

    /// The lab's inventory probe: the identical recipe, but only LISTS names — independent of
    /// classification quality, so a classify miss shows up as a diff against this.
    static func listTools(slug: String) async throws -> [String] {
        guard let identity = ConnectorRegistry.claudeIdentity(slug: slug) else {
            throw CodexCLI.CLIError.badEnvelope("no claude identity for connector")
        }
        let prompt = """
        You can see tools from the "\(identity.name)" connector in your context (named
        \(identity.toolPrefix)...). Do not call any tool.

        Reply with JSON only:
        {"tools":["<full name>", ...]}
        Include every connector tool's full name exactly once; exclude built-ins and
        other connectors' tools.
        """
        let envelope = try await run(prompt: prompt, schema: listSchema, slug: slug)
        struct Reply: Codable { let tools: [String] }
        guard let data = envelope.jsonResult.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw CodexCLI.CLIError.badEnvelope("tool list did not parse")
        }
        return reply.tools.filter { $0.hasPrefix(identity.toolPrefix) }
    }

    private static func run(prompt: String, schema: String,
                            slug: String) async throws -> CodexCLI.Envelope {
        var invocation = CodexCLI.Invocation(prompt: prompt)
        invocation.feature = "classify"
        invocation.model = .gpt56luna          // → haiku on the Claude tier map
        invocation.effort = .low
        invocation.sandbox = .readOnly
        invocation.webSearch = false
        invocation.timeout = 300
        invocation.mcpAttachServer = slug      // the ATTACH recipe: walled in alone, zero allows
        invocation.outputSchema = schema
        // trigger=probe: a failed classification is a quiet retry-later, never filed as an
        // analysis failure (the census warm run's posture).
        return try await CodexTrigger.$current.withValue(.probe) {
            try await FrontierRun.run(invocation)
        }
    }

    // MARK: Validation (fail-closed)

    /// Decode, keep only names carrying the connector's prefix (built-ins and other connectors'
    /// tools excluded), dedupe on name (the first verdict wins), refuse an empty result.
    static func parse(_ json: String,
                      prefix: String) throws -> [ConnectorRegistry.ClassifiedTool] {
        struct Reply: Codable { let tools: [ConnectorRegistry.ClassifiedTool] }
        guard let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw CodexCLI.CLIError.badEnvelope("classification did not parse")
        }
        var seen = Set<String>()
        let tools = reply.tools.filter { $0.name.hasPrefix(prefix) && seen.insert($0.name).inserted }
        guard !tools.isEmpty else {
            // Counts only (structural): distinguishes an empty reply (the connector never
            // attached to the run) from unprefixed names (the model answered with bare names).
            throw CodexCLI.CLIError.badEnvelope(
                "classification kept 0 of \(reply.tools.count) returned tools")
        }
        return tools
    }

    /// Counts and category totals only — never tool descriptions or reasoning.
    private static func logCounts(slug: String, tools: [ConnectorRegistry.ClassifiedTool]) {
        let reads = tools.count(where: { $0.category == .read })
        let writes = tools.count(where: { $0.category == .write })
        let destructive = tools.count(where: { $0.category == .destructive })
        Log("classifier: \(slug) ok tools=\(tools.count) reads=\(reads) writes=\(writes) destructive=\(destructive)")
    }
}
