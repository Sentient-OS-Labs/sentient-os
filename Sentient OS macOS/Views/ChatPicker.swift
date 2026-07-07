//
//  ChatPicker.swift
//  Sentient OS macOS
//
//  The opt-in "Choose chats & groups" sheet, shared by the chat sources (WhatsApp + iMessage).
//  Lists the chats ACTIVE within the scan window (newest first, with message counts), with
//  search + per-chat checkboxes + bulk All-DMs / All-groups / Clear. "Done" hands the selected
//  chat ids (JIDs / GUIDs) back to the caller, which persists them and lights up the source chip.
//  DMs from numbers not in the user's contacts (ChatInfo.isSaved == false — iMessage only) hide
//  behind the "Show unsaved numbers" checkbox, off by default; a selected chat is never hidden.
//

import SwiftUI

struct ChatPicker: View {
    let sourceName: String                                   // "WhatsApp" / "iMessage" — for error/empty states
    let loadChats: @Sendable () throws -> [ChatInfo]
    let initialSelection: Set<String>
    var onDone: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chats: [ChatInfo] = []
    @State private var selection: Set<String>
    @State private var search = ""
    @State private var showUnsaved = false
    @State private var loaded = false
    @State private var loadError: String?

    init(sourceName: String, loadChats: @escaping @Sendable () throws -> [ChatInfo],
         initialSelection: Set<String>, onDone: @escaping (Set<String>) -> Void) {
        self.sourceName = sourceName
        self.loadChats = loadChats
        self.initialSelection = initialSelection
        self.onDone = onDone
        _selection = State(initialValue: initialSelection)
    }

    /// What the list shows: saved chats always; unsaved numbers only with the toggle on —
    /// except ones already selected, which must never be invisibly opted in.
    private var visible: [ChatInfo] {
        chats.filter { showUnsaved || $0.isSaved || selection.contains($0.id) }
    }
    private var filtered: [ChatInfo] {
        search.isEmpty ? visible : visible.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var unsavedCount: Int { chats.count { !$0.isSaved } }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            Divider().overlay(Theme.stroke)
            content
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 560)
        .background(Theme.bg)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choose chats & groups").display(24).foregroundStyle(.white)
            Text(loaded
                 ? "\(selection.count) selected · \(visible.count) active in the last \(ChatWindowing.lookbackDays) days"
                 : "Reading your chats…")
                .font(.footnote).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
    }

    private var filterBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                TextField("Search chats", text: $search).textFieldStyle(.plain).foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 9).glassCard(radius: 10)

            HStack(spacing: 7) {
                bulk("All DMs")    { for c in filtered where !c.isGroup { selection.insert(c.id) } }
                bulk("All groups") { for c in filtered where c.isGroup  { selection.insert(c.id) } }
                bulk("Clear")      { selection.removeAll() }
                Spacer()
                if unsavedCount > 0 { unsavedToggle }
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    /// The "show unsaved numbers" checkbox — mirrors the row checkmarks (accent when on).
    private var unsavedToggle: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { showUnsaved.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: showUnsaved ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13)).foregroundStyle(showUnsaved ? Theme.accent : Theme.faint)
                Text("Show unsaved numbers (\(unsavedCount))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(showUnsaved ? .white : Theme.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func bulk(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Color.white.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if let loadError {
            centered {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("Couldn't read \(sourceName)").foregroundStyle(.white)
                Text(loadError).font(.caption).foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
            }
        } else if !loaded {
            centered { ProgressView().tint(Theme.accent) }
        } else if chats.isEmpty {
            centered {
                Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(Theme.faint)
                Text("No active chats in the last \(ChatWindowing.lookbackDays) days").foregroundStyle(Theme.secondary)
            }
        } else if filtered.isEmpty {
            centered {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.largeTitle).foregroundStyle(Theme.faint)
                Text(search.isEmpty
                     ? "Only unsaved numbers were active; tap “Unsaved numbers” to show them"
                     : "No chats match “\(search)”")
                    .font(.callout).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filtered) { row($0) }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private func row(_ chat: ChatInfo) -> some View {
        let on = selection.contains(chat.id)
        return HStack(spacing: 12) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18)).foregroundStyle(on ? Theme.accent : Theme.faint)
            Image(systemName: chat.isGroup ? "person.3.fill" : "person.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.name).font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                Text("\(chat.isGroup ? "Group" : "DM") · \(chat.messageCount) msgs · \(chat.lastActive.formatted(.relative(presentation: .numeric)))")
                    .font(.caption2).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(on ? Theme.accent.opacity(0.12) : Color.white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(on ? Theme.accent.opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if on { selection.remove(chat.id) } else { selection.insert(chat.id) } }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
            Spacer()
            Button { onDone(selection); dismiss() } label: {
                Text("Done").font(.headline).foregroundStyle(.black)
                    .frame(width: 150, height: 40)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain).disabled(!loaded)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Theme.bg)
    }

    private func centered<C: View>(@ViewBuilder _ inner: () -> C) -> some View {
        VStack(spacing: 8) { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard !loaded else { return }
        do {
            let loader = loadChats
            chats = try await Task.detached { try loader() }.value
        } catch {
            loadError = "\(error)"
        }
        loaded = true
    }
}

#Preview("Mixed saved & unsaved (iMessage)") {
    ChatPicker(
        sourceName: "iMessage",
        loadChats: { [
            ChatInfo(id: "1", name: "Jesai UMass USA", isGroup: false, messageCount: 16,
                     lastActive: .now.addingTimeInterval(-3 * 86400)),
            ChatInfo(id: "2", name: "+14154042744", isGroup: false, messageCount: 2,
                     lastActive: .now.addingTimeInterval(-7 * 86400), isSaved: false),
            ChatInfo(id: "3", name: "+917428192241 & +19121366030", isGroup: true, messageCount: 1,
                     lastActive: .now.addingTimeInterval(-8 * 86400)),
            ChatInfo(id: "4", name: "Aryaman UMass, Gurmeher SF Ditto & 1 others", isGroup: true,
                     messageCount: 50, lastActive: .now.addingTimeInterval(-14 * 86400)),
            ChatInfo(id: "5", name: "Aarit UMass", isGroup: false, messageCount: 19,
                     lastActive: .now.addingTimeInterval(-21 * 86400)),
            ChatInfo(id: "6", name: "262966", isGroup: false, messageCount: 1,
                     lastActive: .now.addingTimeInterval(-40 * 86400), isSaved: false),
            ChatInfo(id: "7", name: "39781", isGroup: false, messageCount: 1,
                     lastActive: .now.addingTimeInterval(-42 * 86400), isSaved: false),
        ] },
        initialSelection: ["2"],   // a selected unsaved number — must stay visible with the toggle off
        onDone: { _ in })
}
