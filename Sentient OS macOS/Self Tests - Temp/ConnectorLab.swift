//
//  ConnectorLab.swift
//  Sentient OS macOS
//
//  The connector-lab harness: exercises the real ConnectorCensus against the real machine,
//  headless. Grows across tasks 1.2 / 1.4 / 1.5 (tool dumps, classification, trial runs) and
//  is deleted at Step 4.
//
//  Run:  SENTIENT_SELFTEST=connectorlab LAB_CMD=census  "<Debug>/Sentient OS.app/Contents/MacOS/Sentient OS"
//  Commands: census (both engines, explicitly) · parse (canned strings) · warm (the codex warm run)
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
        case "census": await census()
        case "parse":  parse()
        case "warm":   await warm()
        default:       Log("unknown LAB_CMD '\(command)' (census | parse | warm)")
        }
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
        let cached = ConnectorCensus.cached(for: ModelBackend.current)
        Log("cached(for: \(ModelBackend.current.rawValue)) → \(cached.count) connector(s), "
            + "matches live: \(cached.map(\.slug) == live.map(\.slug))")

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
}
