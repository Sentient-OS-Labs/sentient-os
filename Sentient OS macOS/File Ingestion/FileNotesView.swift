//
//  FileNotesView.swift
//  Sentient OS macOS
//
//  VIEW SUMMARIES — a plain dev list of the current cycle's FileNotes (the files-iterative
//  system's ephemeral survivor summaries, FileStore). Initial or iterative, it just shows
//  whatever notes exist right now (they're wiped when the proactive button ends the cycle).
//

import SwiftUI

struct FileNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [FileNoteItem] = []
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SUMMARIES · \(notes.count)")
                    .font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)
                Spacer()
                Button("Refresh") { Task { await load() } }.controlSize(.small)
                Button("Done") { dismiss() }.controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

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
    }

    private func row(_ n: FileNoteItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(n.title ?? n.displayName)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .lineLimit(1)
                if n.reminderFlagged {
                    Text("REMINDER").font(.system(size: 8, weight: .bold)).tracking(1)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                        .foregroundStyle(.orange)
                }
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

    private func load() async {
        notes = await FileStore.shared.notes()
        loaded = true
    }
}
