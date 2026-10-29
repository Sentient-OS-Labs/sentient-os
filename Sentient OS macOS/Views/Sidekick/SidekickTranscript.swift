import SwiftUI
import AppKit

struct SidekickTranscript: View {
    let conversation: SidekickConversation
    let coordinator: CommandCoordinator
    @Bindable var presentation: SidekickPresentation
    var active: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reduced: Bool { motionOverride ?? systemReduced }
    private struct RefreshKey: Equatable {
        let generation: UUID?
        let revision: UInt64
        let ready: Bool
    }
    private struct NavigationKey: Equatable {
        let generation: UUID?
        let request: UUID?
    }
    private struct ActiveWorkKey: Equatable {
        let generation: UUID?
        let taskID: UUID?
    }
    private var activeWorkKey: ActiveWorkKey {
        .init(generation: conversation.generation, taskID: coordinator.run.isRunning ? coordinator.run.runID : nil)
    }
    private var refreshKey: RefreshKey {
        RefreshKey(generation: conversation.generation, revision: conversation.revision,
                   ready: active && conversation.navigationRequest == nil && !presentation.searchShown
                       && presentation.newMessages && presentation.canFollowLatest)
    }

    var body: some View {
        VStack(spacing: 0) {
            if presentation.searchShown { searchBar.transition(.move(edge: .top).combined(with: .opacity)) }
            if !presentation.search.isEmpty && presentation.searchShown {
                searchResults
            } else {
                transcript
            }
        }
        .onChange(of: activeWorkKey, initial: true) { _, key in
            presentation.followActiveWork(key.taskID, generation: key.generation)
        }
        .onChange(of: active, initial: true) { _, visible in
            guard visible, conversation.navigationRequest == nil else { return }
            presentation.resumeFollowing(generation: conversation.generation)
        }
        .onAppear { presentation.isScrolling = false }
        .onDisappear { presentation.isScrolling = false }
        .task(id: NavigationKey(generation: conversation.generation, request: conversation.navigationRequest)) {
            presentation.resetForGeneration(conversation.generation)
            if let request = conversation.navigationRequest {
                presentation.search = ""; presentation.searchShown = false
                if let id = conversation.destinationMessageID {
                    await presentation.load(.around(id), conversation: conversation)
                } else { await presentation.load(.latest, conversation: conversation, animated: active && !reduced) }
                if !Task.isCancelled && conversation.navigationRequest == request { conversation.consumeDestination() }
            } else if presentation.rows.isEmpty { await presentation.load(.latest, conversation: conversation) }
        }
        .onChange(of: conversation.revision) { _, _ in
            presentation.newMessages = true
        }
        .task(id: conversation.revision) { await presentation.refreshTaskStates(conversation: conversation) }
        .task(id: refreshKey) {
            guard refreshKey.ready else { return }
            await presentation.load(.latest, conversation: conversation, animated: !reduced, automaticallyFollowing: true)
        }
    }

