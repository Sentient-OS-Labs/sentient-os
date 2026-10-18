import AppKit
import Combine
import SwiftUI

/// Inline task history. Only an expanded section reads activity; a bounded page keeps a
/// months-old conversation as inexpensive to render as a new one.
struct SidekickWorkDisclosure: View {
    let conversation: SidekickConversation
    let taskID: UUID
    let state: SidekickConversationStore.TranscriptTaskState?
    let presentation: SidekickPresentation
    var running = false
    var waiting = false
    var active = false
    var liveStatus = ""
    @State private var visible = false
    private var expanded: Bool { presentation.expandedWorkTasks.contains(taskID) }
    @State private var records: [SidekickConversationStore.Record] = []
    @State private var steps: [SidekickActivityPresentation.Step] = []
    @State private var cursor: Int64 = 0
    @State private var previousCursors: [Int64] = []
    @State private var more = false
    @State private var loading = false
    @State private var hasLoaded = false
    @State private var failed = false
    @State private var activityHeight: CGFloat = 0
    @State private var revision = 0
    @State private var loadToken = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reduced: Bool { motionOverride ?? systemReduced }
    private var canExpand: Bool { running || state?.hasActivity == true || !steps.isEmpty || failureDescription != nil || failed }
    private var revealed: Bool { expanded && canExpand }
    private var progressNote: String? {
        guard running, !waiting, let note = SidekickTranscriptLayout.progressNote(liveStatus) else { return nil }
        let latest = conversation.messages.last { $0.event.taskID == taskID && $0.event.kind == .assistantMessage }
        return latest?.event.text.trimmingCharacters(in: .whitespacesAndNewlines) == note ? nil : note
    }
    private var failureDescription: String? {
        guard let ending = state?.finished?.event, ending.outcome == .failed || ending.outcome == .interrupted else { return nil }
        let text = ending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    private struct LoadKey: Equatable {
        let task: UUID
        let generation: UUID?
        let expanded: Bool
        let revision: Int
        let cursor: Int64
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if running && active && visible {
                TimelineView(.periodic(from: .now, by: 1)) { header(at: $0.date) }
            } else { header(at: Date()) }
            activityViewport
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .task(id: LoadKey(task: taskID, generation: conversation.generation, expanded: expanded, revision: revision, cursor: cursor)) {
            guard expanded else { return }
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sidekickConversationChanged).receive(on: DispatchQueue.main)) { notification in
            guard expanded, let store = notification.object as? SidekickConversationStore,
                  store === conversation.store else { return }
            revision &+= 1
        }
    }

    /// Keep the bounded, previously loaded rows mounted so collapsing does not discard their
    /// detail disclosures or scroll positions. Reveal a viewport below the header, never move
    /// the rows through it. Measuring before the zero-height frame preserves intrinsic sizing.
    private var activityViewport: some View {
        activity
            .padding(.top, 13).padding(.bottom, 5)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { max(0, ceil($0.size.height)) } action: { height in
                guard height.isFinite, abs(height - activityHeight) > 0.5 else { return }
                activityHeight = height
            }
            .frame(height: revealed ? activityHeight : 0, alignment: .top)
            .clipped()
            // A first asynchronous page or a nested detail changes the measured height. Give
            // that resize its own animation instead of snapping from the loading placeholder.
            .animation(reduced ? nil : .easeInOut(duration: 0.24), value: activityHeight)
            .animation(reduced ? nil : .spring(response: 0.35, dampingFraction: 0.92), value: expanded)
            .opacity(revealed ? 1 : 0)
            .animation(.easeOut(duration: reduced ? 0.10 : 0.14), value: expanded)
            .disabled(!revealed)
            .allowsHitTesting(revealed)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(!revealed)
    }

