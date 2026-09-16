//
//  ConnectorCensus.swift
//  Sentient OS macOS
//
//  Zero-prompt detection of the hosted account connectors the user has ALREADY linked on
//  whichever frontier engine is live (Google Drive, Notion, Slack, …). No model call in the
//  ordinary path, because the two engines answer in completely different ways:
//   - Claude  → run `claude mcp list` and parse the `claude.ai <Name>: <url> - <status>` lines.
//   - codex   → pure disk read of the plugins cache; there is NO codex command that lists
//               hosted connectors (`codex mcp list` shows local config servers only). That
//               cache is rewritten ONLY when codex itself runs, hence the warm run below.
//  Gmail and Google Calendar use this same detection. Their existing source flags mirror the
//  selected engine's census; dedicated chips and reading preferences remain separate.
//
//  Key methods:
//   - list()             → the CURRENT backend's connectors (cheap enough for every pane open)
//   - refresh()          → the same, preceded by the codex warm run (freshness on demand)
//   - cached(for:)       → the last persisted list, no subprocess
//   - startWatching(onChange:) / stopWatching() → the bounded connect-polling window behind
//                          "+ Connect Apps" (runs inside the pane's .task, so closing the pane
//                          cancels it); directoryURL is the engine's connector page it pairs with
//   - listClaude() / listCodex() → the engine-explicit listers. The lab calls these directly so
//                          testing one engine never mutates the user's live backend setting.
//   - parseClaudeList()  → pure (String) -> [DetectedConnector]: the ONE place the unversioned
//                          `claude mcp list` output format is understood.
//
//  Doc: Sources/Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation
import os