    private var transcript: some View {
        // Capture rows and their generation together. A retained old row must not borrow
        // the conversation's newer identity while Clear chat is replacing the viewport.
        let generation = presentation.generation
        let display = SidekickTranscriptLayout.rows(presentation.rows)
        return ScrollViewReader { proxy in
            ScrollView {
                // History is already paged (normally 40, at most 100 records). Stable
                // measured rows avoid lazy estimated-height gaps when a live disclosure
                // moves into its final response while the window is hidden.
                VStack(alignment: .leading, spacing: 18) {
                    if presentation.hasEarlier {
                        pagingButton("Earlier messages", symbol: "arrow.up") {
                            guard let first = presentation.rows.first else { return }
                            Task { await presentation.load(.earlier(first.sequence), conversation: conversation) }
                        }
                    }
                    if let error = presentation.error {
                        VStack(spacing: 8) {
                            Text(error).font(.system(size: 12)).foregroundStyle(SidekickStyle.secondary)
                            Button("Try again") { Task { await presentation.load(.latest, conversation: conversation) } }
                        }.frame(maxWidth: .infinity)
                    }
                    if presentation.rows.isEmpty && !presentation.loading && presentation.error == nil && conversation.storageError == nil {
                        VStack(spacing: 12) {
                            SidekickMark(size: 32, illuminated: true).padding(.bottom, 10)
                            Text("A little help. A lot more possible.").font(.system(size: 23, weight: .medium))
                            Text("Ask a question, follow a thought, or hand something over.")
                                .font(.system(size: 13)).foregroundStyle(SidekickStyle.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 110)
                    }
                    ForEach(display) { row in
                        VStack(spacing: 18) {
                            if let date = row.timeBreak {
                                HStack(spacing: 12) {
                                    Rectangle().fill(.white.opacity(0.07)).frame(maxWidth: 70).frame(height: 0.5)
                                    Text(SidekickTranscriptLayout.timeBreakLabel(date))
                                        .font(.system(size: 10.5)).foregroundStyle(SidekickStyle.secondary)
                                    Rectangle().fill(.white.opacity(0.07)).frame(maxWidth: 70).frame(height: 0.5)
                                }.frame(maxWidth: .infinity).padding(.vertical, 7)
                            }
                            SidekickMessageRow(record: row.record, showsWork: row.showsWork,
                                generation: generation, conversation: conversation, coordinator: coordinator,
                                presentation: presentation, active: active)
                        }
                        .id(row.id)
                        .transition(SidekickStyle.entrance(reduced))
                    }
                    if presentation.hasLater {
                        pagingButton("Later messages", symbol: "arrow.down") {
                            guard let last = presentation.rows.last else { return }
                            Task { await presentation.load(.later(last.sequence), conversation: conversation) }
                        }
                    } else if coordinator.run.isRunning && !display.contains(where: { $0.showsWork && $0.record.event.taskID == coordinator.run.runID }) {
                        SidekickWorkDisclosure(conversation: conversation, taskID: coordinator.run.runID,
                            state: presentation.taskStates[coordinator.run.runID], presentation: presentation,
                            running: true, waiting: coordinator.run.recovery.isPending, active: active,
                            liveStatus: coordinator.run.statusLine)
                            .padding(.horizontal, 12)
                    }
                    Color.clear.frame(height: 1).id("sidekick-bottom")
                }
                .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 12)
                .frame(maxWidth: 800).frame(maxWidth: .infinity)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            // A final response can acquire its activity height after the explicit scroll
            // request. Keep followers at the native bottom through those size changes;
            // deliberate history reading/selection keeps its existing viewport instead.
            .defaultScrollAnchor(presentation.canFollowLatest ? .bottom : nil, for: .sizeChanges)
            .onScrollPhaseChange { _, phase, context in
                // Programmatic smooth scrolling is not a new reading gesture. Use this
                // phase's actual geometry so a late layout callback cannot re-enable follow.
                let bottom = context.geometry.contentSize.height - context.geometry.visibleRect.maxY < 70
                presentation.userScrollChanged(phase == .tracking || phase == .interacting || phase == .decelerating,
                                               atLatest: bottom)
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
                }
            }
            // ScrollViewReader owns navigation and live following. A second top-anchored
            // scrollPosition binding competes with bottom following as row heights change.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.height - geo.visibleRect.maxY < 70
            } action: { _, bottom in presentation.viewportChanged(atLatest: bottom) }
            .task(id: presentation.scrollRequest) {
                let request = presentation.scrollRequest
                let requestedDestination = presentation.navigationTarget
                let automatic = presentation.scrollIsAutomatic
                let intent = presentation.readingIntentRevision
                // Activity rows and their expanded viewport measure in the next layout pass.
                // Coalesce bursts before scrolling to the new actual tail, not its old frame.
                await Task.yield()
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard !Task.isCancelled, request == presentation.scrollRequest,
                      let requestedTarget = requestedDestination else { return }
                let target = SidekickTranscriptLayout.destination(requestedTarget, records: presentation.rows)
                guard !automatic || (active && intent == presentation.readingIntentRevision
                    && presentation.canFollowLatest) else { return }
                let tail = target == "sidekick-bottom" || target.hasPrefix("sidekick-work-bottom-")
                if tail && !reduced {
                    withAnimation(.smooth(duration: 0.28)) { proxy.scrollTo(target, anchor: .bottom) }
                } else { proxy.scrollTo(target, anchor: tail ? .bottom : .top) }
            }
            .overlay(alignment: .bottom) {
                if presentation.hasLater || (presentation.newMessages && !presentation.atLatest)
                    || (!presentation.followsLatest && presentation.activeWorkTaskID != nil) {
                    Button {
                        Task { await presentation.load(.latest, conversation: conversation) }
                    } label: {
                        Label(presentation.newMessages ? "New response" : "Back to latest", systemImage: "arrow.down")
                            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 15).padding(.vertical, 10)
                            .sidekickGlass(radius: 20, prominent: true)
                    }
                    .buttonStyle(SidekickPressStyle()).padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        // A deleted conversation has a new identity, including its native scroll viewport.
        // Do not retain a months-old content offset over the fresh empty state.
        .id(conversation.generation)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(SidekickStyle.secondary)
            TextField("Find something in your history", text: $presentation.search)
                .textFieldStyle(.plain).font(.system(size: 13))
                .accessibilityIdentifier("sidekick.history.search")
                .focused($searchFocused)
                .task {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    searchFocused = true
                }
                .onExitCommand { presentation.search = ""; presentation.searchShown = false }
            if !presentation.search.isEmpty {
                Button { presentation.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
            Button("Done") { withAnimation(SidekickStyle.motion(reduced)) { presentation.search = ""; presentation.searchShown = false } }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(SidekickStyle.accent)
        }.padding(12).sidekickGlass(radius: 14)
            .padding(.horizontal, 28).padding(.bottom, 8).frame(maxWidth: 800)
            .task(id: presentation.search) { await presentation.find(conversation: conversation) }
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text(presentation.searchResults.isEmpty ? "No matching messages yet" : "From your saved conversation")
                    .font(.system(size: 11)).foregroundStyle(SidekickStyle.secondary).padding(.vertical, 12)
                ForEach(presentation.searchResults, id: \.event.id) { record in
                    Button {
                        presentation.search = ""; presentation.searchShown = false
                        Task { await presentation.load(.around(record.event.id), conversation: conversation) }
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(record.event.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.system(size: 10)).foregroundStyle(SidekickStyle.secondary)
                            Text(String(record.event.text.prefix(700))).font(.system(size: 13)).lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(16).sidekickGlass(radius: 16)
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 28).frame(maxWidth: 800).frame(maxWidth: .infinity)
        }
    }
    private func pagingButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)) }
            .buttonStyle(.plain).foregroundStyle(SidekickStyle.secondary).disabled(presentation.loading)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}

