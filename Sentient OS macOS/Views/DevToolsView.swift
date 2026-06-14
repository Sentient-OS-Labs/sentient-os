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
//  `SourceSelection` is the one shared reader of the dbg.run.* prefs so the home's Analyze Now and
//  this sheet's legacy Start Analysis run EXACTLY the same selection.
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

/// A queued on-device run for the start-on-device buttons — drives the rich ProcessingView takeover.
struct DeviceJob: Identifiable {
    let id = UUID()
    let connectors: [any Connector]
    let mode: IterativeRun.Mode
}

struct DevToolsView: View {
    let store: Store
    @Binding var customRoots: [URL]
    /// Closes the sheet and hands off to the (legacy) full-pipeline processing takeover.
    var onStartAnalysis: () -> Void

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
    @State private var showMore = false
    @State private var fdaGranted = false
    @State private var resetResult: String?

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
                    viewSummariesButton
                    moreSection
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 720, height: 780)
        .background(Theme.bg)
        .sheet(isPresented: $showSummaries) { SummariesView() }
        .sheet(item: $deviceJob) { job in
            ProcessingView(modelPath: Self.modelPath ?? "", connectors: job.connectors, mode: job.mode) {
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
        .onAppear { fdaGranted = Permissions.hasFullDiskAccess() }
    }

    // MARK: The two columns

    private var columns: some View {
        HStack(alignment: .top, spacing: 16) {
            columnView("INITIAL") {
                deviceButton("init.device", "start on device\n(top → bottom)", .initial)
                actionButton("init.cloud", "tell cloud:\n“go make knowledge base exist”", "cloud.fill", tint: .purple) { progress in
                    await cloudCreate(progress: progress)
                }
                actionButton("init.proactive", "proactive system", "bell.badge.fill", tint: .orange) { _ in
                    await runProactive()
                }
            }
            Divider().frame(maxHeight: 320).overlay(Theme.stroke)
            columnView("ITERATIVE") {
                deviceButton("iter.device", "start on device\n(bottom → top)", .iterative)
                actionButton("iter.cloud", "tell cloud:\n“go update knowledge base”", "cloud.fill", tint: .purple) { _ in
                    await cloudUpdate()
                }
                actionButton("iter.proactive", "proactive system", "bell.badge.fill", tint: .orange) { _ in
                    await runProactive()
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
            .disabled(run.busy != nil || Self.modelPath == nil)

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

    // MARK: The actions (all on the NEW files-iterative stack)

    /// One of the two "start on device" buttons — presents the rich ProcessingView takeover.
    private func deviceButton(_ id: String, _ title: String, _ mode: IterativeRun.Mode) -> some View {
        VStack(spacing: 5) {
            Button { startOnDevice(id: id, mode: mode) } label: {
                HStack(spacing: 7) {
                    Image(systemName: mode == .initial ? "arrow.down.to.line" : "arrow.up.to.line")
                    Text(title).font(.caption.weight(.medium)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered).tint(.green)
            .disabled(deviceJob != nil || Self.modelPath == nil)
            if let s = run.status[id] {   // only set for "✗ …" guidance (no source selected, etc.)
                Text(s).font(.system(.caption2, design: .monospaced)).foregroundStyle(.red)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Build the connectors from the lit SOURCES + (initial) wipe the vault, then present ProcessingView.
    private func startOnDevice(id: String, mode: IterativeRun.Mode) {
        guard Self.modelPath != nil else { run.status[id] = "✗ model not found"; return }
        let roots = selectedFileRoots
        var connectors: [any Connector] = roots.isEmpty ? [] : [FilesConnector(roots: roots)]
        for src in selectedSources {
            switch src {
            case .whatsapp(let jids): connectors.append(WhatsAppConnector(chatJIDs: jids))
            case .imessage(let guids): connectors.append(iMessageConnector(chatGUIDs: guids))
            case .notes:               connectors.append(NotesConnector())
            case .files:               break   // folded into FilesConnector(roots:)
            }
        }
        guard !connectors.isEmpty else {
            run.status[id] = "✗ select a source above (folder / chat / Apple Notes)"; return
        }
        if mode == .initial {
            // Fresh start: immediately wipe the existing on-device knowledge base (the vault).
            try? FileManager.default.removeItem(at: VaultGenerator.vaultRoot)
            Log("DevTools: INITIAL — wiped the on-device vault at \(VaultGenerator.vaultRoot.path)")
        }
        run.status[id] = nil
        deviceJob = DeviceJob(connectors: connectors, mode: mode)
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

    /// Send the reminder-flagged summaries to the placeholder proactive pass, then WIPE the cycle's
    /// summaries (the cycle ends; the next on-device run starts fresh).
    private func runProactive() async -> String {
        let reminders = await CycleStore.shared.reminderNotes().map(CloudNote.init)
        let n = await VaultCloud.shared.proactive(reminderNotes: reminders)   // dummy — no Codex
        await CycleStore.shared.wipeAllNotes()
        return "✓ filtered to send \(n) reminder\(n == 1 ? "" : "s") · summaries wiped"
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
            }
            .frame(maxWidth: 460)

            Text("The INITIAL / ITERATIVE buttons run every selected source (folders + opted chats + Apple Notes) through the iterative core. Select only one to test it alone.")
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
                if showMore { fdaGranted = Permissions.hasFullDiskAccess() }
            } label: {
                Label("More", systemImage: showMore ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary)

            if showMore {
                VStack(spacing: 12) {
                    Button("Start Analysis (legacy)") { onStartAnalysis() }
                        .buttonStyle(.bordered)

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
                }
                .padding(.top, 4)
            }
        }
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
