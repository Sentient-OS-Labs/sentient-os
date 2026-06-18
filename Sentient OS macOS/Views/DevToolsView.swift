//
//  DevToolsView.swift
//  Sentient OS macOS
//
//  The dev cockpit — a sheet behind the home's DEV TOOLS button. This is the control panel for
//  the FILES-iterative system (the hand-drawn INITIAL | ITERATIVE mockup):
//
//    INITIAL                          ITERATIVE
//    • start on device (top→bottom)   • start on device (bottom→top)
//    • tell cloud: make KB exist      • tell cloud: update KB
//    • proactive system               • proactive system
//                       VIEW SUMMARIES
//
//  Initial resets each selected file root and walks newest→oldest; iterative walks only files
//  newer than the saved pointer, oldest→newest. "tell cloud" hands the cycle's summaries to
//  Codex (create / surgical update). "proactive system" sends the reminder-flagged summaries to
//  the placeholder proactive pass, then WIPES the cycle's summaries (the cycle ends). All of it
//  runs through the new self-contained stack (IterativeRun · VaultCloud · CycleStore) — the old
//  Store/Pipeline/messages are untouched, reachable from "More" + the home's Analyze Now.
//
//  `SourceSelection` is the one shared reader of the dbg.run.* prefs, so the home's Analyze Now and
//  this sheet's INITIAL/ITERATIVE buttons act on EXACTLY the same source selection.
//

import SwiftUI
import AppKit

/// One-shot reader of the dev source-picker prefs (same keys as the @AppStorage below; defaults
/// must match: folder toggles ON, DB sources OFF). RootView uses it for Analyze Now; this sheet
/// uses it too. The @AppStorage copies in DevToolsView exist for SwiftUI reactivity.
enum SourceSelection {
    static var chatJIDs: Set<String> {
        Set((UserDefaults.standard.string(forKey: "dbg.whatsapp.chats") ?? "")
            .split(separator: ",").map(String.init))
    }
    static var imessageGUIDs: Set<String> {
        Set((UserDefaults.standard.string(forKey: "dbg.imessage.chats") ?? "")
            .split(separator: ",").map(String.init))
    }

    static func current(customRoots: [URL], fdaGranted: Bool) -> [RunSource] {
        var s: [RunSource] = []
        if bool("dbg.run.downloads", default: true) { s.append(.files(.downloads)) }
        if bool("dbg.run.desktop", default: true) { s.append(.files(.desktop)) }
        if bool("dbg.run.documents", default: true) { s.append(.files(.documents)) }
        s.append(contentsOf: customRoots.map { .files(.custom($0)) })
        if bool("dbg.run.whatsapp", default: false) && fdaGranted && !chatJIDs.isEmpty {
            s.append(.whatsapp(chatJIDs: chatJIDs))
        }
        if bool("dbg.run.imessage", default: false) && fdaGranted && !imessageGUIDs.isEmpty {
            s.append(.imessage(chatGUIDs: imessageGUIDs))
        }
        if bool("dbg.run.notes", default: false) && fdaGranted { s.append(.notes) }
        return s
    }

    private static func bool(_ key: String, default def: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? def
    }
}

/// Tracks which dev action is running + each action's latest status line. MainActor-isolated so a
/// background run's `@Sendable` progress callback can update it safely.
@MainActor
@Observable
final class DevRunModel {
    var busy: String?                       // running action id (nil = idle) → disables all buttons
    var status: [String: String] = [:]      // action id → live/final line
}

/// A queued run for the start-on-device buttons — drives the rich ProcessingView takeover. Carries
/// the on-device connectors AND whether to append the cloud Gmail leg (shown in the same takeover).
struct DeviceJob: Identifiable {
    let id = UUID()
    let connectors: [any Connector]
    let mode: IterativeRun.Mode
    let runGmail: Bool
}

struct DevToolsView: View {
    @Binding var customRoots: [URL]

    @Environment(\.dismiss) private var dismiss

