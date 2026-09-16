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
    /// Granola: https://www.granola.ai/icon.png. Linear: https://linear.app/brand (light logo).
    /// Notion: the sticker logo on https://www.notion.com (CSS black resolved for the asset).
    var logoAsset: String? {
        switch serviceSlug {
        case "google-drive": "GoogleDriveMark"
        case "slack": "SlackMark"
        case "notion": "NotionMark"
        case "granola": "GranolaMark"
        case "linear": "LinearMark"
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

/// Connection health, rather than source selection: neutral when unlinked, green when ready,
/// amber when attention is needed. Every app opens its connection sheet when unlocked.
/// The parent owns the sheet so discovery cannot dismiss it.
struct ConnectorPill: View {
    let source: ConnectorSource
    let locked: Bool
    let action: () -> Void
    @State private var lockHover = false

    var body: some View {
        Button { if !locked { action() } } label: {
            label
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityValue(locked ? "Locked" : source.connector.map { $0.healthy ? "Connected" : "Needs attention" } ?? "Not connected")
        .onHover { lockHover = locked && $0 }
        .overlay(alignment: .top) {
            if lockHover { LockedChipTip().offset(y: -32) }
        }
        .animation(.easeInOut(duration: 0.15), value: lockHover)
    }

    private var label: some View {
        HStack(spacing: 7) {
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            } else if let connector = source.connector {
                HealthDot(color: connector.healthy ? Theme.Ink.green : HealthDot.warnAmber)
            } else {
                Circle().fill(.white.opacity(0.35)).frame(width: 5, height: 5)
            }
            Text(source.displayName)
                .font(.system(size: 12)).foregroundStyle(.white.opacity(locked ? 0.55 : 1))
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .overlay(Capsule().strokeBorder(Color.white.opacity(locked ? 0.10 : 0.16), lineWidth: 1))
        .contentShape(Capsule())
    }
}

#Preview("Connectors · direct connection catalog") {
    ConnectorsSection(sources: ConnectorSource.catalog(with: []).filter { !$0.usesHostedConnection },
                      locked: false, onSelect: { _ in })
        .padding(38).frame(width: 640).background(Theme.bg)
}
