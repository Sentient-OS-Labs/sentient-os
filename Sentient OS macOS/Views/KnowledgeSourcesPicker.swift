//
// KnowledgeSourcesPicker.swift
// Shared source groups and connection flows for Settings and onboarding. Owns folder/chat
// selection, saved connector choices, and sheets. Reports the live selection count to
// onboarding; Settings also guards direct toggle-offs at the four-source minimum.
// Doc: Settings/Documentation - Settings.md; Onboarding/Documentation - Onboarding.md
//

import SwiftUI
import Combine
import AppKit

struct KnowledgeSourcesPicker: View {
    enum Context { case settings, onboarding }

    var context: Context = .settings
    var onSelectionCountChange: (Int) -> Void = { _ in }

    // The shared selection keys (defaults must match SourceSelection).
    @AppStorage("dbg.run.downloads") private var runDownloads = true
    @AppStorage("dbg.run.desktop")   private var runDesktop = true
    @AppStorage("dbg.run.documents") private var runDocuments = true
    @AppStorage("dbg.run.notes")     private var runNotes = false
    @AppStorage("dbg.run.whatsapp")  private var runWhatsApp = false
    @AppStorage("dbg.whatsapp.chats") private var whatsappCSV = ""
    @AppStorage("dbg.run.imessage")  private var runIMessage = false
    @AppStorage("dbg.imessage.chats") private var imessageCSV = ""
    @AppStorage("dbg.run.gmail")       private var runGmail = false
    @AppStorage("dbg.run.calendar")       private var runCalendar = false
    @AppStorage(CustomRoots.key) private var customRootsRaw = ""
    // Re-renders the connector catalog and availability when the engine changes,
    // and keys the census reload below.
    @AppStorage(ModelBackend.key) private var backendRaw = ""

    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    @State private var connectors: [ConnectorCensus.DetectedConnector] = []
    @State private var selectedConnector: ConnectorSource?
    @State private var showWhatsAppPicker = false
    @State private var showIMessagePicker = false
    @State private var showGmailConnect = false
    @State private var showCalendarConnect = false
    @State private var flashMinimum = false

    private var customRoots: [URL] { CustomRoots.decode(customRootsRaw) }
    private var whatsappChats: Set<String> { Set(whatsappCSV.split(separator: ",").map(String.init)) }
    private var imessageChats: Set<String> { Set(imessageCSV.split(separator: ",").map(String.init)) }
    private var connectorSources: [ConnectorSource] {
        let sources = ConnectorSource.catalog(with: connectors)
        return context == .onboarding ? sources.filter(\.isCurated) : sources
    }

    // Connector opt-ins use dynamic mcp.<slug>.kb keys, so the fixed @AppStorage properties
    // above cannot observe every selection. Recount on preferences changes, including edits
    // in a connection sheet or another window, and report the live count to onboarding.
    @State private var selectionCount = SourceSelection.selectionCount

    var body: some View {
        VStack(alignment: .leading, spacing: context == .settings ? 30 : 26) {
            if context == .settings {
                Text("Your Sentient needs at least four sources to truly know you.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(flashMinimum ? Theme.Ink.amber : .white.opacity(0.72))
                    .animation(.easeInOut(duration: 0.25), value: flashMinimum)
                    .padding(.top, -16)
            }
            if !fdaGranted { fdaLine }
            foldersGroup
            chatsGroup
            connectorsGroup
        }
        .task { fdaGranted = Permissions.hasFullDiskAccess() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)) { _ in
                selectionCount = SourceSelection.selectionCount
            }
        .onChange(of: selectionCount, initial: true) { _, count in
            onSelectionCountChange(count)
        }
        .onChange(of: connectors) {
            guard context == .onboarding else { return }
            // Apply the onboarding default to saved user connections. A saved false is
            // an explicit opt-out and must survive refreshes, reconnects, and reopening.
            for connector in connectors where ConnectorRegistry.kbEligible(connector.slug) {
                guard UserDefaults.standard.object(forKey: ConnectorRegistry.kbKey(connector.slug)) == nil else { continue }
                ConnectorRegistry.setKBEnabled(connector.slug, true)
            }
            selectionCount = SourceSelection.selectionCount
        }
        // Catalog and saved selections only. Opening this picker never verifies a connection.
        .task(id: backendRaw) { updateConnectors() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaGranted = Permissions.hasFullDiskAccess()   // may have changed in System Settings
            updateConnectors()
        }
        .sheet(isPresented: $showWhatsAppPicker) {
            ChatPicker(sourceName: "WhatsApp", loadChats: { try WhatsAppSource().listChats() },
                       initialSelection: whatsappChats) { sel in
                whatsappCSV = sel.sorted().joined(separator: ","); runWhatsApp = !sel.isEmpty
            }
        }
        .sheet(isPresented: $showIMessagePicker) {
            ChatPicker(sourceName: "iMessage", loadChats: { try iMessageSource().listChats() },
                       initialSelection: imessageChats) { sel in
                imessageCSV = sel.sorted().joined(separator: ","); runIMessage = !sel.isEmpty
            }
        }
        .sheet(isPresented: $showGmailConnect) { CloudConnectSheet(.gmail) }
        .sheet(isPresented: $showCalendarConnect) { CloudConnectSheet(.calendar) }
        .sheet(item: $selectedConnector) { source in
            ConnectorConnectSheet(source: source, connectors: $connectors, onConnect: connectApps)
        }
        .onChange(of: backendRaw) { selectedConnector = nil }
        .onReceive(NotificationCenter.default.publisher(for: DirectMCPStore.changed).receive(on: RunLoop.main)) { _ in updateConnectors() }
    }