    private static let modelPath = ModelLocator.resolve()

    // The dev source picker (same keys as SourceSelection).
    @AppStorage("dbg.run.downloads") private var runDownloads = true
    @AppStorage("dbg.run.desktop")   private var runDesktop = true
    @AppStorage("dbg.run.documents") private var runDocuments = true
    @AppStorage("dbg.run.whatsapp")  private var runWhatsApp = false
    @AppStorage("dbg.whatsapp.chats") private var selectedChatsCSV = ""
    @AppStorage("dbg.run.imessage")  private var runIMessage = false
    @AppStorage("dbg.imessage.chats") private var selectedIMessageChatsCSV = ""
    @AppStorage("dbg.run.notes")     private var runNotes = false

    @State private var run = DevRunModel()
    @State private var deviceJob: DeviceJob?
    @State private var showChatPicker = false
    @State private var showIMessagePicker = false
    @State private var showSummaries = false
    @State private var showActionItems = false
    @State private var showMore = false
    @State private var fdaGranted = false
    @State private var resetResult: String?
    @State private var showGmailConnect = false
    @AppStorage("dbg.gmail.connected") private var gmailConnected = false
    @AppStorage("dbg.run.gmail")       private var runGmail = false

    // MCP mirror (the hosted Render copy). Local mirrors of MirrorClient's actor state, refreshed
    // when "More" opens and after each action.
    @State private var mirrorEnabled = false
    @State private var mirrorURL: String?
    @State private var mirrorStatus: String?
    @State private var mirrorBusy = false

