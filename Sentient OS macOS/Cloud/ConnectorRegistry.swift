//
//  ConnectorRegistry.swift
//  Sentient OS macOS
//
//  The identity and policy layer over ConnectorCensus: which detected connector is which
//  (curated packs for the named connectors, synthesized identity for everything else), what its
//  tools are allowed to do (hand-curated read lists for the knowledge base, the classifier's
//  cache for action policy), and the per-connector "Use for knowledge base" toggle, which
//  exists ONLY for curated connectors — everything else is task-use only. Gmail and Google
//  Calendar live here as identity-only packs: they keep their dedicated chips and never join
//  the Connectors UI, but chip-filtering and the classifier eval need their identities.
//
//  Key surface:
//   - packs / pack(for:)                  → the curated packs and the detected→pack match
//   - server(for:)                        → the ONE slug → per-engine server resolution seam
//                                           (every recipe builder resolves through it; Step D
//                                           extends it with the direct tier)
//   - claudeIdentity(slug:)               → name + server URL + tool prefix (the classifier's input)
//   - computerUseAttachable()             → the candidate list a computer-use run may attach
//   - computerUseAttachments()            → the FINAL attach set + deny lists (fail-closed)
//   - connectedServicesBlock()            → the prompt teaching both computer-use wrappers splice
//   - readToolNames / destructiveToolNames / allKnownToolNames → full tool names, per policy
//   - kbEligible / isKBEnabled / setKBEnabled / kbEnabledConnectors → the `mcp.<slug>.kb` toggle
//   - classification(for:) / saveClassification        → the `mcp.classified.<slug>` cache
//
//  Doc: Sources/Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation

