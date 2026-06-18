//
//  DatabaseView.swift
//  Sentient OS macOS
//
//  The knowledge inspector — a dark, glassy NavigationSplitView over the CURRENT cycle's survivor
//  summaries (CycleStore). Junk/sensitive leave zero trace, so what's here IS the knowledge: the
//  on-device summaries that feed the cloud vault. Real QuickLook thumbnails, source/folder filters,
//  search. (Summaries are ephemeral per cycle now — no version history.)
//

import SwiftUI
import AppKit
import QuickLookThumbnailing

struct DatabaseView: View {
    /// Scene id for the standalone knowledge window (opened via `openWindow`).
    static let windowID = "knowledge"

    @State private var notes: [CycleNoteItem] = []     // current cycle, newest first
    @State private var selectedID: String?
    @State private var search = ""
    @State private var kindFilter: SourceKind?      // nil = all sources
    @State private var folderFilter: String?        // nil = all folders
    @State private var loaded = false

    /// One row per source (defensive dedup — a cycle holds at most one note per source), newest first.
    private var latest: [CycleNoteItem] {
        var seen = Set<String>()
        return notes.filter { seen.insert($0.sourceID).inserted }
    }

    private var filtered: [CycleNoteItem] {
        latest.filter { n in
            (kindFilter == nil || n.kind == kindFilter)
            && (folderFilter == nil || n.folder == folderFilter)
            && (search.isEmpty
                || n.text.localizedCaseInsensitiveContains(search)
                || (n.title?.localizedCaseInsensitiveContains(search) ?? false)
                || n.sourceID.localizedCaseInsensitiveContains(search))
        }
    }

    /// Distinct non-empty folders present (for the folder filter pills).
    private var folders: [String] {
        Array(Set(latest.map(\.folder).filter { !$0.isEmpty })).sorted()
    }

    private var selected: CycleNoteItem? {
        latest.first { $0.id == selectedID }
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
            notes = await CycleStore.shared.notes()
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
                    ForEach(filtered) { note in
                        RecordRow(note: note, isSelected: note.id == selectedID)
                            .onTapGesture { selectedID = note.id }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 24)
            }
            .overlay { if loaded && notes.isEmpty { emptyState } }
        }
        .background(Theme.bg)
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
            Text("Run an analysis to populate it.")
                .font(.caption).foregroundStyle(Theme.faint)
        }
        .padding(40)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let note = selected {
            RecordDetail(note: note)
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
    let note: CycleNoteItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FileThumbnail(path: note.filePath, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                if !note.folder.isEmpty { FolderTag(folder: note.folder) }
                Text(note.title ?? note.displayName)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                Text(note.text)
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
    let note: CycleNoteItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Spacer()
                    FileThumbnail(path: note.filePath, size: 240, cornerRadius: 16)
                    Spacer()
                }
                .padding(.top, 10)

                Text(note.title ?? note.displayName)
                    .font(.serif(26)).italic().foregroundStyle(.white)
                    .textSelection(.enabled)

                field("Summary", note.text)

                VStack(alignment: .leading, spacing: 11) {
                    meta("Path", note.displayPath)
                    meta("Source", DatabaseView.kindLabel(note.kind))
                    if !note.folder.isEmpty { meta("Folder", note.folder) }
                    meta("Item date", note.itemDate.formatted(date: .abbreviated, time: .shortened))
                    meta("Analyzed", note.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                if let path = note.filePath {
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

/// A small accent chip showing which folder/chat an artifact came from (Downloads / a chat name / …).
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
