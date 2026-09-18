//
// ConnectorsSection.swift
// The always-visible curated catalog, merged with the user's detected accounts. Catalog-only
// entries are presentation values, never detected connections or selected knowledge sources.
// Doc: Documentation - Settings.md
//

import SwiftUI

struct ConnectorSource: Identifiable {
    let id: String
    let serviceSlug: String
    let displayName: String
    let connector: ConnectorCensus.DetectedConnector?

    var isCurated: Bool { ConnectorRegistry.pack(forSlug: serviceSlug) != nil }

    var directProvider: DirectMCPProvider? {
        ConnectorRegistry.pack(forSlug: serviceSlug)?.directProvider
    }

    /// Existing accounts keep their actual route; catalog entries use their supported setup.
    var usesHostedConnection: Bool {
        connector.map { $0.origin != .direct } ?? (directProvider == nil)
    }

    /// Keep registry order, retain each distinct account, and append other connected apps.
    /// Gmail and Calendar already have permanent pills in the hosted connection group.
    /// Teams is outside Knowledge Sources, including when detected as a connected app.
    static func catalog(with connectors: [ConnectorCensus.DetectedConnector]) -> [Self] {
        let hiddenSlugs = ConnectorCensus.dedicatedSourceSlugs.union(["teams", "microsoft-teams"])
        let packs = ConnectorRegistry.packs.filter { !hiddenSlugs.contains($0.slug) }
        var used = Set<String>()
        var sources: [Self] = []
        for pack in packs {
            let accounts = connectors.filter { ConnectorRegistry.pack(for: $0)?.slug == pack.slug }
            if accounts.isEmpty {
                sources.append(Self(id: "catalog:\(pack.slug)", serviceSlug: pack.slug,
                                    displayName: pack.displayName, connector: nil))
            } else {
                for account in accounts where used.insert(account.id).inserted {
                    sources.append(Self(account))
                }
            }
        }
        sources += connectors.filter {
            !hiddenSlugs.contains($0.slug) && used.insert($0.id).inserted
        }.map { Self($0) }
        return sources
    }

    private init(_ connector: ConnectorCensus.DetectedConnector) {
        let pack = ConnectorRegistry.pack(for: connector)
        id = connector.id
        serviceSlug = pack?.slug ?? connector.slug
        displayName = connector.origin == .direct ? connector.displayName : pack?.displayName ?? connector.displayName
        self.connector = connector
    }

    private init(id: String, serviceSlug: String, displayName: String,
                 connector: ConnectorCensus.DetectedConnector?) {
        self.id = id
        self.serviceSlug = serviceSlug
        self.displayName = displayName
        self.connector = connector
    }

    /// Bundled artwork keeps unlinked apps independent of a user's connector cache.
    /// Drive: Google's current product artwork, with its alpha mask expressed as a clip path
    /// for native SVG rendering: https://www.gstatic.com/images/branding/productlogos/drive_2026/v2/web/192px.svg
    /// Slack: its Codex connector artwork, with only transparent padding removed.
    /// Outlook: Microsoft's vector mark, mirrored at Wikimedia Commons:
    /// https://commons.wikimedia.org/wiki/File:Microsoft_Outlook_Icon_(2025–present).svg
    /// Granola: https://www.granola.ai/icon.png.
    /// Notion: the sticker logo on https://www.notion.com (CSS black resolved for the asset).
    var logoAsset: String? {
        switch serviceSlug {
        case "google-drive": "GoogleDriveMark"
        case "slack": "SlackMark"
        case "notion": "NotionMark"
        case "granola": "GranolaMark"
        case "outlook-mail", "outlook-calendar": "OutlookMark"
        default: nil
        }
    }
}

struct ConnectorsSection: View {
    let sources: [ConnectorSource]
    let locked: Bool
    let onSelect: (ConnectorSource) -> Void

    var body: some View {
        SettingsGroup(label: "Connectors") {
            ChipFlow {
                ForEach(sources) { source in
                    ConnectorPill(source: source, locked: locked) { onSelect(source) }
                }
            }
            .animation(.easeInOut(duration: 0.35), value: sources.map(\.id))
        }
    }
}

/// Green means included in analysis, just like the folder, chat, and Gmail chips.
/// A linked account still needs an explicit knowledge opt-in. Task-only apps never look selected.
/// The parent owns the sheet so discovery cannot dismiss it.
struct ConnectorPill: View {
    let source: ConnectorSource
    let locked: Bool
    let action: () -> Void
    @AppStorage private var knowledgeEnabled: Bool

    init(source: ConnectorSource, locked: Bool, action: @escaping () -> Void) {
        self.source = source
        self.locked = locked
        self.action = action
        _knowledgeEnabled = AppStorage(wrappedValue: false,
            ConnectorRegistry.kbKey(source.connector?.slug ?? source.serviceSlug))
    }

    private var selected: Bool {
        source.connector.map {
            ConnectorRegistry.contributesToKnowledgeBase($0, enabled: knowledgeEnabled)
        } ?? false
    }

    private var detail: String? {
        guard !locked, let connector = source.connector else { return nil }
        if !connector.healthy { return "Reconnect" }
        if !ConnectorRegistry.kbEligible(connector.slug) { return "Tasks only" }
        return selected ? nil : "Not selected"
    }

    private var status: String {
        if locked { return CodexAuth.connectorLockedTip }
        guard let connector = source.connector else { return "Connect this app to get started." }
        if !connector.healthy { return "Reconnect this app to use it for analysis." }
        if !ConnectorRegistry.kbEligible(connector.slug) {
            return "Available for tasks, but not supported as a knowledge source. Does not count toward analysis."
        }
        return selected ? "Selected for analysis and nightly updates."
            : "Connected, but not selected for analysis. Open this app and turn on Use for knowledge base."
    }

    var body: some View {
        SettingsChip(label: source.displayName, detail: detail,
                     on: selected,
                     locked: locked,
                     needsAttention: source.connector?.healthy == false,
                     action: action)
        .accessibilityValue(status)
        .help(status)
    }
}

#Preview("Connectors · direct connection catalog") {
    ConnectorsSection(sources: ConnectorSource.catalog(with: []).filter { !$0.usesHostedConnection },
                      locked: false, onSelect: { _ in })
        .padding(38).frame(width: 640).background(Theme.bg)
}
