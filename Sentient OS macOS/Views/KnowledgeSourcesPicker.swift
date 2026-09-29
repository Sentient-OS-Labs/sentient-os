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
    enum Section { case connectors }

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
        VStack(alignment: .leading, spacing: context == .settings ? 30 : 20) {
            if context == .settings {
                Text("Your Sentient needs at least four sources to truly know you.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(flashMinimum ? Theme.Ink.amber : .white.opacity(0.72))
                    .animation(.easeInOut(duration: 0.25), value: flashMinimum)
                    .padding(.top, -16)
            }
            if !fdaGranted { fdaLine }
            emailAndCalendarGroup
                .id(Section.connectors)
            chatsGroup
            SettingsHairline()
            otherAppsGroup
            foldersGroup
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
            ConnectorConnectSheet(source: source, connectors: $connectors, context: context)
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
        SettingsGroup(label: "Folders on this Mac") {
            ChipFlow {
                KnowledgeSourcePill(label: "Desktop", systemImage: "desktopcomputer", selected: runDesktop) {
                    toggleConnector($runDesktop)
                }
                KnowledgeSourcePill(label: "Downloads", systemImage: "arrow.down.to.line", selected: runDownloads) {
                    toggleConnector($runDownloads)
                }
                KnowledgeSourcePill(label: "Documents", systemImage: "doc.text", selected: runDocuments) {
                    toggleConnector($runDocuments)
                }
                ForEach(customRoots, id: \.self) { url in
                    KnowledgeSourcePill(label: url.lastPathComponent, systemImage: "folder",
                                        selected: true, trailingSymbol: "xmark") {
                        CustomRoots.remove(url)
                    }
                    .help("Remove \(url.lastPathComponent) from analysis.")
                }
                KnowledgeSourcePill(label: "Add Folder", systemImage: "folder.badge.plus",
                                    isAction: true, action: chooseFolder)
            }
        }
    }

    private var chatsGroup: some View {
        SettingsGroup(label: "Your conversations") {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { conversationPills }
                    VStack(spacing: 10) { conversationPills }
                }
                sourceNote("Understood privately using Sentient's on-device LLM. Your chats never leave this device.",
                           symbol: "lock")
            }
        }
    }

    @ViewBuilder private var conversationPills: some View {
        if WhatsAppSource.isInstalled {
            KnowledgeSourcePill(label: "WhatsApp",
                                detail: whatsappChats.isEmpty ? "Choose the chats that matter"
                                    : "\(whatsappChats.count) chats selected · Manage",
                                asset: "WhatsAppMark", selected: runWhatsApp && !whatsappChats.isEmpty,
                                featured: true) { showWhatsAppPicker = true }
                .frame(minWidth: 235)
        }
        KnowledgeSourcePill(label: "iMessage",
                            detail: imessageChats.isEmpty ? "Choose the chats that matter"
                                : "\(imessageChats.count) chats selected · Manage",
                            asset: "IMessageMark", selected: runIMessage && !imessageChats.isEmpty,
                            featured: true) { showIMessagePicker = true }
            .frame(minWidth: 235)
    }

    // MARK: - Hosted and direct connectors

    private var emailAndCalendarGroup: some View {
        SettingsGroup(label: "Email & Calendar") {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        emailColumn
                        calendarColumn
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        emailColumn
                        calendarColumn
                    }
                }
                sourceNote("Connect through your own \(ModelBackend.current == .claude ? "Claude" : "ChatGPT") account, never our servers.",
                           symbol: "lock")
            }
        } trailing: {
            Label("Recommended", systemImage: "sparkles")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var emailColumn: some View {
        VStack(alignment: .leading, spacing: 9) {
            KnowledgeSourcePill(label: "Gmail", asset: "GmailMark", selected: runGmail,
                                featured: true, locked: CodexAuth.connectorsLocked) { showGmailConnect = true }
            ForEach(connectorSources.filter { $0.serviceSlug == "outlook-mail" }) { source in
                connectorPill(source, featured: true)
            }
        }
        .frame(minWidth: 235, maxWidth: .infinity, alignment: .leading)
    }

    private var calendarColumn: some View {
        VStack(alignment: .leading, spacing: 9) {
            KnowledgeSourcePill(label: "Google Calendar", asset: "GoogleCalendarMark", selected: runCalendar,
                                featured: true, locked: CodexAuth.connectorsLocked) { showCalendarConnect = true }
            ForEach(connectorSources.filter { $0.serviceSlug == "outlook-calendar" }) { source in
                connectorPill(source, featured: true)
            }
        }
        .frame(minWidth: 235, maxWidth: .infinity, alignment: .leading)
    }

    private var otherAppsGroup: some View {
        SettingsGroup(label: "More of your world") {
            VStack(alignment: .leading, spacing: 12) {
                ChipFlow {
                    ForEach(connectorSources.filter {
                        !["outlook-mail", "outlook-calendar"].contains($0.serviceSlug)
                    }) { source in
                        connectorPill(source)
                    }
                    KnowledgeSourcePill(label: "Apple Notes", asset: "AppleNotesMark", selected: runNotes) {
                        toggleConnector($runNotes)
                    }
                    // Connect More Apps is hidden for this release until discovery can
                    // reliably notice new hosted connections. Curated setup remains available.
                }
            }
        }
    }

    private func connectorPill(_ source: ConnectorSource, featured: Bool = false) -> some View {
        ConnectorPill(source: source,
                      locked: source.usesHostedConnection ? CodexAuth.connectorsLocked : CodexAuth.knowledgeBaseOnly,
                      featured: featured) { selectedConnector = source }
    }

    private func sourceNote(_ text: String, symbol: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9)) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.58))
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