nonisolated enum ConnectorCensus {

    // MARK: The detected connector

    /// One hosted connector the user has linked, as seen by ONE origin. `slug` is the canonical
    /// cross-origin identity ("Google Drive" on Claude and the `google-drive` cache directory on
    /// codex both normalize to `google-drive`, verified live 2026-08-27) — every later key hangs
    /// off it, so normalization must stay exact.
    struct DetectedConnector: Codable, Sendable, Equatable, Identifiable {

        /// Where a connector record comes from. Deliberately NOT ModelBackend: Step D adds
        /// direct MCP servers (Sentient-owned OAuth), which have no frontier engine behind
        /// them, and the engine-dispatch enum must never grow a non-engine case. `direct` records come
        /// from DirectMCPStore and are merged by the registry, separately from CLI census.
        enum Origin: String, Codable, Sendable {
            case claude    // a claude.ai account connector (`claude mcp list`)
            case chatgpt   // a ChatGPT account connector (the codex plugins cache)
            case direct    // Step D: a spec-compliant remote MCP server, Sentient-owned OAuth

            /// The origin an engine's census produces — a custom endpoint has no account to
            /// carry connectors, so it maps to none.
            init?(backend: ModelBackend) {
                switch backend {
                case .claude:  self = .claude
                case .chatgpt: self = .chatgpt
                case .custom:  return nil
                }
            }
        }

        let slug: String
        let displayName: String
        let origin: Origin
        /// Hosted Claude or direct remote MCP endpoint; credentials are stored separately.
        let serverURL: String?
        /// codex only: the hosted catalog id (`connector_<32 hex>` or `asdk_app_<32 hex>`), the key the
        /// per-connector `-c` tool strips are addressed by.
        let catalogID: String?
        /// codex only: an absolute path to the connector's logo shipped inside its plugin cache.
        let iconPath: String?
        let healthy: Bool
        let lastSeen: Date

        var id: String { "\(origin.rawValue):\(slug)" }
    }

    // MARK: Identity rules

    /// Detected normally, but keep their dedicated chips, read pipelines and card channels.
    static let dedicatedSourceSlugs: Set<String> = ["gmail", "google-calendar"]

    /// OpenAI's own plumbing entries in the curated cache — not user connectors. There is no
    /// structural way to spot them: `deep-research-work` is a real linked app that also carries
    /// a `connector_openai_*` id, so the id prefix cannot be the discriminator (measured
    /// 2026-08-27). The slug list stays hand-maintained and fail-closed.
    static let codexSystemSlugs: Set<String> = ["openai-templates", "plugin-management"]

    /// The prefix `claude mcp list` puts on every claude.ai connector. Filtering on it drops the
    /// per-run cua-driver entry and any local MCP server the user configured themselves.
    private static let claudePrefix = "claude.ai "

    /// Canonical slug: strip the claude.ai prefix, lowercase, and collapse every run of
    /// non-alphanumeric characters into a single hyphen. "Google Drive" → `google-drive`,
    /// which is byte-identical to codex's own cache directory name for the same connector.
    static func slugify(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix(claudePrefix.lowercased()) {
            name = String(name.dropFirst(claudePrefix.count))
        }
        var slug = ""
        var pendingSeparator = false
        for character in name.lowercased() {
            guard character.isLetter || character.isNumber else { pendingSeparator = true; continue }
            if pendingSeparator && !slug.isEmpty { slug.append("-") }
            pendingSeparator = false
            slug.append(character)
        }
        return slug
    }

    /// The fallback display name when an engine gives us nothing better: `google-drive` →
    /// "Google Drive". Deliberately dumb; the registry (1.2) overrides with curated names.
    static func titleCased(_ slug: String) -> String {
        slug.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: Public API

    /// The live connectors for the CURRENT backend, persisted on the way out. Cheap: one ~2-5 s
    /// subprocess on Claude, microseconds of file reads on codex. Custom endpoints have no
    /// account to carry connectors, so they always answer empty (ModelBackend.connectorsAvailable).
    static func list() async -> [DetectedConnector] {
        switch ModelBackend.current {
        case .claude:
            let connectors = await listClaude()
            guard !Task.isCancelled else { return [] }
            return persist(connectors, for: .claude)
        case .chatgpt: return persist(listCodex(), for: .chatgpt)
        case .custom:
            syncDedicatedSourceStatus()
            return []
        }
    }

    /// `list()` with freshness forced. On codex that means the warm run first: the plugins cache
    /// is rewritten only as a side effect of codex running, so a connector linked seconds ago is
    /// invisible to a pure disk read until something makes codex start (measured end to end
    /// 2026-08-27: linked Google Drive stayed absent, then appeared after one 4 s warm run).
    /// Claude needs no equivalent — `claude mcp list` does its own live fetch every invocation.
    static func refresh() async -> [DetectedConnector] {
        let backend = ModelBackend.current
        if backend == .chatgpt { await refreshCodexCache() }
        guard !Task.isCancelled, ModelBackend.current == backend else { return [] }
        return await list()
    }

    /// The dedicated connect sheets use exactly the same refresh and health verdict as other apps.
    static func checkConnection(slug: String) async -> Bool {
        let backend = ModelBackend.current
        guard let origin = DetectedConnector.Origin(backend: backend) else { return false }
        let connectors = await refresh()
        return !Task.isCancelled && ModelBackend.current == backend
            && connectors.contains { $0.origin == origin && $0.slug == slug && $0.healthy }
    }

    /// Preserve the production keys observed by every source picker and the scheduler. They
    /// are derived connection status, never permission to start reading: dbg.run.* stays untouched.
    /// A missing census (including an older cache without these services) starts disconnected
    /// until the ordinary list completes. Never carry one engine's old YES into another engine.
    static func syncDedicatedSourceStatus(defaults: UserDefaults = .standard) {
        // A lab run may override its engine without changing the user's selected engine.
        let backend = ModelBackend(rawValue: defaults.string(forKey: ModelBackend.key) ?? "") ?? .chatgpt
        let connectors = DetectedConnector.Origin(backend: backend).map { cached(for: $0, defaults: defaults) } ?? []
        for (slug, key) in [("gmail", "dbg.gmail.connected"), ("google-calendar", "dbg.calendar.connected")] {
            let connected = connectors.contains { $0.slug == slug && $0.healthy }
            if defaults.bool(forKey: key) != connected {
                defaults.set(connected, forKey: key)
            }
        }
    }

    /// The last persisted list for an origin — no subprocess, no disk scan. What the UI paints
    /// with immediately while a live `list()` runs behind it. (Blobs persisted before the
    /// origin field existed fail decode and read as empty — dev machines only, nothing shipped;
    /// the next `list()` rewrites them.)
    static func cached(for origin: DetectedConnector.Origin, defaults: UserDefaults = .standard) -> [DetectedConnector] {
        guard let key = storageKey(for: origin),
              let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([DetectedConnector].self, from: data)
        else { return [] }
        return logicalServices(decoded)
    }

    /// The observed provider identity remains in the endpoint/catalog fields. Outlook's
    /// logical mail service owns its own policy and checkpoint; connecting Microsoft's suite
    /// must not silently enroll Calendar, Teams or files into the mail knowledge source.
    static func logicalService(_ connector: DetectedConnector) -> DetectedConnector {
        let isOutlook = connector.origin == .chatgpt && connector.slug == OutlookMailConnector.codexSlug
            || connector.origin == .claude && connector.displayName == OutlookMailConnector.claudeName
                && connector.serverURL == OutlookMailConnector.claudeURL
        guard isOutlook else { return connector }
        return DetectedConnector(slug: OutlookMailConnector.slug, displayName: "Outlook Mail",
            origin: connector.origin, serverURL: connector.serverURL, catalogID: connector.catalogID,
            iconPath: connector.iconPath, healthy: connector.healthy, lastSeen: connector.lastSeen)
    }

    /// Project the suite into distinct opt-in sources without duplicating already-normalized
    /// cache records. The endpoint remains physical; toggles and checkpoints remain logical.
    static func logicalServices(_ connectors: [DetectedConnector]) -> [DetectedConnector] {
        var seen = Set<String>()
        var result: [DetectedConnector] = []
        for original in connectors {
            let connector = logicalService(original)
            let suite = connector.origin == .claude && connector.serverURL == Microsoft365Connector.url
                && (connector.displayName == Microsoft365Connector.name || Microsoft365Connector.contains(connector.slug))
            let slugs = suite ? [OutlookMailConnector.slug, "outlook-calendar"] : [connector.slug]
            for slug in slugs {
                let record = DetectedConnector(slug: slug,
                    displayName: suite ? (slug == OutlookMailConnector.slug ? "Outlook Mail" : "Outlook Calendar") : connector.displayName,
                    origin: connector.origin, serverURL: connector.serverURL, catalogID: connector.catalogID,
                    iconPath: connector.iconPath, healthy: connector.healthy, lastSeen: connector.lastSeen)
                if seen.insert(record.id).inserted { result.append(record) }
            }
        }
        return result
    }

    // MARK: Watch mode (the "+ Connect Apps" polling window)

    /// The engine's connector directory page — where "+ Connect Apps" sends the user to link a
    /// new app (GmailConnect.connectorURL's engine-switch pattern; the chatgpt anchor is the
    /// same settings route ConnectAIsView already uses). Custom backends never reach here: the
    /// Connectors section renders locked there.
    static var directoryURL: URL {
        ModelBackend.current == .claude
            ? URL(string: "https://claude.ai/new#settings/customize-connectors/directory")!
            : URL(string: "https://chatgpt.com/plugins#settings/Connectors")!
    }

    /// One watch window at a time: starting (or an explicit stop) bumps the generation, and any
    /// older loop exits at its next check.
    private static let watchGeneration = OSAllocatedUnfairLock(initialState: 0)

    /// Poll the live engine until a NEW connector appears, so its pill can arrive on its own the
    /// moment the user finishes linking on the website. Designed to run inside the pane's
    /// `.task(id:)`: cancellation is the leak-proofing, so a closed pane stops the polling with
    /// no cleanup call, and a 10 minute ceiling stops it regardless — it never runs outside an
    /// explicit start. Claude re-lists every ~5 s (each list is its own live fetch); codex needs
    /// the warm run to rewrite its cache, so it cycles every ~25 s (the warm run carries ~13k
    /// input tokens, mostly cached — measured 2026-08-27 — which is why the interval stays
    /// coarse). `onChange` fires on EVERY visible change (health flips and removals render live
    /// too); a slug that was absent at watch start is what ends the window.
    static func startWatching(onChange: @escaping @MainActor ([DetectedConnector]) -> Void) async {
        guard let origin = DetectedConnector.Origin(backend: ModelBackend.current) else { return }
        let generation = watchGeneration.withLock { $0 += 1; return $0 }
        let deadline = Date().addingTimeInterval(10 * 60)
        let baseline = Set(cached(for: origin).map(\.slug))
        var lastDelivered = fingerprint(cached(for: origin))
        Log("ConnectorCensus.watch: started (\(origin.rawValue), \(baseline.count) known)")

        while true {
            if Task.isCancelled {
                Log("ConnectorCensus.watch: stopped (cancelled)"); return
            }
            if watchGeneration.withLock({ $0 }) != generation {
                Log("ConnectorCensus.watch: stopped (superseded)"); return
            }
            if Date() >= deadline {
                Log("ConnectorCensus.watch: stopped (timeout)"); return
            }
            guard DetectedConnector.Origin(backend: ModelBackend.current) == origin else {
                Log("ConnectorCensus.watch: stopped (backend changed)"); return
            }

            let connectors = origin == .claude ? await list() : await refresh()
            if fingerprint(connectors) != lastDelivered, !Task.isCancelled {
                lastDelivered = fingerprint(connectors)
                await onChange(connectors)
            }
            if connectors.contains(where: { !baseline.contains($0.slug) }) {
                Log("ConnectorCensus.watch: stopped (new connector)"); return
            }
            try? await Task.sleep(for: .seconds(origin == .claude ? 5 : 25))
        }
    }

    /// End any active watch window from outside the owning task.
    static func stopWatching() {
        watchGeneration.withLock { $0 += 1 }
    }

    /// What "changed" means to the watcher: identity, name, and health — never `lastSeen`,
    /// which every listing rewrites (comparing it would fire onChange on every tick).
    private static func fingerprint(_ connectors: [DetectedConnector]) -> [String] {
        connectors.map { "\($0.id)|\($0.displayName)|\($0.healthy)" }
    }

    // MARK: Persistence

    /// Production keys (the dbg.* law: never renamed without a migration).
    private static func storageKey(for origin: DetectedConnector.Origin) -> String? {
        switch origin {
        case .claude:  return "mcp.connectors.claude"
        case .chatgpt: return "mcp.connectors.chatgpt"
        case .direct:  return nil   // DirectMCPStore owns this tier; it is not a CLI census.
        }
    }

    /// Internal (not private): the lab's census command persists the engine-explicit listers'
    /// results through the same seam `list()` uses, so the per-origin caches stay honest on a
    /// machine whose live backend never runs one of the engines.
    @discardableResult
    static func persist(_ connectors: [DetectedConnector],
                        for origin: DetectedConnector.Origin,
                        defaults: UserDefaults = .standard) -> [DetectedConnector] {
        let connectors = logicalServices(connectors)
        guard let key = storageKey(for: origin),
              let data = try? JSONEncoder().encode(connectors) else { return connectors }
        let old = cached(for: origin, defaults: defaults)
        let previous = old.count
        // A detected disappearance/reappearance invalidates incremental provenance without
        // deleting pending notes. False-negative census results only cause a safe backfill.
        let changed = Set(old.map(\.slug)).symmetricDifference(Set(connectors.map(\.slug)))
        for slug in changed where ConnectorRegistry.pack(forSlug: slug) != nil {
            let generationKey = ConnectorRegistry.readGenerationKey(slug, origin.rawValue)
            defaults.set(defaults.integer(forKey: generationKey) + 1, forKey: generationKey)
        }
        defaults.set(data, forKey: key)
        syncDedicatedSourceStatus(defaults: defaults)
        // Telemetry: the detected count per engine, ints only, and only when the count actually
        // changed (a steady watch tick or pane open stays silent — this fires on link/unlink).
        if connectors.count != previous {
            Analytics.signal("Connector.census", parameters: [
                "origin": origin.rawValue, "count": String(connectors.count)])
        }
        return logicalServices(connectors)
    }

    // MARK: Claude — `claude mcp list`

    /// Run `claude mcp list` and parse its stdout. The command health-checks every server live,
    /// so it is the slow lister (seconds, and the timeout is generous for a bad network).
    /// stderr carries schema-warning noise on some CLI versions: never parsed, never logged.
    static func listClaude() async -> [DetectedConnector] {
        guard let binary = ClaudeCLI.locateBinary() else {
            Log("ConnectorCensus.claude: no claude binary")
            return []
        }
        // The sanitized env this plumbing builds carries only HOME/USER/PATH, so a dev shell
        // exporting CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 can't reach the child — but the
        // empty-string pin in baseEnv is what guarantees it, and that flag suppresses the
        // claude.ai connector fetch entirely (every probe would read an honest-but-wrong empty).
        guard let out = try? await CodexCLI.executeAsync(binary: binary, args: ["mcp", "list"],
                                                         stdinText: nil, cwd: nil, timeout: 60,
                                                         extraEnv: ClaudeCLI.baseEnv) else {
            Log("ConnectorCensus.claude: mcp list failed to run")
            return []
        }
        return parseClaudeList(out.stdout)
    }

    /// The ONE place `claude mcp list`'s output format is understood — pure, so the lab can
    /// exercise it against canned strings. Anything that is not a `claude.ai …` line (the
    /// "Checking MCP server health…" banner, blank lines, the per-run cua-driver entry, local
    /// servers) is ignored. A malformed line is skipped, never thrown: the CLI's output is
    /// unversioned, so a drift must degrade to "fewer connectors", never to a crash.
    static func parseClaudeList(_ stdout: String) -> [DetectedConnector] {
        let now = Date()
        var connectors: [DetectedConnector] = []
        var candidates = 0

        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(claudePrefix) else { continue }
            candidates += 1

            // "<Name>: <url> - <status>"; the name can't contain ": " but the URL contains "://",
            // so the name ends at the FIRST ": " and the status begins at the LAST " - ".
            let body = String(line.dropFirst(claudePrefix.count))
            guard let nameEnd = body.range(of: ": ") else { continue }
            let name = String(body[body.startIndex..<nameEnd.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let remainder = String(body[nameEnd.upperBound...])
            let url: String
            let status: String
            if let statusStart = remainder.range(of: " - ", options: .backwards) {
                url = String(remainder[remainder.startIndex..<statusStart.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                status = String(remainder[statusStart.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                url = remainder.trimmingCharacters(in: .whitespaces)
                status = ""
            }

            let slug = slugify(name)
            guard !slug.isEmpty else { continue }
            connectors.append(DetectedConnector(slug: slug,
                                                displayName: name,
                                                origin: .claude,
                                                serverURL: url.isEmpty ? nil : url,
                                                catalogID: nil,
                                                iconPath: nil,
                                                healthy: isConnected(status),
                                                lastSeen: now))
        }

        let excluded = candidates - connectors.count
        if excluded > 0 {
            // A claude.ai line was dropped: the output format may have drifted.
            // Report the shape, never the content.
            Log("ConnectorCensus.claude: parsed \(connectors.count) of \(candidates) claude.ai lines")
        }
        return logicalServices(connectors)
    }

    /// Read the health word, not the whole status: "✔ Connected" is healthy while "✘ Disconnected"
    /// must not be (a naive `contains("connected")` reads both as YES).
    private static func isConnected(_ status: String) -> Bool {
        status.drop(while: { !$0.isLetter }).lowercased().hasPrefix("connected")
    }

    // MARK: codex — the plugins cache on disk

    /// Where codex records the account's linked apps. The sibling `created-by-me-remote/` holds
    /// the user's own custom apps and is skipped entirely (hidden in v1).
    private static var codexCacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/plugins/cache/openai-curated-remote")
    }

    /// Scan the plugins cache. Presence IS the verdict — codex has no health probe — so every
    /// connector found reads healthy. Pure disk reads: no subprocess, no model, microseconds.
    static func listCodex(cacheRoot: URL = codexCacheRoot) -> [DetectedConnector] {
        let fm = FileManager.default
        guard let slugs = try? fm.contentsOfDirectory(atPath: cacheRoot.path) else { return [] }
        let now = Date()
        var connectors: [DetectedConnector] = []

        for slug in slugs.sorted() where !slug.hasPrefix(".") {
            guard !codexSystemSlugs.contains(slug) else { continue }
            let slugDir = cacheRoot.appendingPathComponent(slug)
            guard let versionDir = newestVersionDirectory(in: slugDir),
                  let catalogID = catalogID(in: versionDir, slug: slug) else { continue }
            let card = infoCard(in: versionDir)
            connectors.append(DetectedConnector(slug: slug,
                                                displayName: card.displayName ?? titleCased(slug),
                                                origin: .chatgpt,
                                                serverURL: nil,
                                                catalogID: catalogID,
                                                iconPath: card.iconPath,
                                                healthy: true,
                                                lastSeen: now))
        }
        return logicalServices(connectors)
    }

    /// The newest version directory, compared NUMERICALLY per component: a string sort reads
    /// `0.1.9` as newer than `0.1.15`, and both shapes are live in the cache today.
    private static func newestVersionDirectory(in slugDir: URL) -> URL? {
        let fm = FileManager.default
        guard let versions = try? fm.contentsOfDirectory(atPath: slugDir.path) else { return nil }
        let newest = versions.filter { !$0.hasPrefix(".") }
            .max { versionComponents($0).lexicographicallyPrecedes(versionComponents($1)) }
        return newest.map { slugDir.appendingPathComponent($0) }
    }

    /// "0.1.15" → [0, 1, 15]. Non-numeric junk in a component reads as 0 rather than failing.
    private static func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// `.app.json` → `apps.<slug>.id`. Keyed by the directory slug first; when that key is
    /// absent and the file describes exactly one app, that app is taken instead (the two system
    /// entries name their app differently from their directory, so a strict lookup would only
    /// filter them by accident — the explicit skip list above is what actually does it).
    private static func catalogID(in versionDir: URL, slug: String) -> String? {
        let url = versionDir.appendingPathComponent(".app.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = root["apps"] as? [String: Any] else { return nil }
        var entry = apps[slug].flatMap { $0 as? [String: Any] }
        if entry == nil, apps.count == 1 {
            entry = apps.values.first.flatMap { $0 as? [String: Any] }
        }
        guard let id = entry?["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// What the connector calls itself, and where its logo sits — read from the plugin's own
    /// `.codex-plugin/plugin.json`. Only `displayName` and the logo are taken: the card's
    /// `capabilities` field is decorative and must never inform tool policy (Google Drive
    /// declares "Write" and omits "Read" while being almost entirely read tools, measured
    /// 2026-08-27), and the classifier (1.2) is the only real answer to what a tool does.
    private static func infoCard(in versionDir: URL) -> (displayName: String?, iconPath: String?) {
        let url = versionDir.appendingPathComponent(".codex-plugin/plugin.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let interface = root["interface"] as? [String: Any] else { return (nil, nil) }

        let name = (interface["displayName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var iconPath: String?
        for key in ["logo", "composerIcon"] {
            guard let relative = interface[key] as? String, !relative.isEmpty else { continue }
            let cleaned = relative.hasPrefix("./") ? String(relative.dropFirst(2)) : relative
            let candidate = versionDir.appendingPathComponent(cleaned)
            if FileManager.default.fileExists(atPath: candidate.path) {
                iconPath = candidate.path
                break
            }
        }
        return (name?.isEmpty == false ? name : nil, iconPath)
    }

    /// Force the plugins cache to be current. codex rewrites it as a side effect of running, and
    /// nothing else does, so one throwaway turn on the cheapest tier is the whole mechanism
    /// (measured 4 s; it carries ~13k input tokens of connector tool schemas, mostly cached, so
    /// callers that poll should do so sparingly). Failures are logged and swallowed: a warm run
    /// that could not happen just means the following read may be stale, never an error the user
    /// should see. Runs as `trigger=probe` so a failure is never filed as an analysis failure.
    static func refreshCodexCache() async {
        var invocation = CodexCLI.Invocation(prompt: "Reply with exactly: OK")
        invocation.feature = "census"
        invocation.model = .gpt56luna
        invocation.effort = .low
        invocation.sandbox = .readOnly
        invocation.webSearch = false
        invocation.timeout = 120
        do {
            _ = try await CodexTrigger.$current.withValue(.probe) {
                try await ModelBackend.$runOverride.withValue(.chatgpt) {
                    try await FrontierRun.run(invocation)
                }
            }
        } catch {
            Log("ConnectorCensus.warm: \(ErrorLabel(error))")
        }
    }
}
