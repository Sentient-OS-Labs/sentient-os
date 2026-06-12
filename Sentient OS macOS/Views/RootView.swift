//
//  RootView.swift
//  Sentient OS macOS
//
//  The home window. "Start Analysis" (the glow CTA) hands off to the full-screen ProcessingView;
//  "View knowledge" opens the Database viewer. Below: the dev controls (source picker +
//  Reset store) — visible in ALL build configs until real Settings/onboarding ship
//  (re-hide is part of the Phase-6 "Release strip" task). Dark, on-brand.
//

import SwiftUI
import AppKit

struct RootView: View {
    let store: Store
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    @State private var isProcessing = false

    // Resolved at launch (env → bundle → App Support → repo root); nil = model not on this Mac.
    private static let modelPath = ModelLocator.resolve()
    private static let processingLimit: Int? = nil   // nil = process the whole folder

    // The dev source picker: which folders "Start Analysis" runs over. Named-folder toggles
    // persist across launches; custom folders are session-only (re-pick after a relaunch).
    @AppStorage("dbg.run.downloads") private var runDownloads = true
    @AppStorage("dbg.run.desktop")   private var runDesktop = true
    @AppStorage("dbg.run.documents") private var runDocuments = true
    @AppStorage("dbg.run.whatsapp")  private var runWhatsApp = false   // is WhatsApp active this run (chip lit)
    @AppStorage("dbg.whatsapp.chats") private var selectedChatsCSV = ""  // opt-in chat JIDs, comma-joined
    @AppStorage("dbg.run.imessage")  private var runIMessage = false   // is iMessage active this run (chip lit)
    @AppStorage("dbg.imessage.chats") private var selectedIMessageChatsCSV = ""  // opt-in chat GUIDs, comma-joined
    @AppStorage("dbg.run.notes")     private var runNotes = false      // Apple Notes (no picker — all notes, capped)
    @State private var customRoots: [URL] = []
    @State private var showChatPicker = false
    @State private var showIMessagePicker = false
    @State private var resetResult: String?
    @State private var isResetting = false
    @State private var daysEndResult: String?
    @State private var isDaysEndRunning = false
    // "More Options" — advanced debug (Full Disk Access + the DB sources), tucked away so the
    // main debug area stays uncluttered.
    @State private var showMoreOptions = false
    @State private var fdaGranted = false

    /// The sources "Start Analysis" will process: the picker's selection (folders + DB sources).
    private var selectedSources: [RunSource] {
        var s: [RunSource] = []
        if runDownloads { s.append(.files(.downloads)) }
        if runDesktop   { s.append(.files(.desktop)) }
        if runDocuments { s.append(.files(.documents)) }
        s.append(contentsOf: customRoots.map { .files(.custom($0)) })
        // Never run a DB source without FDA + a chat selection.
        if runWhatsApp && fdaGranted && !selectedChatJIDs.isEmpty {
            s.append(.whatsapp(chatJIDs: selectedChatJIDs))
        }
        if runIMessage && fdaGranted && !selectedIMessageGUIDs.isEmpty {
            s.append(.imessage(chatGUIDs: selectedIMessageGUIDs))
        }
        if runNotes && fdaGranted { s.append(.notes) }
        return s
    }

