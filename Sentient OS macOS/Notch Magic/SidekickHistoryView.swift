// A local, persistent place to read Sidekick requests, answers and outcomes.
// SidekickHistoryView observes the existing history store; SidekickHistoryContent is previewable.
// Doc: Documentation - Sidekick - General.md

import SwiftUI
import AppKit

struct SidekickHistoryView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(SidekickHistory.key) private var historyData = Data()
    @Bindable private var navigation = MainNavigation.shared

    var body: some View {
        SidekickHistoryContent(items: SidekickHistory.items(from: historyData),
            activeID: appState.commandCoordinator.run.historyID?.uuidString,
            selection: $navigation.sidekickResultID,
            onClear: { SidekickHistory.reset() })
    }
}

struct SidekickHistoryContent: View {
    let items: [SidekickHistory.Item]
    var activeID: String? = nil
    @Binding var selection: String?
    var onClear: () -> Void = {}
    @State private var search = ""
    @State private var confirmClear = false

    private var filtered: [SidekickHistory.Item] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? items : items.filter {
            $0.request.localizedCaseInsensitiveContains(query)
                || ($0.response?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.status?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
    private var selected: SidekickHistory.Item? {
        filtered.first(where: { $0.id == selection }) ?? filtered.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            if let selected { detail(selected).id(selected.id) }
            else { emptyState }
        }
        .background(Theme.bg.ignoresSafeArea())
        .confirmationDialog("Clear Sidekick history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { onClear(); selection = nil }
        } message: {
            Text("This removes the requests and saved answers from this Mac. Work completed in other apps stays there.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HomeNavigationButton().padding(.horizontal, 14).padding(.top, 24)
            VStack(alignment: .leading, spacing: 7) {
                Text("Sidekick History").font(.system(size: 23, weight: .medium)).foregroundStyle(.white)
                Text("Your last \(SidekickHistory.capacity) tasks, saved on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.label)
            }.padding(.horizontal, 14)
            TextField("Search requests and answers", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("sidekick.history.search")
                .padding(.horizontal, 14)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(filtered) { item in
                        Button { selection = item.id } label: { row(item) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(item.request), \(status(item).title)")
                            .accessibilityIdentifier("sidekick.history.row.\(item.id)")
                    }
                }.padding(.horizontal, 8)
            }
            Button { confirmClear = true } label: {
                Label("Clear History", systemImage: "trash").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.Ink.label)
            .disabled(items.isEmpty || activeID != nil)
            .help(activeID == nil ? "Remove saved requests and answers" : "Finish or stop the current task first")
            .padding(.horizontal, 14).padding(.bottom, 24)
        }
        .frame(width: 316)
        .background(Color(white: 0.045).ignoresSafeArea())
    }

    private func row(_ item: SidekickHistory.Item) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(verbatim: item.request).font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9)).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: status(item).icon).foregroundStyle(status(item).color)
                Text(status(item).title)
                Spacer(minLength: 4)
                Text(item.at, format: .relative(presentation: .named, unitsStyle: .abbreviated)).lineLimit(1)
            }.font(.system(size: 10.5)).foregroundStyle(Theme.Ink.label)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(selected?.id == item.id ? 0.085 : 0.015)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(selected?.id == item.id ? 0.12 : 0.025)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func detail(_ item: SidekickHistory.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Label(status(item).title, systemImage: status(item).icon)
                    .foregroundStyle(status(item).color)
                Text("·").foregroundStyle(Theme.Ink.label)
                Text(item.at.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Theme.Ink.label)
                Spacer()
                if let answer = item.response {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                    } label: { Label("Copy Answer", systemImage: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
                    .accessibilityIdentifier("sidekick.history.copy")
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 36).padding(.vertical, 29)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        label(item.card ? "SUGGESTION" : "YOUR REQUEST")
                        Text(verbatim: item.request).font(.system(size: 23, weight: .medium))
                            .foregroundStyle(.white).textSelection(.enabled)
                    }
                    if let answer = item.response {
                        VStack(alignment: .leading, spacing: 12) {
                            label("SIDEKICK")
                            MarkdownView(markdown: answer, onExternal: { url in
                                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
                                NSWorkspace.shared.open(url)
                            })
                            .textSelection(.enabled)
                            if item.responseTruncated {
                                Text("This answer exceeded the local history limit. The beginning is shown here.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.label)
                            }
                        }
                    }
                    if item.outcome != "success" || item.response == nil {
                        VStack(alignment: .leading, spacing: 10) {
                            label("TASK STATUS")
                            Text(verbatim: item.status ?? (item.id == activeID
                                ? "Sidekick is working. The answer will appear here when it finishes."
                                : "No final response was recorded for this attempt."))
                                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.75)).textSelection(.enabled)
                            if item.response == nil, item.status != nil {
                                Text("Only the task status was saved for this attempt.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.label)
                            }
                        }
                    }
                }
                .frame(maxWidth: 740, alignment: .leading)
                .padding(36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.Ink.label)
            Text(items.isEmpty ? "Your answers have a home." : "No matching tasks")
                .font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
            Text(items.isEmpty ? "Ask Sidekick something. Your request and its final answer will appear here."
                 : "Try another word from your request or answer.")
                .font(.system(size: 14)).foregroundStyle(Theme.Ink.label)
                .multilineTextAlignment(.center).frame(maxWidth: 350)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(1.6).foregroundStyle(Theme.Ink.label)
    }

    private func status(_ item: SidekickHistory.Item) -> (title: String, icon: String, color: Color) {
        if item.id == activeID { return ("Working", "ellipsis", .white.opacity(0.65)) }
        switch item.outcome {
        case "success": return ("Completed", "checkmark", Theme.Ink.green)
        case "failed": return ("Couldn't finish", "exclamationmark.circle", .orange.opacity(0.8))
        case "stopped": return ("Stopped", "stop", .white.opacity(0.55))
        default: return ("Interrupted", "clock", .white.opacity(0.55))
        }
    }
}

#Preview("Sidekick history") {
    SidekickHistoryContent(items: [SidekickHistory.Item(id: "preview", request: "What is on my calendar tomorrow?",
        card: false, at: Date(), outcome: "success", status: "✓ done",
        response: "You have two meetings tomorrow.\n\n- **Design review** in the morning\n- **Project check-in** in the afternoon\n\nYour evening is clear.", responseTruncated: false)], selection: .constant(nil))
        .frame(width: 1180, height: 800).preferredColorScheme(.dark)
}

#Preview("No Sidekick history") {
    SidekickHistoryContent(items: [], selection: .constant(nil))
        .frame(width: 1180, height: 800).preferredColorScheme(.dark)
}
