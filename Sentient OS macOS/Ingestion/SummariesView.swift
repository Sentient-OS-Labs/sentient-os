//
//  SummariesView.swift
//  Sentient OS macOS
//
//  VIEW SUMMARIES — a plain dev list of the current cycle's notes (the iterative system's ephemeral
//  survivor summaries, CycleStore). Any connector, initial or iterative; just shows whatever exists
//  right now (wiped when the proactive button ends the cycle).
//
//  Export/Import (top-left, dev tool): dump the whole summary set to a JSON file, or load one to
//  REPLACE this machine's set — so a dev can hand a co-founder their rich context (e.g. to build
//  proactive against real data). Export is read-only. Import backs up the existing notes to
//  Application Support BEFORE replacing, and never touches pointers. See CycleStore.importNotes.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SummariesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [CycleNoteItem] = []
    @State private var loaded = false
    @State private var showClearConfirm = false
    @State private var showImportConfirm = false
    @State private var pendingImport: SummaryExport?
    @State private var status: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SUMMARIES · \(notes.count)")
                    .font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)
                Button("Export") { export() }.controlSize(.small).disabled(notes.isEmpty)
                Button("Import") { beginImport() }.controlSize(.small)
                Spacer()
                Button("Clear All", role: .destructive) { showClearConfirm = true }
                    .controlSize(.small).tint(.red).disabled(notes.isEmpty)
                Button("Refresh") { Task { await load() } }.controlSize(.small)
                Button("Done") { dismiss() }.controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, status == nil ? 12 : 6)

            if let status {
                Text(status)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(status.hasPrefix("✓") ? .green : status.hasPrefix("✗") ? .red : Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 8)
                    .textSelection(.enabled)
            }

            if loaded && notes.isEmpty {
                Spacer()
                Text("No summaries yet — run “start on device”.")
                    .font(.callout).foregroundStyle(Theme.faint)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(notes) { note in
                            row(note)
                            Divider().overlay(Theme.stroke)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8)
                }
            }
        }
        .frame(width: 640, height: 720)
        .background(Theme.bg)
        .task { await load() }
        .confirmationDialog("Clear all current summaries?", isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { Task { await clearAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every summary in the current cycle. Per-source pointers are kept, so an ITERATIVE run won't re-summarize past items — run INITIAL to fully re-summarize.")
        }
        .confirmationDialog("Replace all summaries with the imported set?",
                            isPresented: $showImportConfirm, titleVisibility: .visible,
                            presenting: pendingImport) { exp in
            Button("Replace \(notes.count) with \(exp.notes.count)", role: .destructive) {
                Task { await performImport(exp) }
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: { exp in
            Text("Your current \(notes.count) summaries are backed up to Application Support first, then replaced with the \(exp.notes.count) imported ones. Per-source pointers are left untouched.")
        }
    }

    // MARK: Rows

    private func row(_ n: CycleNoteItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(n.title ?? n.displayName)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Text(n.folder).font(.caption2).foregroundStyle(Theme.faint)
            }
            Text(n.text)
                .font(.caption).foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Text(n.displayPath)
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.faint)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    // MARK: Load / clear

    private func load() async {
        notes = await CycleStore.shared.notes()
        loaded = true
    }

    private func clearAll() async {
        await CycleStore.shared.wipeAllNotes()
        await load()
    }

    // MARK: Export (read-only — never mutates this machine's store)

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "sentient-summaries-\(Self.stamp()).json"
        panel.canCreateDirectories = true
        panel.title = "Export Summaries"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let items = await CycleStore.shared.notes()
            do {
                let data = try Self.encoder.encode(SummaryExport(notes: items))
                try data.write(to: url)
                status = "✓ exported \(items.count) summaries → \(url.lastPathComponent)"
            } catch {
                status = "✗ export failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Import (REPLACE — backs up existing first, leaves pointers alone)

    /// Pick + parse the file, then raise the confirm dialog. The actual replace happens in
    /// `performImport` only after the user confirms.
    private func beginImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Summaries"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            pendingImport = try Self.decoder.decode(SummaryExport.self, from: data)
            showImportConfirm = true
        } catch {
            status = "✗ couldn't read that file: \(error.localizedDescription)"
        }
    }

    private func performImport(_ exp: SummaryExport) async {
        let existing = await CycleStore.shared.notes()
        backup(existing)                                              // safety net before any wipe
        await CycleStore.shared.importNotes(exp.notes, replace: true)
        pendingImport = nil
        await load()
        status = "✓ imported \(exp.notes.count)" + (existing.isEmpty ? "" : " · backed up \(existing.count)")
    }

    /// Dump the soon-to-be-replaced notes to Application Support/SummaryBackups so an accidental
    /// import is always recoverable (re-import the backup to undo).
    private func backup(_ items: [CycleNoteItem]) {
        guard !items.isEmpty else { return }
        let dir = URL.applicationSupportDirectory.appending(path: "SummaryBackups", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "backup-\(Self.stamp()).json")
        if let data = try? Self.encoder.encode(SummaryExport(notes: items)) {
            try? data.write(to: url)
            Log("SummariesView: backed up \(items.count) summaries → \(url.path)")
        }
    }

    // MARK: Codec helpers

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private static let decoder = JSONDecoder()
    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f.string(from: Date())
    }
}
