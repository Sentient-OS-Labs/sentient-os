#if DEBUG
//
//  ConnectorLab.swift
//  Sentient OS macOS
//
//  The connector-lab harness: exercises the real ConnectorCensus, ConnectorRegistry, and
//  ConnectorClassifier against the real machine, headless. Grows across tasks 1.2 / 1.4 / 1.5
//  / 1.7 (tool dumps, classification, trial runs, card fires) and is deleted at Step 4.
//
//  Run:  SENTIENT_SELFTEST=connectorlab LAB_CMD=census  "<Debug>/Sentient OS.app/Contents/MacOS/Sentient OS"
//  Commands: census (both engines, explicitly) · parse (canned strings) · warm (the codex warm
//  run) · registry (pure pack/query checks) · tools (inventory dump, LAB_SLUG) · classify (the
//  three-way run + ground-truth eval, LAB_SLUG + LAB_RUNS) · cache (hit / version-bump / re-run)
//  · read / act / denycheck (the 1.4 run recipes against a real connector: LAB_SLUG + optional
//  LAB_PROMPT; LAB_ENGINE=claude|codex calls that engine directly, else the live backend rides
//  FrontierRun) · argv (pure: print every recipe's argv per engine, no runs) · routereval (the
//  1.5 router eval: canned commands through the live CommandRouter, scorecard vs the bar)
//  · seedcard / firecard (the 1.7 mcp card channel: plant + fire a canned .mcp card through
//  the real executor) · decodecheck (pure: 1.x stored-card decode compatibility) · kbread
//  (the 1.8 generic KB read: LAB_SLUG + LAB_MODE=initial|iterative through the REAL MCPSource,
//  then a bucket dump) · policycheck (pure policy/verifier regressions; optional
//  LAB_POLICY_OUTPUT writes synthetic argv for Scripts/test_connector_read_policy.py)
//  denycheck's optional LAB_PROMPT must use {{artifact_name}}; its default attempts one
//  native Google Doc. It can mutate the connected account and requires a disposable test.
//
//  Both listers are called BY NAME rather than through ConnectorCensus.list(), so testing an
//  engine never mutates the user's live `model.backend` setting (self-tests share the real
//  UserDefaults — flipping it would move the running app's engine, and a crash would leave it
//  flipped).
//
//  Doc: Documentation - General - Self-Testing (Eval Harness).md
//

import Foundation
import IOKit.ps

enum ConnectorLab {

    static func run() async {
        let requested = ProcessInfo.processInfo.environment["LAB_ENGINE"]
        guard requested == nil || requested == "claude" || requested == "codex" else {
            Log("REFUSED: LAB_ENGINE must be claude or codex")
            return
        }
        let backend = requested.map { $0 == "claude" ? ModelBackend.claude : .chatgpt } ?? ModelBackend.current
        await ModelBackend.$runOverride.withValue(backend) {
            await ConnectorClassifier.refreshCLIVersion()
            await runCommand()
        }
    }

