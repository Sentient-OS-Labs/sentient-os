//
//  ConnectorLab.swift
//  Sentient OS macOS
//
//  The connector-lab harness: exercises the real ConnectorCensus, ConnectorRegistry, and
//  ConnectorClassifier against the real machine, headless. Grows across tasks 1.2 / 1.4 / 1.5
//  (tool dumps, classification, trial runs) and is deleted at Step 4.
//
//  Run:  SENTIENT_SELFTEST=connectorlab LAB_CMD=census  "<Debug>/Sentient OS.app/Contents/MacOS/Sentient OS"
//  Commands: census (both engines, explicitly) · parse (canned strings) · warm (the codex warm
//  run) · registry (pure pack/query checks) · tools (inventory dump, LAB_SLUG) · classify (the
//  three-way run + ground-truth eval, LAB_SLUG + LAB_RUNS) · cache (hit / version-bump / re-run)
//
//  Both listers are called BY NAME rather than through ConnectorCensus.list(), so testing an
//  engine never mutates the user's live `model.backend` setting (self-tests share the real
//  UserDefaults — flipping it would move the running app's engine, and a crash would leave it
//  flipped).
//
//  Doc: Documentation - General - Self-Testing (Eval Harness).md
//

import Foundation

enum ConnectorLab {

    static func run() async {
        let command = ProcessInfo.processInfo.environment["LAB_CMD"] ?? "census"
        Log("=== connector-lab: \(command) ===")
        switch command {
        case "census":   await census()
        case "parse":    parse()
        case "warm":     await warm()
        case "registry": registry()
        case "tools":    await tools()
        case "classify": await classify()
        case "cache":    await cache()
        default:
            Log("unknown LAB_CMD '\(command)' (census | parse | warm | registry | tools | classify | cache)")
        }
    }

    private static var labSlug: String {
        ProcessInfo.processInfo.environment["LAB_SLUG"] ?? "google-drive"
    }

    /// The classifier rides FrontierRun (which dispatches on the live backend), so these
    /// commands need the Claude engine live. The lab never flips `model.backend` itself.
    private static func requireClaudeBackend(_ what: String) -> Bool {
        guard ModelBackend.current == .claude else {
            Log("skipped: \(what) rides FrontierRun, which dispatches on the live backend — "
                + "switch Sentient to the Claude engine (Settings → Frontier Model) to exercise "
                + "it (currently \(ModelBackend.current.rawValue)). This skip IS the no-op the "
                + "classifier guarantees on non-Claude backends.")
            return false
        }
        return true
    }

    // MARK: census

    private static func census() async {
        Log("live backend: \(ModelBackend.current.rawValue)")

        Log("\n-- claude (`claude mcp list`) --")
        let claude = await ConnectorCensus.listClaude()
        dump(claude)

        Log("\n-- codex (plugins cache on disk) --")
        let codex = ConnectorCensus.listCodex()
        dump(codex)

        Log("\n-- list() for the live backend, then the persisted re-read --")
        let live = await ConnectorCensus.list()
        dump(live)
        if let origin = ConnectorCensus.DetectedConnector.Origin(backend: ModelBackend.current) {
            let cached = ConnectorCensus.cached(for: origin)
            Log("cached(for: \(origin.rawValue)) → \(cached.count) connector(s), "
                + "matches live: \(cached.map(\.slug) == live.map(\.slug))")
        } else {
            Log("cached: n/a (a custom backend has no connector origin)")
        }

        // The cross-engine identity that every later key hangs off: the same connector linked on
        // both accounts must normalize to ONE slug.
        let shared = Set(claude.map(\.slug)).intersection(Set(codex.map(\.slug)))
        Log("\nslugs seen on both engines: \(shared.isEmpty ? "none" : shared.sorted().joined(separator: ", "))")
    }

    private static func dump(_ connectors: [ConnectorCensus.DetectedConnector]) {
        guard !connectors.isEmpty else { Log("  (none)"); return }
        for connector in connectors {
            var line = "  \(connector.slug)  \"\(connector.displayName)\"  healthy=\(connector.healthy)"
            if let url = connector.serverURL { line += "  url=\(url)" }
            if let id = connector.catalogID { line += "  id=\(id)" }
            line += "  icon=\(connector.iconPath == nil ? "none" : "yes")"
            Log(line)
        }
        Log("  → \(connectors.count) connector(s)")
    }

    // MARK: parse (canned strings — no machine state involved)

