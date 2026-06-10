//
//  DatabaseView.swift
//  Sentient OS macOS
//
//  The knowledge inspector — a dark, glassy NavigationSplitView over the analyzed artifacts.
//  Reads Sendable RecordSnapshots from the Store (never touches @Model directly). Real QuickLook
//  file previews, verdict pills, reminder gradient, search + verdict filters, and a rich detail
//  pane with Reveal-in-Finder / Open. Inspiration: the iOS DatabaseViewerView, rebuilt for Mac.
//

import SwiftUI
import AppKit
import QuickLookThumbnailing

struct DatabaseView: View {
    /// Scene id for the standalone knowledge window (opened via `openWindow`).
    static let windowID = "knowledge"

    let store: Store

    @State private var records: [RecordSnapshot] = []
    @State private var selectedID: String?
    @State private var search = ""
    @State private var verdictFilter: Verdict?     // nil = all
    @State private var folderFilter: String?       // nil = all folders
    @State private var loaded = false

    private var filtered: [RecordSnapshot] {
        records.filter { r in
            (verdictFilter == nil || r.verdict == verdictFilter)
            && (folderFilter == nil || r.folder == folderFilter)
            && (search.isEmpty
                || (r.summary?.localizedCaseInsensitiveContains(search) ?? false)
                || r.sourceID.localizedCaseInsensitiveContains(search))
        }
    }

    /// Distinct non-empty folders present in the store (for the folder filter pills).
    private var folders: [String] {
        Array(Set(records.map(\.folder).filter { !$0.isEmpty })).sorted()
    }

    private var selected: RecordSnapshot? {
        records.first { $0.id == selectedID }
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
            records = await store.allRecords()
            loaded = true
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Knowledge").font(.serif(28)).italic().foregroundStyle(.white)
                Text("\(filtered.count) of \(records.count) artifacts")
                    .font(.footnote).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)

            filterBar

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { record in
                        RecordRow(record: record, isSelected: record.id == selectedID)
                            .onTapGesture { selectedID = record.id }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 24)
            }
            .overlay { if loaded && records.isEmpty { emptyState } }
        }
        .background(Theme.bg)
    }

    private var filterBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                TextField("Search summaries & paths", text: $search)
                    .textFieldStyle(.plain).foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .glassCard(radius: 10)

            HStack(spacing: 7) {
                pill("All", color: .white, active: verdictFilter == nil) { verdictFilter = nil }
                ForEach([Verdict.survivor, .junk, .sensitive], id: \.self) { v in
                    pill(Theme.verdictLabel(v), color: Theme.verdictColor(v), active: verdictFilter == v) {
                        verdictFilter = (verdictFilter == v) ? nil : v
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
            Text("No artifacts yet").foregroundStyle(Theme.secondary)
            Text("Run the Files pipeline to populate the store.")
                .font(.caption).foregroundStyle(Theme.faint)
        }
        .padding(40)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let record = selected {
            RecordDetail(record: record)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 38, weight: .thin)).foregroundStyle(Theme.faint)
                Text("Select an artifact").font(.serif(20)).italic().foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
        }
    }
}

// MARK: - Row

private struct RecordRow: View {
    let record: RecordSnapshot
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FileThumbnail(path: record.filePath, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                if !record.folder.isEmpty || record.verdict != .survivor || record.reminderFlagged {
                    HStack(spacing: 6) {
                        if !record.folder.isEmpty { FolderTag(folder: record.folder) }
                        if record.verdict != .survivor { VerdictBadge(verdict: record.verdict) }
                        if record.reminderFlagged {
                            Image(systemName: "bell.fill").font(.system(size: 9))
                                .foregroundStyle(Theme.reminderGradient)
                        }
                    }
                }
                Text(record.title ?? record.displayName)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                Text(record.summary ?? record.displayPath)
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
    let record: RecordSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Spacer()
                    FileThumbnail(path: record.filePath, size: 240, cornerRadius: 16)
                    Spacer()
                }
                .padding(.top, 10)

                if record.verdict != .survivor || record.reminderFlagged {
                    HStack(spacing: 8) {
                        if record.verdict == .sensitive { SensitivePill() }
                        else if record.verdict == .junk { JunkPill() }
                        if record.reminderFlagged { ReminderPill() }
                    }
                }

                Text(record.title ?? record.displayName)
                    .font(.serif(26)).italic().foregroundStyle(.white)
                    .textSelection(.enabled)

                if let summary = record.summary { field("Summary", summary) }

                VStack(alignment: .leading, spacing: 11) {
                    meta("Path", record.displayPath)
                    meta("Source", record.kind.rawValue)
                    if !record.folder.isEmpty { meta("Folder", record.folder) }
                    meta("Signature", record.signature)
                    meta("First seen", record.firstSeen.formatted(date: .abbreviated, time: .shortened))
                    meta("Last seen", record.lastSeen.formatted(date: .abbreviated, time: .shortened))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

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

// MARK: - Folder tag

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

// FileThumbnail moved to Views/FileThumbnail.swift (shared with ProcessingView).