    @ViewBuilder private func header(at date: Date) -> some View {
        let title = SidekickTranscriptLayout.workLabel(state: state, running: running, waiting: waiting, now: date)
        if canExpand {
            Button {
                withAnimation(reduced ? .easeOut(duration: 0.14) : .spring(response: 0.35, dampingFraction: 0.92)) {
                    presentation.toggleWork(taskID)
                }
            } label: {
                HStack(spacing: 6) {
                    SidekickWorkingText(text: title, shimmering: running && !waiting && active && visible)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).font(.system(size: 11.5))
            .foregroundStyle(SidekickStyle.secondary)
            .help(expanded ? "Hide recorded activity" : "Show recorded activity")
            .accessibilityLabel(title + (expanded ? ", hide activity" : ", show activity"))
            .accessibilityIdentifier("sidekick.work.\(taskID.uuidString)")
        } else {
            Text(title).font(.system(size: 11.5)).foregroundStyle(SidekickStyle.secondary)
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let failureDescription {
                Text(String(failureDescription.prefix(800))).font(.system(size: 12))
                    .foregroundStyle(SidekickStyle.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progressNote {
                Text(progressNote).font(.system(size: 12)).foregroundStyle(SidekickStyle.secondary)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sidekick.liveProgress")
            } else if running && steps.isEmpty && !failed {
                Text(waiting ? "Waiting for your answer…" : "Sidekick is thinking through your task…")
                    .font(.system(size: 11.5)).foregroundStyle(SidekickStyle.secondary)
                    .accessibilityIdentifier("sidekick.thinking")
            }
            if steps.isEmpty && (failed || (!running && (loading || !hasLoaded))) {
                HStack(spacing: 8) {
                    if expanded && !failed { ProgressView().controlSize(.mini) }
                    Text(failed ? "Activity couldn’t be loaded." : "Loading activity…")
                        .font(.system(size: 11.5)).foregroundStyle(SidekickStyle.secondary)
                    if failed { Button("Try again") { revision &+= 1 }.buttonStyle(.plain) }
                }.frame(minHeight: 16)
            }
            ForEach(steps) { step in
                SidekickActivityRow(step: step)
            }
            if !previousCursors.isEmpty || more {
                HStack(spacing: 18) {
                    if !previousCursors.isEmpty {
                        Button("Earlier steps") { cursor = previousCursors.removeLast() }
                    }
                    if more {
                        Button("Next steps") {
                            guard let last = records.last else { return }
                            previousCursors.append(cursor); cursor = last.sequence
                        }
                    }
                    if expanded && loading { ProgressView().controlSize(.mini) }
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(SidekickStyle.secondary)
                    .disabled(loading)
            }
            if failed && !steps.isEmpty {
                Button("Couldn’t refresh activity. Try again") { revision &+= 1 }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(SidekickStyle.secondary)
            }
        }
        .padding(.leading, 17)
        .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.09)).frame(width: 1) }
        .accessibilityIdentifier("sidekick.activity.\(taskID.uuidString)")
    }

    private func load() async {
        guard let store = conversation.store, let generation = conversation.generation else {
            failed = true
            return
        }
        loadToken &+= 1
        let token = loadToken, after = cursor
        loading = true
        defer { if loadToken == token { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(100))
            let (page, projected) = try await Task.detached(priority: .userInitiated) {
                let page = try store.activityRecords(taskID: taskID, after: after, limit: 41)
                return (page, SidekickActivityPresentation.steps(Array(page.prefix(40))))
            }.value
            guard !Task.isCancelled, token == loadToken, conversation.generation == generation else { return }
            records = Array(page.prefix(40)); steps = projected; more = page.count > 40; failed = false; hasLoaded = true
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, token == loadToken, conversation.generation == generation else { return }
            failed = true; SidekickDiagnostics.failure(.historyRead, reason: .readFailed)
        }
    }
}

private struct SidekickActivityRow: View {
    let step: SidekickActivityPresentation.Step
    @State private var details = false
    var body: some View {
        DisclosureGroup(isExpanded: $details) {
            VStack(alignment: .leading, spacing: 8) {
                Text(step.record.event.activity?.name ?? "Activity")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                if let activity = step.record.event.activity {
                    Text(activity.status.rawValue.capitalized).font(.system(size: 10.5))
                    if let arguments = activity.arguments { detail(arguments) }
                    if let result = activity.result { detail(result) }
                }
            }.foregroundStyle(SidekickStyle.secondary).padding(.vertical, 7)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SidekickActivityIcon(identifier: step.appIdentifier, symbol: step.symbol)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title).font(.system(size: 12)).foregroundStyle(SidekickStyle.secondary)
                    if let app = step.appName, !step.title.localizedCaseInsensitiveContains(app) {
                        Text(app).font(.system(size: 10)).foregroundStyle(SidekickStyle.secondary.opacity(0.8))
                    }
                }
                if step.record.event.activity?.status == .failed {
                    Text("Failed").font(.system(size: 10)).foregroundStyle(.orange.opacity(0.8))
                } else if step.record.event.activity?.status == .interrupted {
                    Text("Not confirmed").font(.system(size: 10)).foregroundStyle(SidekickStyle.secondary)
                } else if step.record.event.activity?.status == .started {
                    Text("Started").font(.system(size: 10)).foregroundStyle(SidekickStyle.secondary)
                }
            }
        }
        .tint(SidekickStyle.secondary.opacity(0.7))
    }
    private func detail(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text).font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 180).padding(9)
            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SidekickActivityIcon: View {
    let identifier: String?
    let symbol: String
    var body: some View {
        Group {
            if let identifier, let icon = SidekickActivityIconCache.icon(for: identifier) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else { Image(systemName: symbol).font(.system(size: 12)) }
        }.frame(width: 16, height: 16).accessibilityHidden(true)
    }
}

@MainActor private enum SidekickActivityIconCache {
    static var icons: [String: NSImage] = [:]
    static var resolved = Set<String>()
    static func icon(for identifier: String) -> NSImage? {
        if resolved.contains(identifier) { return icons[identifier] }
        if resolved.count >= 80 { resolved.removeAll(); icons.removeAll() }
        resolved.insert(identifier)
        let url: URL?
        if identifier.hasPrefix("/"), identifier.lowercased().hasSuffix(".app") {
            url = FileManager.default.fileExists(atPath: identifier) ? URL(fileURLWithPath: identifier) : nil
        } else { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) }
        if let url { icons[identifier] = NSWorkspace.shared.icon(forFile: url.path) }
        return icons[identifier]
    }
}