    // MARK: - Full Disk Access fix-it (only when missing)

    private var fdaLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusLine(title: "Full Disk Access is off, so WhatsApp, iMessage & Notes can't be read.",
                       health: .warn, note: "not granted", fixTitle: "Grant…") {
                Permissions.openFullDiskAccessSettings()
            }
            SettingsProse("Everything is still read locally; Full Disk Access is just how macOS lets Sentient open those databases. After granting, relaunch Sentient.")
        }
    }

    // MARK: - Local sources

    private var foldersGroup: some View {
        SettingsGroup(label: "Folders") {
            ChipFlow {
                SettingsChip(label: "Desktop", on: runDesktop) { toggleConnector($runDesktop) }
                SettingsChip(label: "Downloads", on: runDownloads) { toggleConnector($runDownloads) }
                SettingsChip(label: "Documents", on: runDocuments) { toggleConnector($runDocuments) }
                ForEach(customRoots, id: \.self) { url in
                    SettingsChip(label: url.lastPathComponent, detail: "✕", on: true) {
                        CustomRoots.remove(url)
                    }
                }
                SettingsChip(label: "+ Add Folder", on: false, isAction: true) { chooseFolder() }
            }
        }
    }

    private var chatsGroup: some View {
        SettingsGroup(label: "Chats & Notes") {
            ChipFlow {
                if WhatsAppSource.isInstalled {
                    SettingsChip(label: "WhatsApp",
                                 detail: whatsappChats.isEmpty ? nil : "\(whatsappChats.count) chats",
                                 on: runWhatsApp && !whatsappChats.isEmpty) { showWhatsAppPicker = true }
                }
                SettingsChip(label: "iMessage",
                             detail: imessageChats.isEmpty ? nil : "\(imessageChats.count) chats",
                             on: runIMessage && !imessageChats.isEmpty) { showIMessagePicker = true }
                SettingsChip(label: "Apple Notes", on: runNotes) { toggleConnector($runNotes) }
            }
        }
    }

    // MARK: - Hosted and direct connectors

    private var connectorsGroup: some View {
        SettingsGroup(label: "Connectors") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsProse("Read through your own connectors, never our servers.")
                ChipFlow {
                    SettingsChip(label: "Gmail", on: runGmail,
                                 locked: CodexAuth.connectorsLocked) { showGmailConnect = true }
                    SettingsChip(label: "Google Calendar", on: runCalendar,
                                 locked: CodexAuth.connectorsLocked) { showCalendarConnect = true }
                    ForEach(connectorSources) { source in
                        ConnectorPill(source: source,
                                      locked: source.usesHostedConnection
                                          ? CodexAuth.connectorsLocked : CodexAuth.knowledgeBaseOnly) {
                            selectedConnector = source
                        }
                    }
                    if context == .settings {
                        SettingsChip(label: "+ Connect Apps", on: false, isAction: true,
                                     locked: CodexAuth.connectorsLocked, action: connectApps)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.35), value: connectors)
        }
    }

    private func connectApps() {
        NSWorkspace.shared.open(ConnectorCensus.directoryURL)
    }

    private func updateConnectors() {
        connectors = ConnectorRegistry.detectedForCurrentBackend().filter { $0.origin != .direct }
            + DirectMCPStore.connections().map(\.detected)
        selectionCount = SourceSelection.selectionCount
    }

    // MARK: - Toggle guards (the four-selection minimum)

    /// The guard fires only on the 4 → 3 drop: onboarding guarantees users start at four or
    /// more, and a pre-onboarding dev state below four must never get trapped by the rule.
    private var atMinimum: Bool { SourceSelection.selectionCount == SourceSelection.minimumSelections }

    /// Every selection counts as one (folders included), so one guard covers every chip.
    private func toggleConnector(_ flag: Binding<Bool>) {
        // Onboarding can freely revise the selection; its Start Analysis button owns the gate.
        if context == .settings && flag.wrappedValue && atMinimum { return flash() }
        flag.wrappedValue.toggle()
    }

    private func flash() {
        flashMinimum = true
        Task { try? await Task.sleep(for: .seconds(1.6)); flashMinimum = false }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Add a folder for Sentient to read."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { CustomRoots.add(url) }
    }
}