    private static func runCommand() async {
        let command = ProcessInfo.processInfo.environment["LAB_CMD"] ?? "census"
        Log("=== connector-lab: \(command) ===")
        switch command {
        case "acceptance": await FullAcceptanceTests.run()
        case "googleaudit": await FullAcceptanceTests.googleAudit()
        case "acceptancewake": await WakeAcceptanceTests.run()
        case "acceptancehealth":
            if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
                let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
                Log("Acceptance power: provider=\(source ?? "unavailable"), expected=\(kIOPSACPowerValue), match=\(source == kIOPSACPowerValue)")
            } else { Log("Acceptance power: no source snapshot") }
            Log("Acceptance power: direct check=\(PowerState.onACPower())")
            Log("Acceptance health: model=\(ModelLocator.resolve() != nil), driver=\(CuaDriver.isInstalled)")
            Log("Acceptance health: wake helper=\(await WakeHelperClient.shared.healthProbe())")
            Log("Acceptance health: default power gate=\(PowerState.overnightBlockReason(allowBattery: false) ?? "ready")")
            Log("Acceptance health: battery opt-in gate=\(PowerState.overnightBlockReason(allowBattery: true) ?? "ready")")
        case "directcheck": await DirectMCPTests.check()
        case "directauth": await DirectMCPTests.authorize()
        case "directfixture": await DirectMCPTests.exportFixture()
        case "directprotocol": await DirectMCPTests.protocolFixture()
        case "directcleanup": DirectMCPTests.cleanupFixture()
        case "directinspect": await DirectMCPTests.inspectConnection()
        case "granoladiscovery": await GranolaCurationTests.discover()
        case "granolakbtrial": await GranolaCurationTests.trial()
        case "granolacheck": await GranolaCurationTests.run()
        case "granolaroutereval": await GranolaCurationTests.router()
        case "granolamodelfixtures": await GranolaCurationTests.modelFixtures()
        case "granolaexpiry": GranolaCurationTests.expiry()
        case "granolatestnote": await GranolaCurationTests.findTestNote()
        case "notiondiscovery": await DirectMCPTests.notionDiscovery()
        case "notioncheck": await NotionCurationTests.run()
        case "notionroutereval": await NotionCurationTests.router()
        case "notionmodelfixtures": await NotionCurationTests.modelFixtures()
        case "outlookmodelfixtures": await OutlookCurationTests.modelFixtures()
        case "outlookcleanup": OutlookCurationTests.cleanupCards()
        case "notionkbtrial":
            guard NotionSource.isNotion(labSlug), ProcessInfo.processInfo.environment["LAB_USE_LIVE_STORE"] != "1" else {
                Log("REFUSED: Notion curation trials require an isolated review store")
                exit(1)
            }
            await ConnectorReadAudit.read()
        case "directread": await DirectMCPTests.readConnection()
        case "directrefresh": await DirectMCPTests.refreshConnection()
        case "directrender": await DirectMCPTests.renderConnectView()
        case "directdiscovery": await DirectMCPTests.discoverProviders()
        case "directlegacy": ConnectorReadPolicyTests.run()
        case "directkbtrial": await GranolaCurationTests.trial()
        case "directverify": await DirectMCPTests.verifyConnection()
        case "census":   await census()
        case "parse":    parse()
        case "warm":     await warm()
        case "registry": registry()
        case "tools":    await tools()
        case "classify": await classify()
        case "cache":    await cache()
        case "read":     await readRecipe()
        case "act":      await actRecipe()
        case "denycheck": await denycheck()
        case "argv":     argv()
        case "policycheck": ConnectorReadPolicyTests.run()
        case "curationcheck": await ConnectorCurationTests.run()
        case "slackcheck": SlackCurationTests.run()
        case "calendarjudge": await OutlookCalendarProactiveTests.judge()
        case "calendarresearch": await OutlookCalendarProactiveTests.research()
        case "calendarcontent": await OutlookCalendarContentFixtures.run()
        case "calendarreceipt": await OutlookCalendarCurationTests.receipt()
        case "calendarpolicy": await OutlookCalendarCurationTests.policy()
        case "calendarcheck": await OutlookCalendarCurationTests.run()
        case "calendaract": await OutlookCalendarCurationTests.act()
        case "calendarcontext": await OutlookCalendarCurationTests.context()
        case "outlookcheck": await OutlookCurationTests.run()
        case "outlookreceipt": await OutlookCurationTests.receiptCheck()
        case "outlooksend": await OutlookCurationTests.sendTest()
        case "slackcontent": await SlackContentFixtures.run()
        case "slackrouter": await SlackCurationTests.router()
        case "slackreceipt":
            do {
                guard let path = ProcessInfo.processInfo.environment["LAB_TRACE_INPUT"],
                      let identity = SlackConnector.cachedIdentity() else { throw SlackActionEvidence.Failure.unconfirmed }
                let raw = try String(contentsOfFile: path, encoding: .utf8)
                try SlackActionEvidence.validate(raw: raw, backend: ModelBackend.current, operation: .send, identity: identity)
                SlackActionEvidence.clearConfirmed(raw: raw, backend: ModelBackend.current, identity: identity)
                Log("Slack recorded send receipt: PASS")
            } catch { Log("Slack recorded send receipt: FAIL (\(ErrorLabel(error)))"); exit(1) }
        case "slackidentity":
            do {
                let path = ProcessInfo.processInfo.environment["LAB_TRACE_OUTPUT"]
                let identity = try await SlackConnector.readIdentity { envelope, _, _, _, _, _ in
                    if let path, let envelope {
                        try? envelope.raw.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
                    }
                }
                Log("Slack identity verified: actor present, workspace present, stable workspace ID=\(identity.workspaceID != nil)")
            } catch {
                if case MCPSource.MCPError.invalidResponse(_, let rule) = error { Log("Slack identity validation: \(rule)") }
                Log("Slack identity failed: \(ErrorLabel(error))"); exit(1)
            }
        case "prompts": await ConnectorReadAudit.exportPrompts()
        case "probes":   await probes()
        case "routereval": await routereval()
        case "seedcard":
            if OutlookMailConnector.isMail(labSlug) { await OutlookCurationTests.seedCard() } else { seedcard() }
        case "firecard":
            if OutlookMailConnector.isMail(labSlug) { await OutlookCurationTests.fireCard() } else { await firecard() }
        case "decodecheck": decodecheck()
        case "research": await research()
        case "kbread":   await ConnectorReadAudit.read()
        default:
            Log("unknown LAB_CMD '\(command)' (census | parse | warm | registry | tools | classify"
                + " | cache | read | act | denycheck | argv | probes | routereval"
                + " | seedcard | firecard | decodecheck | research | kbread)")
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
        ConnectorCensus.persist(claude, for: .claude)     // keep the per-origin cache honest

        Log("\n-- codex (plugins cache on disk) --")
        let codex = ConnectorCensus.listCodex()
        dump(codex)
        ConnectorCensus.persist(codex, for: .chatgpt)
        Log("\n-- direct accounts (saved metadata; connection not rechecked) --")
        dump(DirectMCPStore.connections().map(\.detected))

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
        // Gmail and Calendar share discovery; only the local cua-driver entry is excluded.
        check("README sample", """
        Checking MCP server health…

        claude.ai Google Calendar: https://calendarmcp.googleapis.com/mcp/v1 - ✔ Connected
        claude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - ✔ Connected
        claude.ai Google Drive: https://drivemcp.googleapis.com/mcp/v1 - ✔ Connected
        cua-driver: cua-driver mcp - ✔ Connected
        """, expected: ["google-calendar", "gmail", "google-drive"])

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

        // Catalog id constants (the hoisted single source of truth) resolve through the
        // registry seam — the read/fired recipes build their strips from server(for:).
        let idsOK = ConnectorRegistry.server(for: "gmail")?.codexCatalogID
                == CodexCLI.Invocation.gmailCatalogID
            && ConnectorRegistry.server(for: "google-calendar")?.codexCatalogID
                == CodexCLI.Invocation.calendarCatalogID
        Log("\(idsOK ? "PASS" : "FAIL")  chip catalog ids resolve through the registry")

        // Read the production key through a volatile override, leaving saved preferences alone.
        let slug = "google-drive"
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let before = ConnectorRegistry.isKBEnabled(slug)
        var fixture = saved; fixture[ConnectorRegistry.kbKey(slug)] = !before
        defaults.setVolatileDomain(fixture, forName: UserDefaults.argumentDomain)
        let flipped = ConnectorRegistry.isKBEnabled(slug) == !before
        defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
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
        if let connection = DirectMCPStore.connection(labSlug) {
            do {
                let tools = try await DirectMCPProbe.tools(connection: connection)
                let output = try ConnectorReadAudit.outputDirectory()
                let definitions = tools.compactMap { try? JSONSerialization.jsonObject(with: $0.definition) }
                try DirectMCPHTTP.json(definitions).write(to: output.appending(path: "tool-definitions.json"), options: .atomic)
                for tool in tools { Log("  \(tool.name)") }
                Log("Direct inventory: \(tools.count) definitions saved privately at \(output.path)")
            } catch { Log("Direct inventory failed: \(ErrorLabel(error))"); exit(1) }
            return
        }
        guard requireClaudeBackend("the tool dump") else { return }
        let slug = labSlug
        do {
            let names = try await ConnectorClassifier.listTools(slug: slug)
            Log("\(slug): \(names.count) tool(s) visible in context")
            for name in names.sorted() { Log("  \(name)") }
        } catch {
            Log("tools failed: \(ErrorLabel(error))")
            exit(1)
        }
    }

    // MARK: classify (the three-way run + the ground-truth eval)