    private var selectedSources: [RunSource] {
        SourceSelection.current(customRoots: customRoots, fdaGranted: fdaGranted)
    }
    /// Just the FILE roots — what the new INITIAL/ITERATIVE buttons act on (messages/Notes are the
    /// old system's, run from the home's Analyze Now or "More" below).
    private var selectedFileRoots: [FileRoot] {
        selectedSources.compactMap { if case .files(let r) = $0 { return r } else { return nil } }
    }
    private var selectedChatJIDs: Set<String> {
        Set(selectedChatsCSV.split(separator: ",").map(String.init))
    }
    private var selectedIMessageGUIDs: Set<String> {
        Set(selectedIMessageChatsCSV.split(separator: ",").map(String.init))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DEV TOOLS").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)
                Spacer()
                Button("Done") { dismiss() }.controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 22) {
                    sourcePicker

                    if Self.modelPath == nil {
                        Text("On-device model not found — place \(ModelLocator.fileName) next to the .xcodeproj, or set SENTIENT_MODEL_PATH.")
                            .font(.caption2).foregroundStyle(Theme.faint)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }

                    columns
                    HStack(spacing: 10) {
                        viewSummariesButton
                        viewActionItemsButton
                    }
                    mcpToggleButton
                    moreSection
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 720, height: 780)
        .background(Theme.bg)
        .sheet(isPresented: $showSummaries) { SummariesView() }
        .sheet(isPresented: $showActionItems) { ProactiveItemsView() }
        .sheet(isPresented: $showGmailConnect) { GmailConnectSheet() }
        .sheet(item: $deviceJob) { job in
            // Same takeover + same engine as the home "Analyze Now" — dev just gets the prompt pane.
            ProcessingView(modelPath: Self.modelPath ?? "", connectors: job.connectors,
                           mode: job.mode, runGmail: job.runGmail, showPrompt: true) {
                deviceJob = nil
            }
            .frame(minWidth: 600, minHeight: 680)
        }
        .sheet(isPresented: $showChatPicker) {
            ChatPicker(sourceName: "WhatsApp",
                       loadChats: { try WhatsAppSource().listChats() },
                       initialSelection: selectedChatJIDs) { newSel in
                selectedChatsCSV = newSel.sorted().joined(separator: ",")
                runWhatsApp = !newSel.isEmpty
            }
        }
        .sheet(isPresented: $showIMessagePicker) {
            ChatPicker(sourceName: "iMessage",
                       loadChats: { try iMessageSource().listChats() },
                       initialSelection: selectedIMessageGUIDs) { newSel in
                selectedIMessageChatsCSV = newSel.sorted().joined(separator: ",")
                runIMessage = !newSel.isEmpty
            }
        }
        .onAppear {
            fdaGranted = Permissions.hasFullDiskAccess()
            Task { await refreshMirror() }
        }
    }

    // MARK: The two columns

    private var columns: some View {
        HStack(alignment: .top, spacing: 16) {
            columnView("INITIAL") {
                deviceButton("init.device", "start on device\n(top → bottom)", .initial)
                actionButton("init.cloud", "tell cloud:\n“go make knowledge base exist”", "cloud.fill", tint: .purple) { progress in
                    await cloudCreate(progress: progress)
                }
                actionButton("init.proactive", "proactive system", "bell.badge.fill", tint: .orange) { progress in
                    await runProactive(progress: progress)
                }
            }
            Divider().frame(maxHeight: 320).overlay(Theme.stroke)
            columnView("ITERATIVE") {
                deviceButton("iter.device", "start on device\n(bottom → top)", .iterative)
                actionButton("iter.cloud", "tell cloud:\n“go update knowledge base”", "cloud.fill", tint: .purple) { _ in
                    await cloudUpdate()
                }
                actionButton("iter.proactive", "proactive system", "bell.badge.fill", tint: .orange) { progress in
                    await runProactive(progress: progress)
                }
            }
        }
    }

    private func columnView<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.callout.weight(.bold)).tracking(4).foregroundStyle(Theme.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: One action button (spinner while running + a live/final status line)

    private func actionButton(_ id: String, _ title: String, _ systemImage: String, tint: Color,
                              requiresModel: Bool = true, disabled: Bool = false,
                              work: @escaping (@escaping @Sendable (String) -> Void) async -> String) -> some View {
        VStack(spacing: 5) {
            Button {
                run.busy = id
                run.status[id] = "…"
                let progress: @Sendable (String) -> Void = { s in Task { @MainActor in run.status[id] = s } }
                Task {
                    let result = await work(progress)
                    await MainActor.run { run.status[id] = result; run.busy = nil }
                }
            } label: {
                HStack(spacing: 7) {
                    if run.busy == id { ProgressView().controlSize(.small) }
                    else { Image(systemName: systemImage) }
                    Text(title).font(.caption.weight(.medium)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered).tint(tint)
            .disabled(run.busy != nil || (requiresModel && Self.modelPath == nil) || disabled)

            if let s = run.status[id] {
                Text(s)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(s.hasPrefix("✓") ? .green : s.hasPrefix("✗") ? .red : Theme.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var viewSummariesButton: some View {
        Button { showSummaries = true } label: {
            Label("VIEW SUMMARIES", systemImage: "list.bullet.rectangle")
                .font(.caption.weight(.bold)).tracking(2)
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered).tint(Theme.accent)
    }

    private var viewActionItemsButton: some View {
        Button { showActionItems = true } label: {
            Label("VIEW ACTION ITEMS", systemImage: "bell.badge")
                .font(.caption.weight(.bold)).tracking(2)
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered).tint(.orange)
    }

    // MARK: The actions (all on the NEW files-iterative stack)

    /// One of the two "start" buttons. Device sources present the rich ProcessingView takeover;
    /// Gmail (cloud) runs inline with progress in this button's status line.
    private func deviceButton(_ id: String, _ title: String, _ mode: IterativeRun.Mode) -> some View {
        VStack(spacing: 5) {
            Button { startOnDevice(id: id, mode: mode) } label: {
                HStack(spacing: 7) {
                    if run.busy == id { ProgressView().controlSize(.small) }
                    else { Image(systemName: mode == .initial ? "arrow.down.to.line" : "arrow.up.to.line") }
                    Text(title).font(.caption.weight(.medium)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered).tint(.green)
            .disabled(deviceJob != nil || run.busy != nil || (Self.modelPath == nil && !(gmailConnected && runGmail)))
            if let s = run.status[id] {
                Text(s)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(s.hasPrefix("✓") ? .green : s.hasPrefix("✗") ? .red : Theme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Build the connectors from the lit SOURCES + (initial) wipe the vault, then present the rich
    /// ProcessingView takeover for ALL of it — device sources AND Gmail (the cloud leg shows in the
    /// same takeover).
    private func startOnDevice(id: String, mode: IterativeRun.Mode) {
        let gmailRun = gmailConnected && runGmail
        let connectors = RunSource.connectors(from: selectedSources)
        guard gmailRun || !connectors.isEmpty else {
            run.status[id] = "✗ select a source above (folder / chat / Apple Notes / Gmail)"; return
        }
        // Device sources need the on-device model; Gmail (cloud) does not.
        if !connectors.isEmpty && Self.modelPath == nil {
            run.status[id] = "✗ model not found"; return
        }
        if mode == .initial {
            // Fresh start: immediately wipe the existing on-device knowledge base (the vault).
            try? FileManager.default.removeItem(at: VaultGenerator.vaultRoot)
            Log("DevTools: INITIAL — wiped the on-device vault at \(VaultGenerator.vaultRoot.path)")
        }
        run.status[id] = nil
        deviceJob = DeviceJob(connectors: connectors, mode: mode, runGmail: gmailRun)
    }

    private func cloudCreate(progress: @escaping @Sendable (String) -> Void) async -> String {
        let notes = await CycleStore.shared.notes().map(CloudNote.init)
        guard !notes.isEmpty else { return "✗ no summaries — run on-device first" }
        do {
            let r = try await VaultCloud.shared.create(notes: notes) { p in
                switch p {
                case .calling:              progress("… thinking")
                case .writing(let n):       progress("… writing \(n) notes")
                case .materializing(let n): progress("… finishing \(n)")
                case .gathering:            break
                }
            }
            return "✓ \(r.notes) notes / \(r.folders) folders"
        } catch {
            return "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    private func cloudUpdate() async -> String {
        let notes = await CycleStore.shared.notes().map(CloudNote.init)
        guard !notes.isEmpty else { return "✗ no new summaries to fold" }
        do {
            let n = try await VaultCloud.shared.update(notes: notes)
            return "✓ folded \(n) notes into the vault"
        } catch {
            return "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    /// Proactive STEP 1 — the judge. Send the cycle's summaries (windowed to the last week inside
    /// Proactive) + the live vault to Codex and surface the top action items. Read-only: does NOT
    /// wipe the cycle, so it's re-runnable while we tune the prompt. Full detail goes to the console.
    private func runProactive(progress: @escaping @Sendable (String) -> Void) async -> String {
        let notes = await CycleStore.shared.notes().map(CloudNote.init)
        guard !notes.isEmpty else { return "✗ no summaries — run an on-device pass first" }
        progress("Reading the last week + your knowledge base…")
        do {
            let items = try await Proactive.shared.findActionItems(from: notes)
            guard !items.isEmpty else { return "✓ nothing worth surfacing right now" }
            let lines = items.enumerated().map { i, it in
                "\(i + 1). [\(it.urgency.rawValue)\(it.dueDate.map { " · \($0)" } ?? "")] \(it.title)"
            }
            return "✓ \(items.count) action item\(items.count == 1 ? "" : "s") (full detail in console):\n" + lines.joined(separator: "\n")
        } catch {
            return "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    // MARK: Source picker (which folders/connections the buttons act on)

    private var sourcePicker: some View {
        VStack(spacing: 9) {
            Text("SOURCES").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 8) {
                sourceChip("Downloads", selected: runDownloads) { runDownloads.toggle() }
                sourceChip("Desktop",   selected: runDesktop)   { runDesktop.toggle() }
                sourceChip("Documents", selected: runDocuments) { runDocuments.toggle() }
                ForEach(customRoots, id: \.self) { url in
                    sourceChip(url.lastPathComponent, selected: true, removable: true) {
                        customRoots.removeAll { $0 == url }
                    }
                }
                chooseFolderChip
                chatSourceChip("WhatsApp", systemImage: "message.fill",
                               isOn: runWhatsApp && fdaGranted && !selectedChatJIDs.isEmpty,
                               count: selectedChatJIDs.count,
                               turnOff: { runWhatsApp = false },
                               openPicker: { showChatPicker = true })
                chatSourceChip("iMessage", systemImage: "bubble.left.fill",
                               isOn: runIMessage && fdaGranted && !selectedIMessageGUIDs.isEmpty,
                               count: selectedIMessageGUIDs.count,
                               turnOff: { runIMessage = false },
                               openPicker: { showIMessagePicker = true })
                notesChip
                gmailChip
            }
            .frame(maxWidth: 460)

            Text("The INITIAL / ITERATIVE buttons run every selected source (folders + opted chats + Apple Notes + Gmail) through the iterative core. Select only one to test it alone.")
                .font(.caption2).foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notesChip: some View {
        let on = runNotes && fdaGranted
        return HStack(spacing: 6) {
            Image(systemName: on ? "checkmark.circle.fill" : "note.text").font(.system(size: 11))
            Text("Apple Notes").font(.caption.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(on ? .black : (fdaGranted ? Theme.secondary : Theme.faint))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(on ? Theme.accent : Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(on ? .clear : Theme.stroke, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { guard fdaGranted else { return }; runNotes.toggle() }
    }

    /// Gmail (cloud). Not connected → tap opens the connect popup; connected → tap toggles selection.
    private var gmailChip: some View {
        let on = gmailConnected && runGmail
        return HStack(spacing: 6) {
            Image(systemName: on ? "checkmark.circle.fill" : "envelope").font(.system(size: 11))
            Text("Gmail").font(.caption.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(on ? .black : (gmailConnected ? Theme.secondary : Theme.accent))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(on ? Theme.accent : Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(on ? .clear : (gmailConnected ? Theme.stroke : Theme.accent.opacity(0.4)), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { showGmailConnect = true }   // always open the popup (connect / select / remove)
    }

    private func chatSourceChip(_ name: String, systemImage: String, isOn: Bool, count: Int,
                                turnOff: @escaping () -> Void, openPicker: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isOn ? "checkmark.circle.fill" : systemImage).font(.system(size: 11))
            Text(isOn ? "\(name) · \(count)" : name).font(.caption.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(isOn ? .black : (fdaGranted ? Theme.secondary : Theme.faint))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(isOn ? Theme.accent : Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(isOn ? .clear : Theme.stroke, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { guard fdaGranted else { return }; if isOn { turnOff() } else { openPicker() } }
    }

    private func sourceChip(_ label: String, selected: Bool, removable: Bool = false,
                            _ tap: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: removable ? "xmark.circle.fill" : (selected ? "checkmark.circle.fill" : "circle"))
                .font(.system(size: 11))
            Text(label).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(selected ? .black : Theme.secondary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(selected ? Theme.accent : Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(selected ? .clear : Theme.stroke, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture(perform: tap)
    }

    private var chooseFolderChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.plus").font(.system(size: 11))
            Text("Choose folder…").font(.caption.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture(perform: chooseFolder)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Add a folder for Sentient OS to analyze."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !customRoots.contains(url) { customRoots.append(url) }
    }

    // MARK: More (legacy + FDA + reset)

    private var moreSection: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation { showMore.toggle() }
                if showMore {
                    fdaGranted = Permissions.hasFullDiskAccess()
                    Task { await refreshMirror() }
                }
            } label: {
                Label("More", systemImage: showMore ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary)

            if showMore {
                VStack(spacing: 12) {
                    VStack(spacing: 4) {
                        Button(role: .destructive) { Task { await runReset() } } label: {
                            Label("Reset FILE store (pointers + summaries)", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        if let resetResult {
                            Text(resetResult).font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(resetResult.hasPrefix("✓") ? .green : .red)
                        }
                    }

                    fdaPane
                    mirrorPane
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: MCP mirror (opt-in toggle + manual sync — dogfood ahead of the Phase-5 onboarding screen)

    /// The coached system prompt the user pastes into ChatGPT/Claude/Gemini (custom instructions).
    /// Naming the connector + "always call get_structure" is what reliably makes the client load and
    /// use the tools — clients lazy-load connector tools behind a search gate (Arch §7 field learnings).
    static let mcpSystemPrompt = """
        Use the Sentient OS MCP whenever relevant. It gives you access to the user's personal knowledge \
        base, created just for you! It's basically an Obsidian vault of notes about their actual life: \
        their work, projects, plans, relationships, places, preferences, and history, built from their \
        entire digital life (notes, messages, emails, etc.) using on-device LLMs that analyzed their \
        whole digital life.

        In fact, using it would help you improve almost anything you need to help the user with!

        ALWAYS call get_structure at the start of ANY chat with the user.

        It returns the folder and file-name index structure of the vault (so you can know if there's \
        anything you want to read in full), and it also returns the README file of the vault with some \
        incredible general context. So ALWAYS call this at the start of EVERY chat.

        And yeah, any time you think another file is really relevant to a conversation/prompt, go read \
        it in full using get_files!
        """

    /// Put a string on the system clipboard.
    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// The headline MCP control. ON mints the token and pushes the current vault to Render; OFF
    /// deletes the cloud copy but KEEPS the token, so re-enabling reuses the same share link (the
    /// link is what the user pasted into ChatGPT/Claude — toggling must not break those connectors).
    /// The share link + coached system prompt copy right under it (while ON); Sync now / Stats live
    /// in `mirrorPane` under "More".
    private var mcpToggleButton: some View {
        VStack(spacing: 5) {
            Button {
                Task { await runMirror {
                    if mirrorEnabled {
                        await MirrorClient.shared.disable()
                        mirrorStatus = "✓ MCP mirror OFF — cloud copy deleted (link kept)"
                    } else {
                        _ = await MirrorClient.shared.enable()
                        do {
                            try await MirrorClient.shared.push()
                            VaultActivity.shared.vaultDirty = false
                            mirrorStatus = "✓ MCP mirror ON — vault pushed to Render"
                        } catch MirrorClient.MirrorError.noVault {
                            mirrorStatus = "✓ MCP mirror ON — no vault yet (syncs on first KB build)"
                        }
                    }
                } }
            } label: {
                HStack(spacing: 7) {
                    if mirrorBusy { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: mirrorEnabled
                              ? "antenna.radiowaves.left.and.right"
                              : "antenna.radiowaves.left.and.right.slash")
                    }
                    Text("MCP TOGGLE").font(.caption.weight(.bold)).tracking(2)
                    Text(mirrorEnabled ? "ON" : "OFF")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill((mirrorEnabled ? Color.green : Theme.secondary).opacity(0.22)))
                        .foregroundStyle(mirrorEnabled ? .green : Theme.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered).tint(mirrorEnabled ? .green : Theme.secondary)
            .disabled(mirrorBusy)

            if mirrorEnabled, let url = mirrorURL {
                HStack(spacing: 8) {
                    Button {
                        copyToPasteboard(url)
                        mirrorStatus = "✓ MCP link copied — add it as a connector in ChatGPT/Claude"
                    } label: {
                        Label("Copy MCP Link", systemImage: "link")
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                    Button {
                        copyToPasteboard(Self.mcpSystemPrompt)
                        mirrorStatus = "✓ system prompt copied — paste into the model's custom instructions"
                    } label: {
                        Label("Copy System Prompt", systemImage: "text.quote")
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(.purple)
                }
                .frame(maxWidth: 460)
                .disabled(mirrorBusy)

                // Dedicated manual sync — create/update no longer auto-push (they only mark the
                // vault dirty), so this is the explicit "push the vault to the mirror now" step.
                Button {
                    Task { await runMirror {
                        try await MirrorClient.shared.push()
                        VaultActivity.shared.vaultDirty = false
                        mirrorStatus = "✓ synced to mirror"
                    } }
                } label: {
                    HStack(spacing: 7) {
                        if mirrorBusy { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.triangle.2.circlepath") }
                        Text("MCP SYNC").font(.caption.weight(.bold)).tracking(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent).tint(.purple)
                .frame(maxWidth: 460)
                .disabled(mirrorBusy)
            }

            if let mirrorStatus {
                Text(mirrorStatus)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(mirrorStatus.hasPrefix("✓") ? .green : mirrorStatus.hasPrefix("✗") ? .red : Theme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// Detailed mirror actions under "More" — shown only while the mirror is ON (flip it with the
    /// MCP TOGGLE button above). Copy the share URL, force a sync, or read the access-log stats.
    @ViewBuilder private var mirrorPane: some View {
        if mirrorEnabled, let url = mirrorURL {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(Theme.verdictColor(.survivor))
                    Text("MCP mirror — syncs after each KB update")
                        .font(.caption.weight(.medium)).foregroundStyle(.white)
                    Spacer()
                    if mirrorBusy { ProgressView().controlSize(.small) }
                }
                Text(url)
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.faint)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Stats") { Task { await runMirror {
                        let s = try await MirrorClient.shared.stats()
                        let last = s.lastAccess.map {
                            RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())
                        } ?? "never"
                        mirrorStatus = "✓ \(s.notesRead24h) notes · \(s.toolCalls24h) calls (24h) · last \(last)"
                    } } }
                    .buttonStyle(.bordered).controlSize(.small).tint(.white).disabled(mirrorBusy)
                }
            }
            .padding(14).frame(maxWidth: 460).glassCard()
        }
    }

    /// Pull MirrorClient's actor state into the local @State the pane renders from.
    @MainActor private func refreshMirror() async {
        mirrorEnabled = await MirrorClient.shared.isEnabled
        mirrorURL = await MirrorClient.shared.shareURL
    }

    /// Run one mirror action with a busy spinner; funnel thrown errors into the status line and
    /// always refresh the enabled/URL state afterward.
    @MainActor private func runMirror(_ work: @escaping @MainActor () async throws -> Void) async {
        guard !mirrorBusy else { return }
        mirrorBusy = true
        do { try await work() }
        catch { mirrorStatus = "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")" }
        await refreshMirror()
        mirrorBusy = false
    }

    private var fdaPane: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: fdaGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(fdaGranted ? Theme.verdictColor(.survivor) : .orange)
                Text(fdaGranted ? "Full Disk Access granted" : "Full Disk Access needed")
                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                Spacer()
                Button("Re-check") { fdaGranted = Permissions.hasFullDiskAccess() }
                    .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
            }
            if !fdaGranted {
                Text("WhatsApp · iMessage · Apple Notes read protected databases. Grant Full Disk Access, then restart.")
                    .font(.caption2).foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Grant Full Disk Access…") { Permissions.openFullDiskAccessSettings() }
                        .buttonStyle(.bordered).tint(Theme.accent)
                    Button("Restart app") { Permissions.relaunch() }
                        .buttonStyle(.bordered).tint(.white)
                }
            }
        }
        .padding(14).frame(maxWidth: 460).glassCard()
    }

    /// Reset the FILE store only (the new files-iterative pointers + summaries). The old Store
    /// (messages/Notes) is untouched.
    @MainActor
    private func runReset() async {
        await CycleStore.shared.wipeAllNotes()
        // Clear every selected root's pointer too, so the next initial truly starts fresh.
        for root in selectedFileRoots { await CycleStore.shared.clearBucket("file:\(root.id)") }
        let c = await CycleStore.shared.counts()
        resetResult = "✓ cycle store cleared — notes \(c.notes)"
    }
}
