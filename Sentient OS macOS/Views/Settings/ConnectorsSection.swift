//
// ConnectorsSection.swift
// The curated catalog, detected accounts and saved selections that still need setup.
// Unlinked presentation entries preserve intent without claiming an authenticated account.
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

    var isDirectSetup: Bool { connector == nil && directProvider != nil }

    /// Keep registry order, retain each distinct account, and append other connected apps.
    /// Gmail and Calendar already have permanent pills in the shared Connectors group.
    /// Teams is outside Knowledge Sources, including when detected as a connected app.
    static func catalog(with connectors: [ConnectorCensus.DetectedConnector]) -> [Self] {
        let hiddenSlugs = ConnectorCensus.dedicatedSourceSlugs.union(["teams", "microsoft-teams"])
        let packs = ConnectorRegistry.packs.filter { !hiddenSlugs.contains($0.slug) }
        var used = Set<String>()
        var sources: [Self] = []
        for pack in packs {
            var accounts = connectors.filter { ConnectorRegistry.pack(for: $0)?.slug == pack.slug }
            if pack.directProvider != nil, ConnectorRegistry.isKBEnabled(pack.slug),
               !accounts.contains(where: { $0.slug == pack.slug && $0.origin != .direct }),
               let origin = ConnectorCensus.DetectedConnector.Origin(backend: ModelBackend.current) {
                // Saved intent still needs its repair action after catalog/cache loss. This
                // presentation record is not a grant or a claim of a successful connection.
                accounts.append(.init(slug: pack.slug, displayName: pack.displayName, origin: origin,
                    serverURL: nil, catalogID: nil, iconPath: nil, healthy: false, lastSeen: .distantPast))
            }
            if accounts.isEmpty {
                sources.append(Self(id: "catalog:\(pack.slug)", serviceSlug: pack.slug,
                                    displayName: pack.displayName, connector: nil))
            } else {
                for account in accounts where used.insert(account.id).inserted {
                    sources.append(Self(account))
                }
                if pack.directProvider != nil {
                    // An existing hosted record must not hide the supported native setup.
                    sources.append(Self(id: "catalog:\(pack.slug)", serviceSlug: pack.slug,
                                        displayName: "Add \(pack.displayName) account", connector: nil))
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

/// Green means included in analysis, just like the folder, chat, and Gmail chips.
/// A linked account still needs an explicit knowledge opt-in. Task-only apps never look selected.
/// The parent owns the sheet so discovery cannot dismiss it.
struct ConnectorPill: View {
    let source: ConnectorSource
    let locked: Bool
    let featured: Bool
    let action: () -> Void
    @AppStorage private var knowledgeEnabled: Bool

    init(source: ConnectorSource, locked: Bool, featured: Bool = false, action: @escaping () -> Void) {
        self.source = source
        self.locked = locked
        self.featured = featured
        self.action = action
        _knowledgeEnabled = AppStorage(wrappedValue: false,
            ConnectorRegistry.kbKey(source.connector?.slug ?? source.serviceSlug))
    }

    private var selected: Bool {
        !source.isDirectSetup && knowledgeEnabled
            && !ConnectorRegistry.requiresDirectKnowledgeConnection(source.connector?.slug ?? source.serviceSlug)
            && ConnectorRegistry.kbEligible(source.connector?.slug ?? source.serviceSlug)
            && (source.usesHostedConnection || source.connector?.canAttempt == true)
    }

    private var detail: String? {
        guard !locked else { return nil }
        if source.isDirectSetup { return "Connect to Sentient" }
        if ConnectorRegistry.requiresDirectKnowledgeConnection(source.connector?.slug ?? source.serviceSlug) {
            return knowledgeEnabled ? "Knowledge connection needed" : "Tasks only"
        }
        if knowledgeEnabled && !selected { return "Connection needs attention · Manage" }
        if !ConnectorRegistry.kbEligible(source.connector?.slug ?? source.serviceSlug) { return "Tasks only" }
        return nil
    }

    private var status: String {
        if locked { return CodexAuth.connectorLockedTip }
        if source.isDirectSetup { return "Connect an account directly to Sentient for knowledge analysis." }
        if ConnectorRegistry.requiresDirectKnowledgeConnection(source.connector?.slug ?? source.serviceSlug) {
            return "Your AI connection is kept for tasks. Connect to Sentient to use it for knowledge analysis."
        }
        if knowledgeEnabled && !selected { return "Selected, but review this connection before analysis can use it." }
        return selected ? "Selected for analysis and nightly updates."
            : "Open this app to set it up and choose whether to use it for your knowledge base."
    }

    var body: some View {
        KnowledgeSourcePill(label: source.displayName, detail: detail,
                            asset: source.logoAsset, iconPath: source.connector?.iconPath,
                            selected: selected, featured: featured, locked: locked, action: action)
        .accessibilityValue(status)
        .help(status)
    }
}

#Preview("Connectors · catalog pills") {
    ChipFlow {
        ForEach(ConnectorSource.catalog(with: [])) { source in
            ConnectorPill(source: source, locked: false, action: {})
        }
    }
    .padding(38).frame(width: 640).background(Theme.bg)
}