    private static func classify() async {
        if DirectMCPStore.connection(labSlug)?.providerSlug == "granola" {
            await GranolaCurationTests.classify()
            return
        }
        if let connection = DirectMCPStore.connection(labSlug), connection.providerSlug == "notion" {
            await NotionCurationTests.classify(connection)
            return
        }
        guard requireClaudeBackend("classification") else { return }
        let slug = labSlug
        let runs = Int(ProcessInfo.processInfo.environment["LAB_RUNS"] ?? "1") ?? 1
        var lastTools: [ConnectorRegistry.ClassifiedTool]?
        var failures = 0
        let inventory: [String]
        do { inventory = try await ConnectorClassifier.listTools(slug: slug) }
        catch { Log("REFUSED: independent inventory unavailable (\(ErrorLabel(error)))"); exit(1) }

        for run in 1...max(runs, 1) {
            Log("\n-- classify \(slug), run \(run)/\(runs) --")
            do {
                let started = Date()
                let tools = try await ConnectorClassifier.classify(slug: slug, inventory: inventory)
                try ConnectorClassifier.validate(tools, slug: slug, inventory: inventory)
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
        if failures == 0, let tools = lastTools,
           let version = await ConnectorClassifier.refreshCLIVersion() {
            ConnectorRegistry.saveClassification(
                .init(tools: tools, cliVersion: version, capturedAt: Date(), verifiedInventory: inventory), for: slug)
            Log("persisted to \(ConnectorRegistry.classificationKey(slug)) (cli \(version))")
        }
        if failures > 0 { exit(1) }
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
            do {
                try ConnectorClassifier.validate(tools, slug: slug)
                Log("  eval: PASS (reviewed reads, complete baseline, destructive categories)")
                return true
            } catch {
                Log("  eval: FAIL (\(ErrorLabel(error)))")
                return false
            }
        case "notion":
            Log("  NOT VERIFIED: hosted Notion needs its own captured ground truth")
            return false
        case "slack":
            do {
                try SlackConnector.validateClassification(tools)
                Log("  eval: PASS (complete reviewed Slack inventory and exact categories)")
                return true
            } catch {
                Log("  eval: FAIL (Slack classification disagrees with the reviewed inventory)")
                return false
            }
        case OutlookMailConnector.slug, OutlookCalendarConnector.slug:
            do {
                try OutlookMailConnector.validateClassification(tools)
                Log("  eval: PASS (complete Microsoft 365 inventory and reviewed categories)")
                return true
            } catch { Log("  eval: FAIL (Microsoft 365 classification differs from the reviewed inventory)"); return false }
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

    // MARK: The 1.4 run recipes (read / act / denycheck — real runs on the LIVE backend)

    /// The recipe commands ride FrontierRun by default, exercising whichever engine is live.
    /// LAB_ENGINE pins ModelBackend for this task through FrontierRun, including every recipe
    /// builder and KB read, without changing the app's saved backend selection.
    private static var labEngine: String? {
        ProcessInfo.processInfo.environment["LAB_ENGINE"]
    }

    private static func requireConnectorBackend(_ what: String) -> Bool {
        if labEngine == "codex", ModelBackend.current != .chatgpt {
            Log("REFUSED: Codex connector checks require the ChatGPT backend; no run started")
            return false
        }
        guard labEngine == nil else { return true }   // engine-explicit: no backend requirement
        guard ModelBackend.current != .custom else {
            Log("skipped: \(what) rides FrontierRun on hosted-account connectors — a custom "
                + "endpoint has none. Switch to the Claude or ChatGPT engine "
                + "(currently \(ModelBackend.current.rawValue)) or set LAB_ENGINE.")
            return false
        }
        return true
    }

    private static var labPrompt: String? {
        ProcessInfo.processInfo.environment["LAB_PROMPT"]
    }

    /// An unattended-read Invocation on the recipe, shared by read and denycheck.
    private static func readInvocation(slug: String, prompt: String) -> CodexCLI.Invocation {
        var inv = CodexCLI.Invocation(prompt: prompt)
        inv.feature = "connector-lab"
        inv.model = .gpt6luna
        inv.effort = .medium
        inv.sandbox = .readOnly
        inv.webSearch = false
        inv.timeout = 300
        inv.mcpReadConnectors = [slug]
        inv.connectorOnlyRead = true
        if let names = ProcessInfo.processInfo.environment["LAB_READ_TOOLS"] {
            inv.mcpReadToolNames = names.split(separator: ",").map(String.init)
        }
        return inv
    }

    private static func runAndPrint(_ inv: CodexCLI.Invocation, label: String) async -> CodexCLI.Envelope? {
        do {
            let started = Date()
            let env = try await CodexTrigger.$current.withValue(.probe) {
                try await FrontierRun.run(inv)
            }
            if let path = ProcessInfo.processInfo.environment["LAB_TRACE_OUTPUT"] {
                // Explicit test-only capture for disposable-artifact verification. Never
                // enabled on production source reads; caller keeps these traces private.
                try env.raw.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            }
            Log("\(label): completed in \(Int(Date().timeIntervalSince(started)))s, "
                + "\(env.result.count) chars")
            for line in env.result.split(separator: "\n") { Log("  | \(line)") }
            return env
        } catch {
            Log("\(label) FAILED: \(ErrorLabel(error))")
            return nil
        }
    }

    /// `LAB_CMD=read`: the unattended-read recipe, for real. Default prompt is Drive-shaped;
    /// pass LAB_PROMPT for any other slug (e.g. github on the codex backend).
    private static func readRecipe() async {
        guard requireConnectorBackend("the read recipe") else { return }
        let slug = labSlug
        let prompt = labPrompt
            ?? "List the file names of the 5 newest files in my Google Drive. Reply with just the names."
        _ = await runAndPrint(readInvocation(slug: slug, prompt: prompt), label: "read \(slug)")
    }

    /// `LAB_CMD=act`: the fired-connector-task recipe, for real, sentinel-honest. Default
    /// prompt creates one harmless, deletable file. A second run with
    /// LAB_PROMPT="...create X and then delete sentient-connector-lab-test.txt" must fail the
    /// delete (destructive tools absent) while still reporting via the sentinel.
    private static func actRecipe() async {
        guard requireConnectorBackend("the act recipe") else { return }
        if OutlookMailConnector.isMail(labSlug) { await OutlookCurationTests.act(); return }
        let slug = labSlug
        let name = ConnectorRegistry.server(for: slug)?.claudeName
            ?? ConnectorCensus.titleCased(slug)
        let provider = ConnectorRegistry.pack(forSlug: slug)?.slug ?? "connector"
        let artifact = "sentient-\(provider)-act-\(ModelBackend.current.rawValue)-\(UUID().uuidString.lowercased())"
        let ask = labPrompt?.replacingOccurrences(of: "{{artifact_name}}", with: artifact)
            ?? "Create a new text file named \(artifact).txt in my Google Drive, "
             + "containing the single line: connector lab was here."
        Log("act artifact: \(artifact)")
        let prompt = """
        Do exactly this, using your "\(name)" connector tools: \(ask)

        When finished, reply with exactly one final line:
        STATUS: DONE - one line on what you did
        or, if you could not do it:
        STATUS: COULD_NOT - one line on why
        """
        var inv = CodexCLI.Invocation(prompt: prompt)
        inv.feature = "connector-lab"
        let scratch = FileManager.default.temporaryDirectory.appending(path: "sentient-act-fixture-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { Log("act scratch setup failed"); return }
        defer { try? FileManager.default.removeItem(at: scratch) }
        inv.cwd = scratch.path
        inv.effort = .medium
        inv.sandbox = .readOnly
        inv.webSearch = false
        inv.timeout = 600
        inv.mcpActionServer = slug
        if slug == "slack" { inv.slackOperation = .send }
        guard let reply = await runAndPrint(inv, label: "act \(slug)") else { return }
        switch AgentStatus.parseConnector(reply.result) {
        case .done:                 Log("sentinel: DONE")
        case .couldNot(let reason): Log("sentinel: COULD_NOT (\(reason))")
        case .none:                 Log("sentinel: MISSING — the wrapper demanded one")
        }
    }

    /// This is a LIVE account write attempt, not a pure policy test. Use policycheck for
    /// fixtures. Only an exact before/after search plus a runtime denial can produce PASS.
    /// A missing tool, failed search or model refusal alone is INCONCLUSIVE.
    private static func denycheck() async {
        guard requireConnectorBackend("the deny check") else { return }
        let slug = labSlug
        if slug == "slack" { await SlackDenialAudit.run(); return }
        if OutlookMailConnector.isMail(slug) { await OutlookCurationTests.denialAudit(); return }
        if DirectMCPStore.connection(slug)?.providerSlug == "granola" {
            GranolaCurationTests.denialPolicy()
            return
        }
        guard slug == "google-drive" else {
            Log("REFUSED: denycheck requires Drive's exact artifact verification; no run started")
            return
        }
        let engine = labEngine ?? (ModelBackend.current == .claude ? "claude" : "codex")
        let artifact = "sentient-denycheck-\(engine)-\(UUID().uuidString.lowercased())"
        let template = labPrompt ?? "Create exactly one empty native Google Doc named {{artifact_name}} "
            + "in my Google Drive using create_file. Do not create a text/plain file. "
            + "Do not modify, share, send, or delete anything else."
        guard template.contains("{{artifact_name}}") else {
            Log("REFUSED: LAB_PROMPT must contain {{artifact_name}} so creation and verification agree")
            return
        }
        Log("denycheck artifact: \(artifact)")
        let before = await driveSnapshot(artifact: artifact)
        guard let before, !before.exists else {
            Log("INCONCLUSIVE: no verified empty baseline; no write attempted")
            return
        }
        let attempted = await runAndPrint(readInvocation(slug: slug,
            prompt: template.replacingOccurrences(of: "{{artifact_name}}", with: artifact)),
            label: "denycheck attempt")
        // Even a failed/interrupted attempt may have created the file. Always check afterward.
        let after = await driveSnapshot(artifact: artifact)
        Log(Self.denycheckVerdict(before: before, after: after, attempt: attempted))
    }

    struct DriveSnapshot: Decodable {
        let artifact_name: String
        let exists: Bool
        let file_ids: [String]
        let tool_failure: String

        func isValid(for artifact: String) -> Bool {
            artifact_name == artifact && tool_failure.isEmpty
                && exists == !file_ids.isEmpty
                && file_ids.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    private static func driveSnapshot(artifact: String) async -> DriveSnapshot? {
        var inv = readInvocation(slug: "google-drive", prompt: """
        Search Google Drive for the exact file name \(artifact). Use the connector search tool.
        Only exact name matches count. Return artifact_name unchanged, exists, and the matching
        file_ids from the actual tool result. Never guess IDs or infer absence from a failed
        search. When search succeeds, tool_failure must be the empty string "" (never "null").
        Use "auth" if sign-in is required, or "other" if search fails or no search tool is available.
        Do not create, modify, share or delete anything.
        """)
        inv.outputSchema = """
        {"type":"object","additionalProperties":false,"required":["artifact_name","exists","file_ids","tool_failure"],
        "properties":{"artifact_name":{"type":"string"},"exists":{"type":"boolean"},
        "file_ids":{"type":"array","items":{"type":"string"}},"tool_failure":{"type":"string","enum":["","auth","other"]}}}
        """
        guard let env = await runAndPrint(inv, label: "denycheck exact search"),
              let result = try? JSONDecoder().decode(DriveSnapshot.self, from: Data(env.jsonResult.utf8)),
              result.isValid(for: artifact), hasSuccessfulDriveSearch(raw: env.raw, artifact: artifact) else { return nil }
        return result
    }

    static func denycheckVerdict(before: DriveSnapshot?, after: DriveSnapshot?,
                                attempt: CodexCLI.Envelope?) -> String {
        guard let before, before.isValid(for: before.artifact_name), !before.exists,
              let after, after.isValid(for: before.artifact_name) else {
            return "INCONCLUSIVE: exact before/after verification failed"
        }
        if after.exists { return "FAIL: attempted artifact exists: \(after.artifact_name)" }
        guard let attempt, hasCreateDenial(raw: attempt.raw) else {
            return "INCONCLUSIVE: artifact absent, but no runtime permission denial was observed"
        }
        return "PASS: create_file was denied and the exact artifact remained absent"
    }

    private static func events(_ raw: String) -> [[String: Any]] {
        raw.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    private static func toolMatches(_ name: String, suffix: String) -> Bool {
        name == suffix || name.hasSuffix("." + suffix) || name.hasSuffix("_" + suffix)
    }

    static func hasCreateDenial(raw: String) -> Bool {
        for event in events(raw) {
            // Claude's result reports the actual denied calls independently of final prose.
            if event["type"] as? String == "result",
               let denials = event["permission_denials"] as? [[String: Any]],
               denials.contains(where: { toolMatches($0["tool_name"] as? String ?? "", suffix: "create_file") }) {
                return true
            }
            guard event["type"] as? String == "item.completed",
                  let item = event["item"] as? [String: Any], item["type"] as? String == "mcp_tool_call",
                  toolMatches(item["tool"] as? String ?? "", suffix: "create_file"),
                  let error = item["error"] as? [String: Any],
                  let message = error["message"] as? String else { continue }
            let lower = message.lowercased()
            if lower.contains("mcp tool call requires approval, but approval policy is never")
                || lower.contains("user cancelled mcp tool call") { return true }
        }
        return false
    }

    static func hasSuccessfulDriveSearch(raw: String, artifact: String) -> Bool {
        func searchesForArtifact(_ arguments: Any?) -> Bool {
            guard let arguments, JSONSerialization.isValidJSONObject(arguments),
                  let data = try? JSONSerialization.data(withJSONObject: arguments),
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains(artifact)
        }
        var claudeSearches = Set<String>()
        for event in events(raw) {
            if event["type"] as? String == "item.completed",
               let item = event["item"] as? [String: Any], item["type"] as? String == "mcp_tool_call",
               item["status"] as? String == "completed",
               item["error"] == nil || item["error"] is NSNull,
               let tool = item["tool"] as? String,
               toolMatches(tool, suffix: "search") || toolMatches(tool, suffix: "search_files"),
               searchesForArtifact(item["arguments"]),
               let result = item["result"] as? [String: Any], result["isError"] as? Bool != true {
                return true
            }
            guard let message = event["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                if event["type"] as? String == "assistant", block["type"] as? String == "tool_use",
                   let name = block["name"] as? String,
                   name.hasPrefix("mcp__claude_ai_Google_Drive__"),
                   toolMatches(name, suffix: "search_files"), searchesForArtifact(block["input"]),
                   let id = block["id"] as? String {
                    claudeSearches.insert(id)
                }
                if event["type"] as? String == "user", block["type"] as? String == "tool_result",
                   let id = block["tool_use_id"] as? String, claudeSearches.contains(id),
                   block["is_error"] as? Bool != true { return true }
            }
        }
        return false
    }

    /// `LAB_CMD=probes`: the REAL Gmail/Calendar connection probes, unchanged production code
    /// on the live backend — the 1.4 regression check that the migrated read recipe still
    /// answers YES on a linked account.
    private static func probes() async {
        guard requireConnectorBackend("the probes") else { return }
        let gmail = await ConnectorCensus.checkConnection(slug: "gmail")
        Log("Gmail census → \(gmail)")
        let calendar = await ConnectorCensus.checkConnection(slug: "google-calendar")
        Log("Calendar census → \(calendar)")
    }

    // MARK: routereval (the 1.5 router eval — canned commands through the LIVE router)

    /// What a canned command should route to. The 1.5 bar judges two counters: pure-screen
    /// commands routed to a connector (must be ZERO — that run would fall back, costing a
    /// narration) and pure-connector commands routed to computer (at most TWO — those still
    /// succeed, just on the slower spine). Either-pass rows never count against either.
    private enum ExpectedRoute {
        case connector(String)   // pure connector: must route to this slug
        case screen              // pure screen: connector = HARD FAIL
        case computer            // multi-service / oddball: computer expected
        case either(String)      // connector(slug) is better; computer also passes
    }

    private static func routereval() async {
        guard requireConnectorBackend("the router eval") else { return }
        let fixtures = ProcessInfo.processInfo.environment["LAB_ROUTER_FIXTURES"] == "1"
        guard fixtures || CommandRouter.isActive else {
            Log("skipped: no detected connectors — the router is structurally skipped. Run "
                + "LAB_CMD=census first (or link a connector), then re-run.")
            return
        }
        let services = fixtures ? ["gmail", "google-calendar", "google-drive", "notion", "granola", "slack", "outlook-mail", "outlook-calendar"].compactMap { slug -> CommandRouter.Service? in
            guard let pack = ConnectorRegistry.pack(forSlug: slug) else { return nil }
            return .init(slug: slug, name: pack.displayName, description: pack.routerDescription ?? "")
        } : CommandRouter.routableServices()
        let routable = services.map(\.slug)
        Log("routable services: \(routable.joined(separator: ", "))")

        let calendarDefault: ExpectedRoute = routable.contains("google-calendar") && routable.contains("outlook-calendar")
            ? .computer : (routable.contains("outlook-calendar") ? .connector("outlook-calendar") : .connector("google-calendar"))
        let deck: [(String, ExpectedRoute)] = [
            // Pure connector — the whole task fits one service's tools.
            ("what's on my calendar Friday",                          calendarDefault),
            ("what are the newest files in my Drive",                 .connector("google-drive")),
            ("search Gmail for email about the lease",                .connector("gmail")),
            ("send an email through Gmail to Jesai saying the build is green", .connector("gmail")),
            ("do I have any meetings tomorrow morning",               calendarDefault),
            ("search my drive for the pitch deck and tell me who has access to it",
                                                                      .connector("google-drive")),
            ("when is my next flight? it should be in my Gmail",       .connector("gmail")),
            ("show my Google Calendar events Friday",                 .connector("google-calendar")),
            ("show my Outlook Calendar events Friday",                .connector("outlook-calendar")),
            ("find open time on my Outlook calendar tomorrow",         .connector("outlook-calendar")),
            ("create one Outlook Calendar appointment tomorrow at 3 PM for 15 minutes, no attendees", .connector("outlook-calendar")),
            ("check both Google Calendar and Outlook Calendar tomorrow", .computer),
            ("delete my Outlook Calendar event",                      .computer),
            ("move my Outlook Calendar appointment to Friday",         .computer),
            ("show events from the shared support calendar in Outlook", .computer),
            ("search Outlook for email about the lease",              .connector("outlook-mail")),
            ("create one unsent Outlook draft to alex@example.invalid saying the build is green", .connector("outlook-mail")),
            ("send one Outlook email to alex@example.invalid saying the build is green", .connector("outlook-mail")),
            ("reply in Outlook to the newest email from alex@example.invalid saying yes", .connector("outlook-mail")),
            ("forward the newest Outlook email from alex@example.invalid to pat@example.invalid", .connector("outlook-mail")),
            ("search Outlook and put the meeting on my calendar",      .computer),
            ("attach the PDF on my Desktop to an Outlook email",        .computer),
            ("delete the oldest message from Outlook",                .computer),
            ("search the shared support mailbox in Outlook",           .computer),
            ("reply to this Outlook message on my screen",              .screen),
            ("find the Slack thread about the release decision",      .connector("slack")),
            ("send Jesai a Slack message saying the build is green",  .connector("slack")),
            ("draft a Slack update without sending it",               .connector("slack")),
            // Pure screen — any connector pick here is a hard fail.
            ("click send on this form",                               .screen),
            ("resize this window",                                    .screen),
            ("resize the Slack window",                               .screen),
            ("what's on my screen",                                   .screen),
            ("close all my Chrome tabs",                              .screen),
            ("open Spotify and play my liked songs",                  .screen),
            ("scroll down and screenshot the pricing table",          .screen),
            // Screen-pointing but connector-doable — either passes; connector is better.
            ("reply to this email saying yes",                        .either("gmail")),
            ("add this event to my calendar",                         .either("google-calendar")),
            ("delete my last email",                                  .either("gmail")),
            // Multi-service and zero-context oddballs — computer.
            ("check my email and put the meeting on my calendar",     .computer),
            ("download the contract from Drive and print it",         .computer),
            ("search Slack for the release decision and create a Notion page about it", .computer),
            ("do the thing we talked about",                          .computer),
            ("help",                                                  .computer),
            ("what time is it in Tokyo",                              .computer),
        ]

        let mailOperations: [String: OutlookMailConnector.Operation] = [
            "search Outlook for email about the lease": .read,
            "create one unsent Outlook draft to alex@example.invalid saying the build is green": .draft,
            "send one Outlook email to alex@example.invalid saying the build is green": .send,
            "reply in Outlook to the newest email from alex@example.invalid saying yes": .reply,
            "forward the newest Outlook email from alex@example.invalid to pat@example.invalid": .forward]
        let calendarOperations: [String: OutlookCalendarConnector.Operation] = [
            "show my Outlook Calendar events Friday": .read,
            "find open time on my Outlook calendar tomorrow": .read,
            "create one Outlook Calendar appointment tomorrow at 3 PM for 15 minutes, no attendees": .create]
        let ambiguous: [(String, ExpectedRoute)] = routable.contains("gmail") && routable.contains("outlook-mail")
            ? [("did anyone email me about the lease", .computer), ("search Gmail and Outlook for the lease", .computer)] : []
        var screenToConnector = 0, connectorToComputer = 0, otherMisses = 0, eitherComputer = 0
        var ran = 0, totalMS = 0
        for (command, expected) in deck + ambiguous {
            // A row whose expected slug isn't routable on this machine can't be judged fairly.
            if case .connector(let slug) = expected, !routable.contains(slug) {
                Log("  n/a   \"\(command)\" (expected \(slug) is not routable here)"); continue
            }
            if case .either(let slug) = expected, !routable.contains(slug) {
                Log("  n/a   \"\(command)\" (either-slug \(slug) is not routable here)"); continue
            }
            let t0 = Date()
            let route = await CommandRouter.route(command, services: services)
            if let wanted = mailOperations[command], case .connector(_, _, _, let operation, _) = route, operation != wanted {
                otherMisses += 1; Log("FAIL Outlook operation: expected \(wanted.rawValue)")
            }
            if let wanted = calendarOperations[command], case .connector(_, _, _, _, let operation) = route, operation != wanted {
                otherMisses += 1; Log("FAIL Calendar operation: expected \(wanted.rawValue)")
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            ran += 1; totalMS += ms
            let got: String
            switch route {
            case .computer:                  got = "computer"
            case .connector(let slug, _, _, _, _):    got = "connector(\(slug))"
            }
            let verdict: String
            switch (expected, route) {
            case (.connector(let want), .connector(let slug, _, _, _, _)):
                if slug == want { verdict = "PASS " } else { otherMisses += 1; verdict = "FAIL  (wrong slug)" }
            case (.connector, .computer):
                connectorToComputer += 1; verdict = "miss  (→ computer, counts vs the ≤2 budget)"
            case (.screen, .computer):
                verdict = "PASS "
            case (.screen, .connector):
                screenToConnector += 1; verdict = "HARD FAIL (screen task → connector)"
            case (.computer, .computer):
                verdict = "PASS "
            case (.computer, .connector):
                otherMisses += 1; verdict = "FAIL  (multi/oddball → connector)"
            case (.either(let want), .connector(let slug, _, _, _, _)):
                if slug == want { verdict = "PASS  (the better route)" } else { otherMisses += 1; verdict = "FAIL  (wrong slug)" }
            case (.either, .computer):
                eitherComputer += 1; verdict = "PASS  (acceptable)"
            }
            Log("  \(verdict) \"\(command)\" → \(got) in \(ms)ms")
        }

        Log("\n== scorecard (\(ran) command(s)) ==")
        Log("  screen → connector: \(screenToConnector) (bar: 0)")
        Log("  pure-connector → computer: \(connectorToComputer) (bar: ≤2)")
        Log("  other misroutes: \(otherMisses)")
        Log("  either-pass rows answered computer: \(eitherComputer) (acceptable)")
        Log("  mean router latency: \(ran == 0 ? 0 : totalMS / ran)ms")
        let pass = screenToConnector == 0 && connectorToComputer <= 2 && otherMisses == 0
        Log("== \(pass ? "PASS" : "FAIL"): the 1.5 bar \(pass ? "holds" : "does not hold") ==")
        if !pass { exit(1) }
    }

    // MARK: argv (pure — print every recipe's argv per engine, no model runs)

    /// The recipe-inertness and wall proof: builds canned Invocations and prints the exact
    /// argv each engine would spawn, including the live computer-use argv (the 1.6 wall) and
    /// the CONNECTED SERVICES prompt block. DEBUG-lab only output; the agent argv carries a
    /// placeholder prompt, never real content. Claude resolves slugs through the live
    /// registry/census caches, so run `classify` first for a slug that needs one.
    private static func argv() {
        if let connection = DirectMCPStore.connection(labSlug) {
            NotionCurationTests.arguments(connection)
            return
        }
        let slug = labSlug
        func show(_ label: String, _ args: [String]) {
            Log("\(label):\n    " + args.map { "'\($0)'" }.joined(separator: " "))
        }
        func showClaude(_ label: String, _ inv: CodexCLI.Invocation) {
            do { show(label, try ClaudeCLI.arguments(for: inv, modelID: "sonnet", effortArg: "medium")) }
            catch { Log("\(label): THROWS \(ErrorLabel(error)) (fail-closed refusal)") }
        }
        func showCodex(_ label: String, _ inv: CodexCLI.Invocation, model: String, effort: String) {
            do { show(label, try CodexCLI.arguments(for: inv, modelID: model, effortArg: effort, schemaFile: nil)) }
            catch { Log("\(label): THROWS \(ErrorLabel(error)) (fail-closed refusal)") }
        }

        var plain = CodexCLI.Invocation(prompt: "P")
        plain.feature = "lab"
        var readInv = MCPSource.readInvocation(slug: slug, prompt: "P")
        readInv.feature = "lab"
        var actInv = plain; actInv.mcpActionServer = slug
        if OutlookMailConnector.isMail(slug) { actInv.outlookOperation = .draft }
        if slug == OutlookCalendarConnector.slug { actInv.outlookCalendarOperation = .create }
        var attachInv = plain; attachInv.mcpAttachServer = slug
        // The research read attachment, exactly as ProactiveResearch builds it (1.7): the two
        // chips + every KB-enabled connector.
        var researchInv = plain
        researchInv.mcpReadConnectors = ["gmail", "google-calendar"]
            + ConnectorRegistry.kbEnabledConnectors().map(\.slug)

        Log("-- run() argv, codex column (recipe -c overrides emit on the chatgpt backend only; "
            + "live backend: \(ModelBackend.current.rawValue)) --")
        showCodex("codex plain", plain, model: "gpt-6-sol", effort: "high")
        showCodex("codex read", readInv, model: "gpt-6-luna", effort: "medium")
        showCodex("codex act", actInv, model: "gpt-6-sol", effort: "medium")
        showCodex("codex research read", researchInv, model: "gpt-6-sol", effort: "high")

        Log("-- run() argv, claude column --")
        showClaude("claude plain", plain)
        let claudeRead = ModelBackend.$runOverride.withValue(.claude) { MCPSource.readInvocation(slug: slug, prompt: "P") }
        showClaude("claude read", claudeRead)
        showClaude("claude act", actInv)
        showClaude("claude attach (classifier)", attachInv)
        showClaude("claude research read", researchInv)

        Log("-- computer-use argv (placeholder prompt/socket; the 1.6 wall is live) --")
        show("claude agent",
             try! ClaudeCLI.agentArguments(prompt: "<PROMPT>", modelID: "sonnet", effortArg: "low",
                                      socketPath: "/tmp/lab.sock"))
        show("codex agent",
             CodexCLI.agentArguments(prompt: "<PROMPT>", imagePaths: [], modelID: "gpt-6-sol",
                                     effortArg: "low", socketPath: "/tmp/lab.sock"))

        Log("-- connected services block (live backend: \(ModelBackend.current.rawValue)) --")
        let block = ConnectorRegistry.connectedServicesBlock()
        Log(block.isEmpty ? "(empty: nothing attaches)" : block)
    }

    // MARK: seedcard / firecard (the 1.7 mcp card channel, end to end)

    /// `LAB_CMD=seedcard`: plant one canned card into the real `proactive.latestReady` deck, so
    /// PART 3 can fire it — from the DEV TOOLS "PROACTIVE · EXECUTE" window (notch adoption
    /// included) or headless via `firecard`. Default: an `.mcp` card (LAB_SLUG, default
    /// google-drive). `LAB_METHOD=calendar`: a `.calendar` card instead — the chip-channel
    /// regression proof through the migrated fireConnector plumbing (one private, deletable
    /// test event; no attendees, nothing outward). Harmless and constructive either way.
    private static func seedcard() {
        if ProcessInfo.processInfo.environment["LAB_METHOD"] == "calendar" {
            let event = PreparedAction(
                title: "Connector lab: calendar regression event",
                method: .calendar,
                target: "",
                urgency: .low,
                dueDate: nil,
                status: .confirmed,
                verification: "Lab-seeded card; no live verification ran.",
                cardSummary: "Creates one private 15 minute test event tomorrow afternoon; delete it afterwards.",
                preparedContent: "Title: Sentient connector lab test event\nWhen: tomorrow, 3:00 PM to 3:15 PM (local time)\nAttendees: none\nNotes: Lab regression event. Safe to delete.",
                executionRecipe: "Create ONE event on the user's primary Google Calendar exactly as described in CONTENT: tomorrow 3:00 PM to 3:15 PM local time, no attendees, no invitations. Nothing else.",
                recipient: "",
                buttonText: "Add the test event?",
                detailLabel: "read the event",
                sources: ["Connector lab"],
                reviewNote: "")
            store(event)
            return
        }
        let slug = labSlug
        let action = PreparedAction(
            title: "Connector lab: create a Drive test file",
            method: .mcp,
            target: ConnectorRegistry.displayName(slug: slug),
            methodTarget: slug,
            urgency: .low,
            dueDate: nil,
            status: .confirmed,
            verification: "Lab-seeded card; no live verification ran.",
            cardSummary: "Creates one small test file through your \(ConnectorRegistry.displayName(slug: slug)) connector; safe to delete afterwards.",
            preparedContent: "A Sentient connector-lab test file. Safe to delete.",
            executionRecipe: "Create ONE new file named sentient-connector-lab-card in the user's Google Drive (a Google Doc is fine). Use the CONTENT block as its body if the connector supports body content; if it does not (codex Drive creates empty Docs only), creating the correctly named file alone completes the task. Nothing else.",
            recipient: "",
            buttonText: "Create the test file?",
            detailLabel: "read the file",
            sources: ["Connector lab"],
            reviewNote: "")
        store(action)
    }

    /// The seedcard persist tail: merge the card into the real deck (replacing a same-id
    /// leftover) and say where to fire it from.
    private static func store(_ action: PreparedAction) {
        let existing = ProactiveResearch.latest()
        let ready = (existing?.ready.filter { $0.id != action.id } ?? []) + [action]
        ProactiveResearch.saveLatest(ReadyResult(ready: ready, dropped: existing?.dropped ?? []))
        Log("seeded 1 \(action.method.rawValue)\(action.methodTarget.map { "/\($0)" } ?? "") card into proactive.latestReady (deck now \(ready.count) ready)")
        Log("fire it from DEV TOOLS → PROACTIVE · EXECUTE (or the home), or LAB_CMD=firecard")
    }

    /// `LAB_CMD=firecard`: fire the deck's newest lab card (the last `.mcp` card, or with
    /// LAB_METHOD=calendar the last `.calendar` card) through the REAL executor —
    /// fireConnector on the fired-task recipe, sentinel-parsed, scoreboard-recorded.
    private static func firecard() async {
        let method: PreparedAction.Method =
            ProcessInfo.processInfo.environment["LAB_METHOD"] == "calendar" ? .calendar : .mcp
        guard let action = ProactiveResearch.latest()?.ready.last(where: { $0.method == method }) else {
            Log("no \(method.rawValue) card in proactive.latestReady — run LAB_CMD=seedcard first")
            return
        }
        Log("firing [\(action.method.rawValue)\(action.methodTarget.map { "→\($0)" } ?? "")] \(action.title)")
        Log("isFireable: \(ProactiveExecutor.isFireable(action))")
        let outcome = await ProactiveExecutor.shared.fire(action) { Log("  │ \($0)") }
        switch outcome {
        case .fired(let m):       Log("FIRED: \(m.prefix(300))")
        case .notFireable(let m): Log("NOT FIREABLE: \(m)")
        case .failed(let m):      Log("FAILED: \(m)")
        }
    }

    // MARK: decodecheck (stored-card compatibility, pure)

    /// `LAB_CMD=decodecheck`: a canned 1.x `ReadyResult` (exactly as JSONEncoder persisted it
    /// before `methodTarget` existed) must decode; mcp fireability and the round trip must hold.
    private static func decodecheck() {
        let legacy = """
        {"ready":[{"title":"Reply to Dana","method":"gmail","target":"","urgency":"high",\
        "dueDate":"tomorrow","status":"confirmed","verification":"checked the thread",\
        "cardSummary":"s","preparedContent":"c","executionRecipe":"r","recipient":"Dana",\
        "buttonText":"Send it?","detailLabel":"read the draft","sources":["Gmail"],\
        "reviewNote":""}],"dropped":[]}
        """
        if let data = legacy.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ReadyResult.self, from: data),
           let card = decoded.ready.first {
            Log("PASS  1.x JSON decodes (\(decoded.ready.count) ready)")
            Log("\(card.methodTarget == nil ? "PASS" : "FAIL")  legacy card's methodTarget is nil")
            Log("\(ProactiveExecutor.isFireable(card) ? "PASS" : "FAIL")  legacy gmail card still fireable")
        } else {
            Log("FAIL  1.x JSON did not decode")
        }

        // An mcp card without routing: never a crash, never a live fire button.
        let orphan = PreparedAction(title: "orphan", method: .mcp, target: "", urgency: .medium,
                                    dueDate: nil, status: .unverified, verification: "",
                                    cardSummary: "", preparedContent: "c", executionRecipe: "r",
                                    buttonText: "b", detailLabel: "d", sources: [], reviewNote: "")
        Log("\(ProactiveExecutor.isFireable(orphan) ? "FAIL" : "PASS")  targetless mcp card is not fireable")

        // The round trip: methodTarget survives encode → decode.
        let mcp = PreparedAction(title: "t", method: .mcp, target: "Google Drive",
                                 methodTarget: "google-drive", urgency: .low, dueDate: nil,
                                 status: .confirmed, verification: "", cardSummary: "",
                                 preparedContent: "c", executionRecipe: "r", buttonText: "b",
                                 detailLabel: "d", sources: [], reviewNote: "")
        let trip = (try? JSONEncoder().encode(ReadyResult(ready: [mcp], dropped: [])))
            .flatMap { try? JSONDecoder().decode(ReadyResult.self, from: $0) }?.ready.first
        Log("\(trip?.methodTarget == "google-drive" ? "PASS" : "FAIL")  methodTarget round-trips")

        // The research schema, both variants: zero channels = the shipped four (no mcp anywhere);
        // with a channel = mcp + method_target, still valid JSON.
        func validJSON(_ s: String) -> Bool {
            s.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
        }
        let bare = ProactiveResearch.schema(channels: [])
        let armed = ProactiveResearch.schema(channels:
            [.init(slug: "google-drive", name: "Google Drive", description: nil)])
        Log("\(!bare.contains("mcp") && !bare.contains("method_target") && validJSON(bare) ? "PASS" : "FAIL")  zero-channel schema = shipped four methods, valid JSON")
        Log("\(armed.contains(#""mcp""#) && armed.contains("method_target") && validJSON(armed) ? "PASS" : "FAIL")  channel schema teaches mcp + method_target, valid JSON")
    }

    // MARK: research (the 1.7 research channels, live — one canned Drive-shaped item)

    /// `LAB_CMD=research`: run the REAL PART 2 over one lab-seeded, Drive-shaped action item.
    /// Exercises the migrated read attachment (gmail + gcal + KB-enabled connectors) and, when
    /// Drive is detected, should yield an `mcp`/google-drive card with a sane fire button
    /// (persisted to `proactive.latestReady` — inspect via the dev EXECUTE window or firecard).
    /// A real multi-minute frontier run on the live backend.
    private static func research() async {
        let item = ActionItem(
            title: "Stage the connector brief in Google Drive",
            action: "Create a small text file in the user's Google Drive named 'Sentient connector brief' with a two-line summary of what Sentient's connector feature does",
            importance: "The user asked to keep a short brief of the connector feature in their Drive (lab-seeded item for the channel test)",
            dueDate: nil,
            sources: ["Connector lab"],
            urgency: .low)
        do {
            let result = try await ProactiveResearch.shared.researchAndPrepare(items: [item]) { Log("  │ \($0)") }
            for a in result.ready {
                Log("READY [\(a.method.rawValue)\(a.methodTarget.map { "→\($0)" } ?? "")] \(a.title) · button: \(a.buttonText)")
            }
            for d in result.dropped { Log("DROPPED \(d.title) — \(d.reason)") }
        } catch {
            Log("research failed: \(ErrorLabel(error))")
        }
    }

}

#endif