    /// The opt-in chats, decoded from the persisted comma-joined id lists (WhatsApp JIDs / iMessage GUIDs).
    private var selectedChatJIDs: Set<String> {
        Set(selectedChatsCSV.split(separator: ",").map(String.init))
    }
    private var selectedIMessageGUIDs: Set<String> {
        Set(selectedIMessageChatsCSV.split(separator: ",").map(String.init))
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if isProcessing, let modelPath = Self.modelPath {
                ProcessingView(store: store, modelPath: modelPath,
                               sources: selectedSources, limit: Self.processingLimit) {
                    withAnimation(.easeInOut(duration: 0.3)) { isProcessing = false }
                }
                .transition(.opacity)
            } else {
                home.transition(.opacity)
            }
        }
        .frame(minWidth: 560, minHeight: 640)
        .sheet(isPresented: $showChatPicker) {
            ChatPicker(sourceName: "WhatsApp",
                       loadChats: { try WhatsAppSource().listChats() },
                       initialSelection: selectedChatJIDs) { newSel in
                selectedChatsCSV = newSel.sorted().joined(separator: ",")
                runWhatsApp = !newSel.isEmpty   // lit only if at least one chat is chosen
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
    }

    private var home: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer().frame(height: 36)

                GlowButton(title: "Start Analysis", systemImage: "sparkles",
                           active: !selectedSources.isEmpty && Self.modelPath != nil) {
                    withAnimation(.easeInOut(duration: 0.3)) { isProcessing = true }
                }
                .frame(maxWidth: 300)

                if Self.modelPath == nil {
                    Text("On-device model not found — place \(ModelLocator.fileName) next to the .xcodeproj, or set SENTIENT_MODEL_PATH.")
                        .font(.caption2).foregroundStyle(Theme.faint)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button { openWindow(id: DatabaseView.windowID) } label: {
                    Label("View knowledge", systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(.bordered).controlSize(.large).tint(Theme.accent)

                devControls

                VaultView(store: store)
                    .padding(.top, 14)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private var devControls: some View {
        VStack(spacing: 14) {
            Divider().overlay(Theme.stroke).padding(.vertical, 10)
            Text("DEV CONTROLS").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)

            sourcePicker

            debugTest(title: "Reset store", systemImage: "trash",
                      isRunning: isResetting, result: resetResult, passPrefix: "Cleared",
                      action: { Task { await runReset() } })

            // The scheduler's stand-in [DECIDED]: this button IS the day's-end trigger until
            // the condition-gate loop lands — which will call exactly the same entry point
            // (iterative updater → mirror push → notify). Proactive intelligence gets its
            // own separate trigger when it lands.
            debugTest(title: "Update Knowledge Base", systemImage: "arrow.triangle.2.circlepath",
                      isRunning: isDaysEndRunning, result: daysEndResult, passPrefix: "Done",
                      action: { Task { await runDaysEnd() } })

            Button {
                withAnimation { showMoreOptions.toggle() }
                if showMoreOptions { fdaGranted = Permissions.hasFullDiskAccess() }
            } label: {
                Label("More Options", systemImage: showMoreOptions ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary)

            if showMoreOptions { moreOptions }
        }
    }

    // MARK: More Options (advanced DEBUG: Full Disk Access + DB sources)

    private var moreOptions: some View {
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
                Text("The database sources (WhatsApp · iMessage · Notes) read protected databases. Grant Full Disk Access, then restart.")
                    .font(.caption2).foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Grant Full Disk Access…") { Permissions.openFullDiskAccessSettings() }
                        .buttonStyle(.bordered).tint(Theme.accent)
                    Button("Restart app") { Permissions.relaunch() }
                        .buttonStyle(.bordered).tint(.white)
                }
            } else {
                Text("Database sources (WhatsApp · iMessage · Notes) are unlocked — pick them up in SOURCES above.")
                    .font(.caption2).foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: 460)
        .glassCard()
    }

    // MARK: Source picker (DEBUG) — pick which folders "Start Analysis" runs over

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
                // DB sources — enabled once Full Disk Access is granted (see More Options).
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
            .frame(maxWidth: 420)

            if selectedSources.isEmpty {
                Text("Select at least one source to analyze.")
                    .font(.caption2).foregroundStyle(Theme.faint)
            }
            if !fdaGranted {
                Text("WhatsApp, iMessage & Apple Notes need Full Disk Access — grant it in More Options below.")
                    .font(.caption2).foregroundStyle(Theme.faint)
            }
        }
        .onAppear { fdaGranted = Permissions.hasFullDiskAccess() }
    }

    /// Apple Notes chip — a plain FDA-gated toggle (no picker: all notes go in, capped inside
    /// the source). Same look as the chat chips, minus the count.
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
        .onTapGesture {
            guard fdaGranted else { return }
            runNotes.toggle()
        }
    }

    /// A chat-DB source chip (WhatsApp / iMessage). Tap when OFF → opens that source's chat
    /// picker → Done lights it up (with the chat count). Tap when ON → turns it off (keeps the
    /// selection for next time).
    private func chatSourceChip(_ name: String, systemImage: String, isOn: Bool, count: Int,
                                turnOff: @escaping () -> Void,
                                openPicker: @escaping () -> Void) -> some View {
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
        .onTapGesture {
            guard fdaGranted else { return }
            if isOn { turnOff() }          // ON → off (selection kept)
            else { openPicker() }          // OFF → choose chats
        }
    }

    private func sourceChip(_ label: String, selected: Bool, removable: Bool = false,
                            _ tap: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: removable ? "xmark.circle.fill"
                              : (selected ? "checkmark.circle.fill" : "circle"))
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

    /// Pick any folder(s) to add as custom sources for this session.
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

    @ViewBuilder
    private func debugTest(title: String, systemImage: String, isRunning: Bool,
                           result: String?, passPrefix: String,
                           action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                if isRunning { ProgressView().controlSize(.small) }
                Label(title, systemImage: systemImage)
            }
            .disabled(isRunning)

            if let result {
                Text(result)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(result.hasPrefix(passPrefix) ? .green
                                     : result.contains("FAIL") ? .red : Theme.secondary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
            }
        }
    }

    @MainActor
    private func runDaysEnd() async {
        isDaysEndRunning = true
        defer { isDaysEndRunning = false }
        daysEndResult = await DaysEndJob.shared.run(store: store)
    }

    @MainActor
    private func runReset() async {
        isResetting = true
        defer { isResetting = false }
        do {
            try await store.reset()
            LifetimeStats.reset()
            let counts = await store.counts()
            resetResult = "Cleared ✓  summaries=\(counts.versions)  pointers=\(counts.cursors)"
        } catch {
            resetResult = "Reset FAIL: \(error)"
        }
    }
}