    private static func parse() {
        // The README's measured sample: 3 claude.ai lines + the cua-driver entry + the banner.
        // Gmail and Calendar are excluded by design, so only Google Drive survives.
        check("README sample", """
        Checking MCP server health…

        claude.ai Google Calendar: https://calendarmcp.googleapis.com/mcp/v1 - ✔ Connected
        claude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - ✔ Connected
        claude.ai Google Drive: https://drivemcp.googleapis.com/mcp/v1 - ✔ Connected
        cua-driver: cua-driver mcp - ✔ Connected
        """, expected: ["google-drive"])

        check("empty", "", expected: [])

        check("login error", """
        Invalid API key · Please run /login
        """, expected: [])

        check("partial line (no url)", """
        claude.ai Broken
        """, expected: [])

        check("unhealthy connector", """
        claude.ai Notion: https://mcp.notion.com/mcp - ✘ Disconnected
        """, expected: ["notion"], expectHealthy: false)

        check("multi-word name", """
        claude.ai Outlook Mail: https://example.com/mcp - ✔ Connected
        """, expected: ["outlook-mail"])
    }

    private static func check(_ label: String, _ input: String,
                              expected: [String], expectHealthy: Bool = true) {
        let candidates = input.split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("claude.ai ") }.count
        let parsed = ConnectorCensus.parseClaudeList(input)
        let slugs = parsed.map(\.slug)
        let healthOK = parsed.allSatisfy { $0.healthy == expectHealthy }
        let pass = slugs == expected && healthOK
        Log("\(pass ? "PASS" : "FAIL")  \(label): \(candidates) claude.ai line(s) → "
            + "\(slugs.isEmpty ? "[]" : slugs.joined(separator: ", "))"
            + (healthOK ? "" : "  (health mismatch)"))
    }

    // MARK: warm (the codex freshness mechanism)

    private static func warm() async {
        guard ModelBackend.current == .chatgpt else {
            Log("skipped: the warm run goes through FrontierRun, which dispatches on the live "
                + "backend — switch Sentient to ChatGPT to exercise it (currently "
                + "\(ModelBackend.current.rawValue)).")
            return
        }
        let before = ConnectorCensus.listCodex().map(\.slug).sorted()
        Log("before: \(before.joined(separator: ", "))")

        let started = Date()
        await ConnectorCensus.refreshCodexCache()
        Log("warm run finished in \(Int(Date().timeIntervalSince(started)))s")

        let after = ConnectorCensus.listCodex().map(\.slug).sorted()
        Log("after:  \(after.joined(separator: ", "))")

        let added = Set(after).subtracting(before).sorted()
        let removed = Set(before).subtracting(after).sorted()
        if added.isEmpty && removed.isEmpty {
            Log("no change (expected, unless a connector was linked or unlinked since the last "
                + "codex run — link one and re-run to see it appear)")
        } else {
            Log("appeared: \(added.joined(separator: ", ")) · gone: \(removed.joined(separator: ", "))")
        }
    }

    // MARK: registry (pure — no model, no backend requirement)

    private static func registry() {
        // The verbatim-reference check: the curated read queries must round-trip to the
        // ConnectorTools arrays exactly (proving the packs reference them, not copy them).
        let gmailOK = ConnectorRegistry.readToolNames(slug: "gmail")
            == ClaudeCLI.ConnectorTools.gmailReads
        let calendarOK = ConnectorRegistry.readToolNames(slug: "google-calendar")
            == ClaudeCLI.ConnectorTools.calendarReads
        Log("\(gmailOK ? "PASS" : "FAIL")  readToolNames(gmail) == ConnectorTools.gmailReads")
        Log("\(calendarOK ? "PASS" : "FAIL")  readToolNames(google-calendar) == ConnectorTools.calendarReads")

        let driveReads = ConnectorRegistry.readToolNames(slug: "google-drive")
        let drivePrefixOK = driveReads.count == 6
            && driveReads.allSatisfy { $0.hasPrefix("mcp__claude_ai_Google_Drive__") }
        Log("\(drivePrefixOK ? "PASS" : "FAIL")  drive pack: \(driveReads.count) reads, prefixed")

        // Catalog id constants (the hoisted single source of truth).
        let stripOK = CodexCLI.Invocation.stripConnectorActionTools
            .contains("apps.\(CodexCLI.Invocation.gmailCatalogID).open_world_enabled=false")
        Log("\(stripOK ? "PASS" : "FAIL")  strip preset built from the hoisted catalog ids")

        // KB toggle round trip (restored afterwards — this is the real UserDefaults).
        let slug = "google-drive"
        let before = ConnectorRegistry.isKBEnabled(slug)
        ConnectorRegistry.setKBEnabled(slug, !before)
        let flipped = ConnectorRegistry.isKBEnabled(slug) == !before
        ConnectorRegistry.setKBEnabled(slug, before)
        Log("\(flipped ? "PASS" : "FAIL")  KB toggle round trip on \(ConnectorRegistry.kbKey(slug))")

        // Derived prefixes for uncurated names.
        let derived = ConnectorRegistry.derivedClaudePrefix(from: "Outlook Mail")
        Log("\(derived == "mcp__claude_ai_Outlook_Mail__" ? "PASS" : "FAIL")  derived prefix: \(derived)")

        // Pack matching over whatever the census last saw.
        for connector in ConnectorRegistry.detectedForCurrentBackend() {
            let pack = ConnectorRegistry.pack(for: connector)
            Log("  detected \(connector.slug) → \(pack == nil ? "uncurated" : "curated pack")")
        }
        Log("kbEnabledConnectors: \(ConnectorRegistry.kbEnabledConnectors().map(\.slug).sorted().joined(separator: ", "))")
    }

    // MARK: tools (the inventory probe)

    private static func tools() async {
        guard requireClaudeBackend("the tool dump") else { return }
        let slug = labSlug
        do {
            let names = try await ConnectorClassifier.listTools(slug: slug)
            Log("\(slug): \(names.count) tool(s) visible in context")
            for name in names.sorted() { Log("  \(name)") }
        } catch {
            Log("tools failed: \(ErrorLabel(error))")
        }
    }

    // MARK: classify (the three-way run + the ground-truth eval)

    private static func classify() async {
        guard requireClaudeBackend("classification") else { return }
        let slug = labSlug
        let runs = Int(ProcessInfo.processInfo.environment["LAB_RUNS"] ?? "1") ?? 1
        var lastTools: [ConnectorRegistry.ClassifiedTool]?
        var failures = 0

        for run in 1...max(runs, 1) {
            Log("\n-- classify \(slug), run \(run)/\(runs) --")
            do {
                let started = Date()
                let tools = try await ConnectorClassifier.classify(slug: slug)
                Log("classified \(tools.count) tool(s) in \(Int(Date().timeIntervalSince(started)))s")
                printBuckets(tools)
                if !evaluate(slug: slug, tools: tools) { failures += 1 }
                lastTools = tools
            } catch {
                failures += 1
                Log("run \(run) FAILED: \(ErrorLabel(error))")
            }
        }

        Log("\n== \(failures == 0 ? "PASS" : "FAIL"): \(runs - failures)/\(runs) clean run(s) ==")
        // Persist the last result so `cache`, the registry queries, and later tasks see it —
        // the same write ensureClassified performs.
        if let tools = lastTools {
            let version = await ClaudeCLI.installedVersion() ?? "unknown"
            ConnectorRegistry.saveClassification(
                .init(tools: tools, cliVersion: version, capturedAt: Date()), for: slug)
            Log("persisted to \(ConnectorRegistry.classificationKey(slug)) (cli \(version))")
        }
    }

    private static func printBuckets(_ tools: [ConnectorRegistry.ClassifiedTool]) {
        for category: ConnectorRegistry.ToolCategory in [.read, .write, .destructive] {
            let names = tools.filter { $0.category == category }
                .map { shortName($0.name) }.sorted()
            Log("  \(category.rawValue) (\(names.count)): \(names.joined(separator: ", "))")
        }
    }

    private static func shortName(_ full: String) -> String {
        guard let range = full.range(of: "__", options: .backwards) else { return full }
        return String(full[range.upperBound...])
    }

    /// The ground-truth eval. The HARD FAIL in every case is a write-family tool classified
    /// "read" (that is the dangerous direction); a curated read landing "write" is conservative
    /// and only warned. Returns false when a hard fail occurred.
    private static func evaluate(slug: String,
                                 tools: [ConnectorRegistry.ClassifiedTool]) -> Bool {
        switch slug {
        case "gmail":
            // 5 curated reads + get_draft (a read, deliberately uncurated) are the ONLY
            // acceptable reads; every gmailWriteDenies tool must land write or destructive.
            return evaluate(tools,
                            okReads: Set(ClaudeCLI.ConnectorTools.gmailReads
                                         + ["mcp__claude_ai_Gmail__get_draft"]),
                            mustNotRead: Set(ClaudeCLI.ConnectorTools.gmailWriteDenies),
                            curatedReads: Set(ClaudeCLI.ConnectorTools.gmailReads),
                            wantDestructive: Set(["trash_message", "trash_thread", "delete_label",
                                                  "delete_filter", "mark_message_spam",
                                                  "mark_thread_spam"]
                                .map { "mcp__claude_ai_Gmail__\($0)" }))
        case "google-calendar":
            let prefix = "mcp__claude_ai_Google_Calendar__"
            let reads = Set(ClaudeCLI.ConnectorTools.calendarReads)
            let writes = Set(["create_event", "update_event", "delete_event", "respond_to_event"]
                .map { prefix + $0 })
            return evaluate(tools, okReads: reads, mustNotRead: writes, curatedReads: reads,
                            wantDestructive: Set([prefix + "delete_event"]))
        case "google-drive":
            // Re-verifies the provisional pack: the captured reads should classify read, the
            // two captured writes must NOT, and any surface drift is reported for a pack update.
            guard let pack = ConnectorRegistry.pack(forSlug: "google-drive"),
                  let packReads = pack.readTools, let prefix = pack.claudeToolPrefix else {
                Log("  eval: no drive pack?!"); return false
            }
            let expectedReads = Set(packReads.map { prefix + $0 })
            let knownWrites = Set(["copy_file", "create_file"].map { prefix + $0 })
            let ok = evaluate(tools, okReads: expectedReads, mustNotRead: knownWrites,
                              curatedReads: expectedReads, wantDestructive: [])
            let live = Set(tools.map(\.name))
            let drift = live.symmetricDifference(expectedReads.union(knownWrites))
            if !drift.isEmpty {
                Log("  PACK DRIFT vs the captured surface: \(drift.map(shortName).sorted().joined(separator: ", "))")
            }
            return ok
        default:
            Log("  (no ground truth for \(slug); buckets above are the whole output)")
            return true
        }
    }

    private static func evaluate(_ tools: [ConnectorRegistry.ClassifiedTool],
                                 okReads: Set<String>, mustNotRead: Set<String>,
                                 curatedReads: Set<String>,
                                 wantDestructive: Set<String>) -> Bool {
        var hardFails = 0
        for tool in tools {
            if tool.category == .read, mustNotRead.contains(tool.name) {
                hardFails += 1
                Log("  HARD FAIL write-as-read: \(shortName(tool.name))")
            }
            if tool.category == .read, !okReads.contains(tool.name) {
                hardFails += 1
                Log("  HARD FAIL unexpected read: \(shortName(tool.name))")
            }
            if tool.category != .read, curatedReads.contains(tool.name) {
                Log("  warn (tolerable, conservative): curated read landed \(tool.category.rawValue): \(shortName(tool.name))")
            }
            if tool.category != .destructive, wantDestructive.contains(tool.name) {
                Log("  note: expected destructive, landed \(tool.category.rawValue): \(shortName(tool.name))")
            }
        }
        let missing = curatedReads.subtracting(tools.map(\.name))
        if !missing.isEmpty {
            Log("  note: curated reads absent from the live surface: \(missing.map(shortName).sorted().joined(separator: ", "))")
        }
        Log("  eval: \(hardFails == 0 ? "PASS (zero write-as-read)" : "FAIL (\(hardFails) hard fail(s))")")
        return hardFails == 0
    }

    // MARK: cache (hit → version bump → re-run)

    private static func cache() async {
        guard requireClaudeBackend("the cache lifecycle") else { return }
        let slug = labSlug
        guard let stored = ConnectorRegistry.classification(for: slug) else {
            Log("no classification cached for \(slug) — run LAB_CMD=classify first")
            return
        }

        var started = Date()
        let hit = await ConnectorClassifier.ensureClassified(slug: slug)
        let hitSeconds = Date().timeIntervalSince(started)
        Log("fresh cache: ensureClassified=\(hit) in \(String(format: "%.1f", hitSeconds))s "
            + "(expect a fast hit — no model run beyond the one-time `claude --version`)")

        ConnectorRegistry.saveClassification(
            .init(tools: stored.tools, cliVersion: "0.0.0", capturedAt: stored.capturedAt),
            for: slug)
        Log("stored cliVersion rewritten to 0.0.0")

        started = Date()
        let reran = await ConnectorClassifier.ensureClassified(slug: slug)
        let rerunSeconds = Date().timeIntervalSince(started)
        let after = ConnectorRegistry.classification(for: slug)
        let versionRestored = (after?.cliVersion ?? "0.0.0") != "0.0.0"
        Log("\(reran && versionRestored && rerunSeconds > 5 ? "PASS" : "FAIL")  version bump forced "
            + "a re-run: ok=\(reran) in \(Int(rerunSeconds))s, stored cli=\(after?.cliVersion ?? "none")")
    }
}
