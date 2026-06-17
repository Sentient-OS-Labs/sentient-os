//
//  DatabaseView.swift
//  Sentient OS macOS
//
//  The knowledge inspector — a dark, glassy NavigationSplitView over the survivor summaries.
//  Reads Sendable SummaryRecords from the Store (never touches @Model directly). With the
//  ledger gone there are no junk/sensitive rows to show — what's here IS the knowledge.
//  Summaries are versioned: the sidebar lists the latest version per source; the detail pane
//  shows that source's full version history (edits over time). Real QuickLook thumbnails,
//  source/folder filters, reminder gradient, Reveal-in-Finder / Open.
//

import SwiftUI
import AppKit
import QuickLookThumbnailing

struct DatabaseView: View {
    /// Scene id for the standalone knowledge window (opened via `openWindow`).
    static let windowID = "knowledge"

    let store: Store

    @State private var records: [SummaryRecord] = []    // every version, newest first
    @State private var selectedID: String?
    @State private var search = ""
    @State private var kindFilter: SourceKind?      // nil = all sources
    @State private var folderFilter: String?        // nil = all folders
    @State private var loaded = false

    /// Latest version per source (the sidebar rows), preserving newest-first order.
    private var latest: [SummaryRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.sourceID).inserted }
    }

    private var filtered: [SummaryRecord] {
        latest.filter { r in
            (kindFilter == nil || r.kind == kindFilter)
            && (folderFilter == nil || r.folder == folderFilter)
            && (search.isEmpty
                || r.text.localizedCaseInsensitiveContains(search)
                || (r.title?.localizedCaseInsensitiveContains(search) ?? false)
                || r.sourceID.localizedCaseInsensitiveContains(search))
        }
    }

    /// Distinct non-empty folders present in the store (for the folder filter pills).
    private var folders: [String] {
        Array(Set(latest.map(\.folder).filter { !$0.isEmpty })).sorted()
    }

    private var selected: SummaryRecord? {
        latest.first { $0.id == selectedID }
    }

    /// Every version of the selected source, newest first (records are already newest-first).
    private var selectedVersions: [SummaryRecord] {
        guard let s = selected else { return [] }
        return records.filter { $0.sourceID == s.sourceID }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 460)
        } detail: {
            detail
        }
        .frame(minWidth: 880, minHeight: 600)
        .background(Theme.bg)
        .task {
            records = await store.allSummaries()
            loaded = true
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Knowledge").font(.serif(28)).italic().foregroundStyle(.white)
                Text("\(filtered.count) of \(latest.count) memories · \(LifetimeStats.analyzed.formatted()) things understood")
                    .font(.footnote).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)

            filterBar

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { record in
                        RecordRow(record: record,
                                  versions: versionCount(record.sourceID),
                                  isSelected: record.id == selectedID)
                            .onTapGesture { selectedID = record.id }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 24)
            }
            .overlay { if loaded && records.isEmpty { emptyState } }
        }
        .background(Theme.bg)
    }

    private func versionCount(_ sourceID: String) -> Int {
        records.count(where: { $0.sourceID == sourceID })
    }

    private var filterBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                TextField("Search summaries, titles & paths", text: $search)
                    .textFieldStyle(.plain).foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .glassCard(radius: 10)

            HStack(spacing: 7) {
                pill("All", color: .white, active: kindFilter == nil) { kindFilter = nil }
                ForEach(SourceKind.allCases, id: \.self) { k in
                    pill(Self.kindLabel(k), color: Theme.accent, active: kindFilter == k) {
                        kindFilter = (kindFilter == k) ? nil : k
                    }
                }
                Spacer()
            }

            if !folders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        pill("All folders", color: Theme.accent, active: folderFilter == nil) { folderFilter = nil }
                        ForEach(folders, id: \.self) { f in
                            pill(f, color: Theme.accent, active: folderFilter == f) {
                                folderFilter = (folderFilter == f) ? nil : f
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 12)
    }

    static func kindLabel(_ k: SourceKind) -> String {
        switch k {
        case .file:     return "Files"
        case .whatsapp: return "WhatsApp"
        case .imessage: return "iMessage"
        case .notes:    return "Notes"
        case .gmail:    return "Gmail"
        }
    }

    private func pill(_ title: String, color: Color, active: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? .black : color)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(active ? color : Color.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Theme.faint)
            Text("No memories yet").foregroundStyle(Theme.secondary)
            Text("Run an analysis to populate the store.")
                .font(.caption).foregroundStyle(Theme.faint)
        }
        .padding(40)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let record = selected {
            RecordDetail(record: record, versions: selectedVersions)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 38, weight: .thin)).foregroundStyle(Theme.faint)
                Text("Select a memory").font(.serif(20)).italic().foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
        }
    }
}

// MARK: - Row

private struct RecordRow: View {
    let record: SummaryRecord
    let versions: Int
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FileThumbnail(path: record.filePath, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if !record.folder.isEmpty { FolderTag(folder: record.folder) }
                    if versions > 1 { VersionTag(count: versions) }
                }
                Text(record.title ?? record.displayName)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                Text(record.text)
                    .font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(isSelected ? Theme.accent.opacity(0.16) : Color.white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.55) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

private struct RecordDetail: View {
    let record: SummaryRecord          // the latest version
    let versions: [SummaryRecord]      // all versions, newest first (incl. `record`)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Spacer()
                    FileThumbnail(path: record.filePath, size: 240, cornerRadius: 16)
                    Spacer()
                }
                .padding(.top, 10)

                Text(record.title ?? record.displayName)
                    .font(.serif(26)).italic().foregroundStyle(.white)
                    .textSelection(.enabled)

                field("Summary", record.text)

                VStack(alignment: .leading, spacing: 11) {
                    meta("Path", record.displayPath)
                    meta("Source", DatabaseView.kindLabel(record.kind))
                    if !record.folder.isEmpty { meta("Folder", record.folder) }
                    if let d = record.itemDate {
                        meta("Item date", d.formatted(date: .abbreviated, time: .shortened))
                    }
                    meta("Analyzed", record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    meta("In vault", record.syncedToVault.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "queued for next update")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                if versions.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("VERSION HISTORY").font(.caption2.weight(.semibold)).tracking(1.2)
                            .foregroundStyle(Theme.faint)
                        ForEach(versions.dropFirst()) { v in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(v.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2.monospaced()).foregroundStyle(Theme.faint)
                                Text(v.text).font(.caption).foregroundStyle(Theme.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.03),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }

                if let path = record.filePath {
                    HStack(spacing: 10) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: { Label("Reveal in Finder", systemImage: "folder") }
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                    }
                    .buttonStyle(.bordered).tint(Theme.accent)
                }

                Spacer(minLength: 30)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(Theme.faint)
            Text(value).font(.body).foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func meta(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.caption).foregroundStyle(Theme.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Tags

/// A small accent chip showing which folder an artifact came from (Downloads / Desktop / …).
private struct FolderTag: View {
    let folder: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "folder.fill").font(.system(size: 8))
            Text(folder).font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Theme.accent.opacity(0.14), in: Capsule())
    }
}

/// "3 versions" — this source has been re-analyzed after edits (summaries are versioned).
private struct VersionTag: View {
    let count: Int
    var body: some View {
        Text("\(count) versions")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.white.opacity(0.08), in: Capsule())
    }
}

// FileThumbnail moved to Views/FileThumbnail.swift (shared with ProcessingView).