private struct SidekickMessageRow: View {
    let record: SidekickConversationStore.Record
    let showsWork: Bool
    let generation: UUID?
    let conversation: SidekickConversation
    let coordinator: CommandCoordinator
    let presentation: SidekickPresentation
    var active: Bool
    @State private var visible = false
    @State private var hovered = false
    @State private var copied = false
    @Environment(\.sidekickHoveredMessageID) private var hoverOverride
    private var event: SidekickConversationEvent { record.event }
    private var user: Bool { event.kind == .userMessage || event.kind == .answer }
    private var incoming: Bool { event.kind == .assistantMessage || event.kind == .question }
    private var running: Bool { coordinator.run.isRunning && coordinator.run.runID == event.taskID }
    private struct ReadReceiptKey: Equatable {
        let generation: UUID?
        let messageID: String
        let visible: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsWork {
                SidekickWorkDisclosure(conversation: conversation, taskID: event.taskID,
                    state: presentation.taskStates[event.taskID], presentation: presentation,
                    running: running, waiting: running && coordinator.run.recovery.isPending, active: active,
                    liveStatus: running ? coordinator.run.statusLine : "")
                    .padding(.horizontal, 12)
            }
            if event.kind == .taskFinished {
                if let status = standaloneStatus {
                    Text(status).font(.system(size: 12)).foregroundStyle(SidekickStyle.secondary)
                        .textSelection(.enabled).padding(.horizontal, 12)
                }
            } else { message }
        }
        .foregroundStyle(SidekickStyle.ink)
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .task(id: ReadReceiptKey(generation: generation, messageID: event.id, visible: active && visible)) {
            guard incoming, active, visible, let generation, conversation.generation == generation else { return }
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard !Task.isCancelled, active, visible, conversation.generation == generation else { return }
            conversation.markRead(messageIDs: [event.id], generation: generation)
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.8)); copied = false } catch { }
        }
    }

    private var message: some View {
        HStack(alignment: .top, spacing: 0) {
            if user { Spacer(minLength: 58) }
            VStack(alignment: .leading, spacing: 10) {
                if let reference = event.reply {
                    Button { conversation.show(messageID: reference.messageID) } label: {
                        Label(reference.selectedText.map { String($0.prefix(100)) } ?? "Earlier message", systemImage: "arrowshape.turn.up.left")
                            .font(.system(size: 10.5)).lineLimit(2).foregroundStyle(SidekickStyle.accent)
                    }.buttonStyle(.plain)
                }
                if user {
                    SidekickPlainText(text: event.text, onReply: { reply($0) }, onReplyToMessage: { reply(nil) },
                        onSelectionChange: { presentation.setSelection($0, messageID: event.id) })
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    SidekickMarkdown(markdown: event.text, compact: event.messageKind == .update,
                        onReply: reply, onReplyToMessage: { reply(nil) },
                        onSelectionChange: { presentation.setSelection($0, messageID: event.id) })
                        .opacity(event.messageKind == .update ? 0.76 : 1)
                }
            }
            .padding(.horizontal, user ? 17 : 12).padding(.vertical, user ? 12 : 0)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(user ? Color(white: 0.075) : .clear)
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(user ? 0.075 : 0)))
            .contextMenu {
                Button("Copy message", systemImage: "doc.on.doc", action: copy)
                Button("Reply to message", systemImage: "arrowshape.turn.up.left") { reply(nil) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(user ? "Your message" : "Sidekick response")
            .accessibilityAction(named: "Copy message", copy)
            .accessibilityAction(named: "Reply to message") { reply(nil) }
            if !user { Spacer(minLength: 14) }
        }
        // A quiet reserved gutter avoids shifting the conversation when controls appear.
        .padding(.bottom, 20)
        .overlay(alignment: user ? .bottomTrailing : .bottomLeading) {
            if hovered || copied || hoverOverride == event.id {
                HStack(spacing: 8) {
                    Text(SidekickTranscriptLayout.hoverDate(event.createdAt))
                        .font(.system(size: 10))
                        .help(event.createdAt.formatted(date: .complete, time: .shortened))
                    Button(action: copy) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5)).frame(width: 22, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(copied ? "Copied" : "Copy message")
                    .accessibilityLabel(copied ? "Copied" : "Copy message")
                }
                .foregroundStyle(SidekickStyle.secondary.opacity(0.9))
                .padding(.horizontal, user ? 5 : 12)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var standaloneStatus: String? {
        guard event.outcome == .success || event.outcome == .failed else { return nil }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !["done", "completed", "✓ done", "✓ completed"].contains(text.lowercased()) else { return nil }
        return text
    }
    private func copy() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(event.text, forType: .string)
        copied = true
    }
    private func reply(_ selected: String?) {
        conversation.replyReference = .init(messageID: event.id, selectedText: selected)
    }
}