nonisolated enum ConnectorRegistry {

    // MARK: The curated pack shape

    /// How the KB read engine (task 1.8) windows a connector's history. Placeholder shape —
    /// the Step 3 chats enrich per connector.
    enum KBAdapter: String, Sendable {
        case windowedWeekly    // gmail-style: the last month as weekly windows, then since-mark
        case windowedMonthly   // calendar-style: the last year as monthly windows, then since-mark
        case generic           // one budgeted "what's new" read (the default until a Step 3 chat tunes the pack)
    }

    /// One hand-curated connector: identity on both engines plus the verified read surface.
    /// Step D adds a direct MCP URL field here (granola and notion curate against the direct
    /// tier — `mcp.granola.ai/mcp`, `mcp.notion.com/mcp`); do not invent a second home for it.
    struct CuratedConnector: Sendable {
        var slug: String
        var displayName: String
        /// One line for the command router's CONNECTED SERVICES list (task 1.5): short and
        /// factual, tuned only against the router eval. nil (uncurated) = name rides alone.
        var routerDescription: String? = nil
        // Per-engine identity (nil = not yet captured; the Step 3 chats fill these).
        var claudeName: String? = nil        // as `claude mcp list` prints it, minus "claude.ai "
        var claudeServerURL: String? = nil
        var claudeToolPrefix: String? = nil  // e.g. "mcp__claude_ai_Google_Drive__"
        var codexSlug: String? = nil         // the plugins-cache directory name
        var codexCatalogID: String? = nil    // the global marketplace id (census supplies it live
                                             // for detected connectors; pinned here only for the
                                             // two chip connectors the census excludes)
        /// BARE Claude tool names; the Claude query layer adds the server prefix.
        /// nil = not yet curated → kbEligible is false: no KB toggle, no KB reads.
        var readTools: [String]? = nil
        /// Codex tool names/titles, verified separately from Claude's surface. A missing list
        /// refuses Codex unattended reads; never infer it from the Claude classifier cache.
        var codexReadTools: [String]? = nil
        var kbAdapter: KBAdapter = .generic
        /// True while the read list is a captured-but-unverified surface — the Step 3 chats
        /// mark fresh captures with it until their live re-verify confirms them.
        var capturedProvisional = false
    }

    /// Strip a curated full-name list back to bare names — the ConnectorTools REFERENCE, not a
    /// copy: `readToolNames` re-prefixes these, so the round trip returns those arrays verbatim
    /// and the one source of truth stays `ClaudeCLI.ConnectorTools`.
    private static func bare(_ fullNames: [String], prefix: String) -> [String] {
        fullNames.map { String($0.dropFirst(prefix.count)) }
    }

    /// The curated packs. gmail + google-calendar are identity-only (dedicated chips; excluded
    /// from every census result); Drive has verified read lists, with prompt curation separate.
    /// Codex lists were checked against hosted descriptions using CLI 0.154.0. Names/titles
    /// intentionally differ from Claude's; new tools require another manual review.
    /// The other six are named-but-empty until their Step 3 chats.
    static let packs: [CuratedConnector] = [
        CuratedConnector(slug: "gmail", displayName: "Gmail",
                         routerDescription: "read, search, and send the user's email; drafts and labels",
                         claudeName: "Gmail",
                         claudeServerURL: "https://gmailmcp.googleapis.com/mcp/v1",
                         claudeToolPrefix: "mcp__claude_ai_Gmail__",
                         codexSlug: "gmail",
                         codexCatalogID: CodexCLI.Invocation.gmailCatalogID,
                         readTools: bare(ClaudeCLI.ConnectorTools.gmailReads,
                                         prefix: "mcp__claude_ai_Gmail__"),
                         codexReadTools: ["search_email_ids", "search_emails", "read_email",
                                          "read_email_thread", "batch_read_email",
                                          "batch_read_email_threads", "list_drafts", "list_labels"],
                         kbAdapter: .windowedWeekly),
        CuratedConnector(slug: "google-calendar", displayName: "Google Calendar",
                         routerDescription: "read the user's calendars and events; create, update, and RSVP",
                         claudeName: "Google Calendar",
                         claudeServerURL: "https://calendarmcp.googleapis.com/mcp/v1",
                         claudeToolPrefix: "mcp__claude_ai_Google_Calendar__",
                         codexSlug: "google-calendar",
                         codexCatalogID: CodexCLI.Invocation.calendarCatalogID,
                         readTools: bare(ClaudeCLI.ConnectorTools.calendarReads,
                                         prefix: "mcp__claude_ai_Google_Calendar__"),
                         codexReadTools: ["search", "search_events", "fetch", "read_event",
                                          "batch_read_event", "list_calendars", "get_availability"],
                         kbAdapter: .windowedMonthly),
        // Drive's read list was captured live 2026-08-26 and re-verified 2026-08-29 (the
        // classifier eval). The live surface has since GROWN server-side (new write/destructive
        // tools appeared within days — why the classifier cache carries a weekly TTL); the six
        // curated reads below remain the verified read surface, and the destructive denies
        // always come from the live classifier cache, never from this pack.
        CuratedConnector(slug: "google-drive", displayName: "Google Drive",
                         routerDescription: "search, read, and create files in the user's Google Drive",
                         claudeName: "Google Drive",
                         claudeServerURL: "https://drivemcp.googleapis.com/mcp/v1",
                         claudeToolPrefix: "mcp__claude_ai_Google_Drive__",
                         codexSlug: "google-drive",
                         readTools: ["search_files", "read_file_content", "download_file_content",
                                     "get_file_metadata", "get_file_permissions",
                                     "list_recent_files"],
                         codexReadTools: ["search", "fetch", "recent_documents", "get_file_metadata",
                                          "list_file_revisions", "fetch_file_revision", "get_profile"]),
        CuratedConnector(slug: "slack", displayName: "Slack"),
        CuratedConnector(slug: "notion", displayName: "Notion"),
        CuratedConnector(slug: "granola", displayName: "Granola"),
        CuratedConnector(slug: "outlook-mail", displayName: "Outlook Mail"),
        CuratedConnector(slug: "outlook-calendar", displayName: "Outlook Calendar"),
        CuratedConnector(slug: "teams", displayName: "Teams"),
    ]

    // MARK: Identity

    static func pack(forSlug slug: String) -> CuratedConnector? {
        packs.first { $0.slug == slug }
    }

    /// Match a detected connector to its curated pack. Census slugs ARE the canonical identity
    /// (slugify makes a pack's claudeName and its codex cache directory converge on the same
    /// slug, verified live 2026-08-27), so slug equality is the whole match; the per-engine
    /// fields exist for building walls and prefixes, not for matching. nil = uncurated.
    static func pack(for connector: ConnectorCensus.DetectedConnector) -> CuratedConnector? {
        pack(forSlug: connector.slug)
    }

    /// One connector as the run recipes address it on each engine. Every field is optional
    /// because a connector can exist on one engine only (drive was Claude-only for a while).
    /// Step D extends THIS shape with the direct tier's server URL + Keychain credential
    /// reference — the resolver below stays the one seam, never a parallel path.
    struct ResolvedServer: Sendable {
        let slug: String
        let claudeName: String?
        let claudeServerURL: String?
        let claudeToolPrefix: String?
        let codexCatalogID: String?
    }

    /// The ONE slug → server resolution seam. Every recipe builder (ClaudeCLI / CodexCLI
    /// argument construction) resolves a slug through here and nowhere else. Pack fields win
    /// (gmail/google-calendar are census-EXCLUDED, so their pinned identities are the only
    /// source); the census fills in whatever the packs don't pin (a detected connector's live
    /// URL or catalog id). nil = the slug matches no pack and no census record.
    static func server(for slug: String) -> ResolvedServer? {
        let pack = pack(forSlug: slug)
        let claude = ConnectorCensus.cached(for: .claude).first { $0.slug == slug }
        let codex = ConnectorCensus.cached(for: .chatgpt).first { $0.slug == slug }
        guard pack != nil || claude != nil || codex != nil else { return nil }
        let name = pack?.claudeName ?? claude?.displayName
        return ResolvedServer(slug: slug,
                              claudeName: name,
                              claudeServerURL: pack?.claudeServerURL ?? claude?.serverURL,
                              claudeToolPrefix: pack?.claudeToolPrefix
                                  ?? name.map(derivedClaudePrefix(from:)),
                              codexCatalogID: pack?.codexCatalogID ?? codex?.catalogID)
    }

    /// The Claude-side identity the classifier needs to wall a connector in alone: display
    /// name, server URL, and tool prefix. A convenience view over `server(for:)` — nil when
    /// there is no known claude.ai endpoint (unclassifiable until seen).
    static func claudeIdentity(slug: String) -> (name: String, serverURL: String, toolPrefix: String)? {
        guard let resolved = server(for: slug),
              let name = resolved.claudeName,
              let url = resolved.claudeServerURL,
              let prefix = resolved.claudeToolPrefix else { return nil }
        return (name, url, prefix)
    }

    /// The connectors a widened computer-use run may attach on the Claude engine (task 1.6
    /// flips the attachment on; 1.4 builds it dormant): every detected claude-origin connector
    /// that is curated or classified (unclassified = excluded, fail-closed), PLUS the two
    /// dedicated-chip connectors when their chips are connected (the census excludes them, so
    /// the general mechanism must union them in — gmail riding into computer use is shipped
    /// behavior this must preserve). Order: chips first, then detected, so argv stays stable.
    static func computerUseAttachable() -> [ResolvedServer] {
        var slugs: [String] = []
        if UserDefaults.standard.bool(forKey: "dbg.gmail.connected") { slugs.append("gmail") }
        if UserDefaults.standard.bool(forKey: "dbg.calendar.connected") { slugs.append("google-calendar") }
        slugs += ConnectorCensus.cached(for: .claude)
            .filter { pack(for: $0)?.readTools != nil || isClassified($0.slug) }
            .map(\.slug)
        return slugs.compactMap { server(for: $0) }
    }

    /// One connector as a computer-use run actually attaches it: the resolved server, the deny
    /// list its bypass run carries, and whether it rides read-only (the unclassified-gmail
    /// fallback described on computerUseAttachments).
    struct ComputerUseAttachment: Sendable {
        let server: ResolvedServer
        let denies: [String]
        let readOnly: Bool
    }

    /// The FINAL attach set for a computer-use run (task 1.6): computerUseAttachable() gated
    /// fail-closed through the one deny-list rule. A bypass run auto-approves every tool it can
    /// see, so a connector may only attach when a REAL deny list can be built for it:
    ///  · classified → its destructive verdicts are denied and constructive writes stay LIVE
    ///    (the deliberate posture change, README decision #13);
    ///  · unclassified gmail → the hand-curated write-deny complement
    ///    (ClaudeCLI.ConnectorTools.gmailWriteDenies): gmail keeps riding in read-only, exactly
    ///    the shipped posture, until the classifier sweep catches up;
    ///  · anything else unclassified → NOT attached, counted in `excluded` (transient: the
    ///    idle-tick sweep, ConnectorClassifier.sweepComputerUseAttachables, classifies the whole
    ///    candidate list within minutes of launch).
    /// Both consumers — the Claude wall in agentArguments and the CONNECTED SERVICES prompt
    /// block — read THIS function, so the prompt can never promise a server the wall excluded.
    static func computerUseAttachments() -> (attached: [ComputerUseAttachment], excluded: Int) {
        var attached: [ComputerUseAttachment] = []
        var excluded = 0
        for server in computerUseAttachable() {
            guard server.claudeServerURL != nil else { excluded += 1; continue }
            if isClassified(server.slug) {
                attached.append(.init(server: server,
                                      denies: destructiveToolNames(slug: server.slug),
                                      readOnly: false))
            } else if server.slug == "gmail" {
                attached.append(.init(server: server,
                                      denies: ClaudeCLI.ConnectorTools.gmailWriteDenies,
                                      readOnly: true))
            } else {
                excluded += 1
            }
        }
        return (attached, excluded)
    }

    /// A connector's user-facing name: the curated pack's, else the census's, else the slug
    /// title-cased.
    static func displayName(slug: String) -> String {
        if let pack = pack(forSlug: slug) { return pack.displayName }
        return (ConnectorCensus.cached(for: .claude) + ConnectorCensus.cached(for: .chatgpt))
            .first { $0.slug == slug }?.displayName ?? ConnectorCensus.titleCased(slug)
    }

    /// The closed-vocabulary telemetry label for a slug: curated slugs name themselves; every
    /// uncurated connector reports the literal "other". Uncurated names can be user-authored
    /// (custom connectors), and telemetry carries structure only — every telemetry sink that
    /// tags a slug goes through here (the executor's channel label, the router, the KB reads).
    static func telemetrySlug(_ slug: String) -> String {
        pack(forSlug: slug) != nil ? slug : "other"
    }

    // MARK: The CONNECTED SERVICES prompt block (task 1.6)

    /// The teaching both computer-use wrappers splice in: which services' tools are REALLY in
    /// this run, and the standing instruction to prefer them over driving an app's UI. Built
    /// per run from the live attach set, per engine:
    ///  · claude → computerUseAttachments() (the exact set the wall admits, so the prompt and
    ///    the argv can never disagree; a read-only fallback entry says so on its line, and the
    ///    send-email example only appears when gmail's writes are actually live);
    ///  · chatgpt → the chips when connected + every census codex-origin connector (hosted
    ///    connectors ride hermetic codex runs whole; only destructive tools are stripped);
    ///  · custom → "" (BYOM has no account to carry connectors).
    /// "" when nothing attaches, so callers splice nothing. Schema cost is ~1.5k tokens per
    /// connector on Claude (measured 2026-08-27); a 10+-connector account is Step 4's problem.
    static func connectedServicesBlock() -> String {
        struct Entry { let slug: String; let name: String; let note: String? }
        var entries: [Entry] = []
        var gmailWritesLive = false
        switch ModelBackend.current {
        case .custom:
            return ""
        case .claude:
            for attachment in computerUseAttachments().attached {
                let slug = attachment.server.slug
                if slug == "gmail", !attachment.readOnly { gmailWritesLive = true }
                entries.append(Entry(slug: slug, name: displayName(slug: slug),
                                     note: attachment.readOnly
                                         ? "read-only in this run"
                                         : pack(forSlug: slug)?.routerDescription))
            }
        case .chatgpt:
            var slugs: [String] = []
            if UserDefaults.standard.bool(forKey: "dbg.gmail.connected") { slugs.append("gmail") }
            if UserDefaults.standard.bool(forKey: "dbg.calendar.connected") { slugs.append("google-calendar") }
            slugs += ConnectorCensus.cached(for: .chatgpt).map(\.slug)
            gmailWritesLive = slugs.contains("gmail")
            entries = slugs.map { Entry(slug: $0, name: displayName(slug: $0),
                                        note: pack(forSlug: $0)?.routerDescription) }
        }
        guard !entries.isEmpty else { return "" }
        let list = entries.map { entry in
            entry.note.map { "- \(entry.slug): \(entry.name) (\($0))" }
                ?? "- \(entry.slug): \(entry.name)"
        }.joined(separator: "\n")
        let example = gmailWritesLive
            ? " (send email through the Gmail tools, never by driving a mail app's window)."
            : "."
        let block = """
        CONNECTED SERVICES (real tools available in this run):
        \(list)

        Whenever a step of the task can be completed by one of these services' tools, use the tool instead of driving an app's UI; it is faster and more reliable\(example)
        - Sending, creating, or updating through a service is allowed ONLY as part of what the user asked for.
        - Destructive tools do not exist in this run.
        - If a service's tools cannot finish a step, fall back to the screen and do it there.
        """
        Log("connected services: \(entries.count) service(s) in the prompt block")
        #if DEBUG
        Log("connected services block: +\(block.utf8.count) bytes")
        #endif
        return block
    }

    /// `mcp__claude_ai_<Name>__` with every non-alphanumeric character in the name replaced by
    /// an underscore — the shape Claude Code gives claude.ai connector tools ("Google Calendar"
    /// → `mcp__claude_ai_Google_Calendar__`). Curated packs pin their prefix instead; for a new
    /// connector, the lab's `tools` dump is how the derivation gets verified.
    static func derivedClaudePrefix(from claudeName: String) -> String {
        let cleaned = claudeName.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return "mcp__claude_ai_\(cleaned)__"
    }

    // MARK: The proactive card channels (task 1.7)

    /// One connector as proactive research may teach it: an `mcp` fire channel for a morning
    /// card. `description` = the curated router line (uncurated connectors ride name-only).
    struct CardChannel: Sendable {
        let slug: String
        let name: String
        let description: String?
    }

    /// The connectors research may declare as a card's fire channel: every detected connector
    /// for the live backend — on the Claude engine only CLASSIFIED ones, because the fired-task
    /// recipe refuses an unclassified slug and a card fire has no narrated fallback (the
    /// idle-tick classifier sweep makes exclusions a minutes-long transient). gmail and
    /// google-calendar never appear (census-excluded; they are their own methods). Empty =
    /// the shipped four-method research prompt and schema, untouched.
    static func cardChannels() -> [CardChannel] {
        let detected = detectedForCurrentBackend()
        let usable = ModelBackend.current == .claude
            ? detected.filter { isClassified($0.slug) }
            : detected
        if usable.count != detected.count {
            Log("cardChannels: \(detected.count - usable.count) unclassified connector(s) not offered as channels yet")
        }
        return usable.map { CardChannel(slug: $0.slug,
                                        name: displayName(slug: $0.slug),
                                        description: pack(forSlug: $0.slug)?.routerDescription) }
    }

    // MARK: Detection convenience

    /// The census's persisted list for the live backend (always empty on `.custom`, which has
    /// no account to carry connectors).
    static func detectedForCurrentBackend() -> [ConnectorCensus.DetectedConnector] {
        guard let origin = ConnectorCensus.DetectedConnector.Origin(backend: ModelBackend.current)
        else { return [] }
        return ConnectorCensus.cached(for: origin)
    }

    // MARK: The KB toggle (production keys)

    static func kbKey(_ slug: String) -> String { "mcp.\(slug).kb" }

    static func isKBEnabled(_ slug: String) -> Bool {
        UserDefaults.standard.bool(forKey: kbKey(slug))
    }

    static func setKBEnabled(_ slug: String, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: kbKey(slug))
    }

    /// The detected connectors whose KB toggle is on — the nightly read list (task 1.8) and the
    /// proactive-research attachment (task 1.7). Gated through kbEligible, so a toggle
    /// persisted before the curated-only rule landed can never read.
    static func kbEnabledConnectors() -> [ConnectorCensus.DetectedConnector] {
        detectedForCurrentBackend().filter { kbEligible($0.slug) && isKBEnabled($0.slug) }
    }

    /// Whether a connector may feed the knowledge base at all: only curated packs with a
    /// hand-verified read surface qualify, on both engines (Aditya's call, 2026-09-03,
    /// amending the original design where any connector could earn the toggle through the
    /// auto-classifier). An ineligible connector has no KB toggle anywhere; it stays fully
    /// task-usable (Sidekick, cards, computer use), which needs no toggle by ledger #2.
    static func kbEligible(_ slug: String, backend: ModelBackend = ModelBackend.current) -> Bool {
        guard let pack = pack(forSlug: slug), !pack.capturedProvisional,
              let server = server(for: slug) else { return false }
        switch backend {
        case .claude:
            return pack.readTools?.isEmpty == false && server.claudeServerURL != nil
                && server.claudeToolPrefix != nil
        case .chatgpt:
            guard pack.codexReadTools?.isEmpty == false, let id = server.codexCatalogID else { return false }
            return id.range(of: "^connector_[0-9a-f]{32}\\z", options: .regularExpression) != nil
        case .custom:
            return false
        }
    }

    /// A service identity is not an account identity. Track the engine and observed relinks;
    /// silent account changes within a hosted provider cannot be detected by the census.
    static func readOrigin(slug: String, backend: ModelBackend) -> String {
        let generation = UserDefaults.standard.integer(forKey: readGenerationKey(slug, backend.rawValue))
        return "v1:\(backend.rawValue):\(generation)"
    }

    static func readGenerationKey(_ slug: String, _ origin: String) -> String {
        "mcp.\(slug).readGeneration.\(origin)"
    }

    // MARK: The classifier cache (production keys)

    enum ToolCategory: String, Codable, Sendable {
        case read          // cannot change anything anywhere
        case write         // creates, sends, shares, moves, or modifies
        case destructive   // deletes, trashes, cancels, revokes, or overwrites
    }

    struct ClassifiedTool: Codable, Sendable, Equatable {
        let name: String          // the FULL engine tool name, as classified
        let category: ToolCategory
    }

    /// One connector's classified inventory. `cliVersion` is the managed CLI at capture time:
    /// tool surfaces drift with CLI updates, so a version mismatch forces a re-classification
    /// (the known fail-open window between captures — the existing house posture).
    struct Classification: Codable, Sendable {
        let tools: [ClassifiedTool]
        let cliVersion: String
        let capturedAt: Date
        /// Independent inventory checked before activation. Older captures require refresh.
        var verifiedInventory: [String]? = nil
    }

    static func classificationKey(_ slug: String) -> String { "mcp.classified.\(slug)" }

    static func classification(for slug: String) -> Classification? {
        guard let data = UserDefaults.standard.data(forKey: classificationKey(slug)) else { return nil }
        return try? JSONDecoder().decode(Classification.self, from: data)
    }

    static func saveClassification(_ classification: Classification, for slug: String) {
        guard let data = try? JSONEncoder().encode(classification) else { return }
        UserDefaults.standard.set(data, forKey: classificationKey(slug))
    }

    static func isClassified(_ slug: String) -> Bool {
        guard let capture = classification(for: slug),
              let version = ConnectorClassifier.currentCLIVersion else { return false }
        return ConnectorClassifier.isFresh(capture, slug: slug, version: version)
    }

    // MARK: Tool queries (full engine tool names out)

    /// The tools a READ run may pre-approve: the curated list when the pack has one (prefixed
    /// back to full names — for gmail/google-calendar that round-trips to the ConnectorTools
    /// arrays verbatim), else the classifier's reads (production KB reads are curated-only via
    /// kbEligible; the classifier fallback serves the lab's trial reads). Empty = NO read
    /// allows anywhere: fail closed.
    static func readToolNames(slug: String) -> [String] {
        if pack(forSlug: slug)?.capturedProvisional == true { return [] }
        if let pack = pack(forSlug: slug), let reads = pack.readTools,
           let prefix = pack.claudeToolPrefix {
            return reads.map { prefix + $0 }
        }
        guard isClassified(slug) else { return [] }
        return classification(for: slug)?.tools.filter { $0.category == .read }.map(\.name) ?? []
    }

    /// The deny list for user-fired runs — always the classifier's verdict, curated or not:
    /// curation covers reads, but the destructive denies need the full live inventory.
    static func destructiveToolNames(slug: String) -> [String] {
        classification(for: slug)?.tools.filter { $0.category == .destructive }.map(\.name) ?? []
    }

    /// The full known inventory: the classified surface when there is one, else the curated
    /// reads as the floor, else nothing.
    static func allKnownToolNames(slug: String) -> [String] {
        if let tools = classification(for: slug)?.tools, !tools.isEmpty {
            return tools.map(\.name)
        }
        return readToolNames(slug: slug)
    }
}
