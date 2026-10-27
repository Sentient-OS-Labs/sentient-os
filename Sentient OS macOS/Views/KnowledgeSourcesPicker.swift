//
// KnowledgeSourcesPicker.swift
// Shared source groups and connection flows for Settings and onboarding. Owns folder/chat
// selection, saved connector choices, and sheets. Reports the live selection count to
// personal setup. Permission requests follow an explicit protected-source Connect action.
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
    @AppStorage("dbg.run.downloads") private var runDownloads = false
    @AppStorage("dbg.run.desktop")   private var runDesktop = false
    @AppStorage("dbg.run.documents") private var runDocuments = false
    @AppStorage("dbg.run.notes")     private var runNotes = false
    @AppStorage(SiYuanSource.enabledKey) private var runSiYuan = false
    @AppStorage("dbg.run.whatsapp")  private var runWhatsApp = false
    @AppStorage("dbg.whatsapp.chats") private var whatsappCSV = ""
    @AppStorage("dbg.run.imessage")  private var runIMessage = false
    @AppStorage("dbg.imessage.chats") private var imessageCSV = ""
    @AppStorage("dbg.run.gmail")       private var runGmail = false
    @AppStorage("dbg.run.calendar")       private var runCalendar = false
    @AppStorage(CustomRoots.key) private var customRootsRaw = ""
    @AppStorage(AppleCalendarSource.issueKey) private var calendarReadIssue = ""
    // Re-renders the connector catalog and availability when the engine changes,
    // and keys the census reload below.
    @AppStorage(ModelBackend.key) private var backendRaw = ""

    @State private var protectedSource: ProtectedLocalSource?
    @AppStorage(SourceSelection.pendingProtectedSourceKey) private var pendingProtectedSource = ""
    @State private var connectors: [ConnectorCensus.DetectedConnector] = []
    @State private var selectedConnector: ConnectorSource?
    @State private var showWhatsAppPicker = false
    @State private var showIMessagePicker = false
    @State private var showGmailConnect = false
    @State private var showCalendarConnect = false
    @State private var showAppleMailPicker = false
    @AppStorage(AppleMailSelection.key) private var appleMailAccounts = ""
    @State private var showAppleCalendarConnect = false

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
                Text("Choose at least three sources to set up your personal context.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.top, -16)
            }
            emailAndCalendarGroup
                .id(Section.connectors)
            chatsGroup
            SettingsHairline()
            otherAppsGroup
            foldersGroup
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)) { _ in
                selectionCount = SourceSelection.selectionCount
            }
        .onChange(of: selectionCount, initial: true) { _, count in
            onSelectionCountChange(count)
        }
        // Catalog and saved selections only. Opening this picker never verifies a connection.
        .task(id: backendRaw) { updateConnectors() }
        .task {
            if let source = ProtectedLocalSource(rawValue: pendingProtectedSource) { connectProtectedSource(source) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updateConnectors()
        }
        .sheet(item: $protectedSource, onDismiss: { pendingProtectedSource = "" }) { source in
            SourceAccessSheet(source: source, onStopReading: isProtectedSourceSelected(source) ? {
                stopReading(source)
                pendingProtectedSource = ""
                protectedSource = nil
            } : nil) {
                pendingProtectedSource = ""
                protectedSource = nil
                // Present the source picker only after the permission sheet has dismissed.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    openProtectedSource(source)
                }
            }
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
        .sheet(isPresented: $showAppleMailPicker) {
            AppleMailPicker(initialSelection: AppleMailSelection.accounts) { accounts in
                appleMailAccounts = accounts.sorted().joined(separator: ",")
            }
        }
        .sheet(isPresented: $showAppleCalendarConnect) { AppleCalendarConnectSheet() }
        .sheet(item: $selectedConnector) { source in
            ConnectorConnectSheet(source: source, connectors: $connectors, context: context)
        }
        .onChange(of: backendRaw) { selectedConnector = nil }
        .onReceive(NotificationCenter.default.publisher(for: DirectMCPStore.changed).receive(on: RunLoop.main)) { _ in updateConnectors() }
    }

    /// Clicking a protected app is explicit intent. Merely showing its chip never opens a
    /// database, asks for FDA, or enables a source. The final chat/account choice owns opt-in.
    private func connectProtectedSource(_ source: ProtectedLocalSource) {
        pendingProtectedSource = source.rawValue
        if source.isReadable { pendingProtectedSource = ""; openProtectedSource(source) }
        else { protectedSource = source }
    }

    private func isProtectedSourceSelected(_ source: ProtectedLocalSource) -> Bool {
        switch source {
        case .whatsapp: runWhatsApp
        case .imessage: runIMessage
        case .notes: runNotes
        case .mail: !appleMailAccounts.isEmpty
        }
    }

    private func stopReading(_ source: ProtectedLocalSource) {
        switch source {
        case .whatsapp: runWhatsApp = false
        case .imessage: runIMessage = false
        case .notes: runNotes = false
        case .mail: appleMailAccounts = ""; AppleMailResearchAccess.save(accounts: [])
        }
    }

    private func openProtectedSource(_ source: ProtectedLocalSource) {
        switch source {
        case .whatsapp: showWhatsAppPicker = true
        case .imessage: showIMessagePicker = true
        case .mail: showAppleMailPicker = true
        case .notes: runNotes = true
        }
        selectionCount = SourceSelection.selectionCount
    }

    // MARK: - Local sources

    private var foldersGroup: some View {
        SettingsGroup(label: "Folders on this Mac") {
            ChipFlow {
                KnowledgeSourcePill(label: "Desktop", systemImage: "desktopcomputer", selected: runDesktop) {
                    runDesktop.toggle()
                }
                KnowledgeSourcePill(label: "Downloads", systemImage: "arrow.down.to.line", selected: runDownloads) {
                    runDownloads.toggle()
                }
                KnowledgeSourcePill(label: "Documents", systemImage: "doc.text", selected: runDocuments) {
                    runDocuments.toggle()
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
                sourceNote(PrivacyCopy.conversationSources,
                           symbol: "lock")
            }
        }
    }

    @ViewBuilder private var conversationPills: some View {
        if SourceSelection.shouldShowWhatsApp {
            KnowledgeSourcePill(label: "WhatsApp",
                                detail: protectedDetail(.whatsapp, selected: runWhatsApp && !whatsappChats.isEmpty,
                                    ready: whatsappChats.isEmpty ? "Choose the chats that matter" : "\(whatsappChats.count) chats selected · Manage"),
                                asset: "WhatsAppMark", selected: runWhatsApp && !whatsappChats.isEmpty,
                                featured: true) { connectProtectedSource(.whatsapp) }
                .frame(minWidth: 235)
        }
        KnowledgeSourcePill(label: "iMessage",
                            detail: protectedDetail(.imessage, selected: runIMessage && !imessageChats.isEmpty,
                                ready: imessageChats.isEmpty ? "Choose the chats that matter" : "\(imessageChats.count) chats selected · Manage"),
                            asset: "IMessageMark", selected: runIMessage && !imessageChats.isEmpty,
                            featured: true) { connectProtectedSource(.imessage) }
            .frame(minWidth: 235)
    }

    // MARK: - Hosted and direct connectors

    private var emailAndCalendarGroup: some View {
        SettingsGroup(label: "Email & calendar") {
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
                sourceNote(PrivacyCopy.emailSources,
                           symbol: "lock")
            }
        } trailing: {
            Label("Recommended", systemImage: "sparkles")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var emailColumn: some View {
        let mailSupported = AppleMailSource.isSupported
        return VStack(alignment: .leading, spacing: 9) {
            KnowledgeSourcePill(label: "Gmail", detail: runGmail && !SourceSelection.hostedSourceReady("gmail") ? "Connection needs attention · Manage" : nil,
                                asset: "GmailMark", selected: runGmail,
                                featured: true, locked: CodexAuth.connectorsLocked && !runGmail) { showGmailConnect = true }
            ForEach(connectorSources.filter { $0.serviceSlug == "outlook-mail" }) { source in
                connectorPill(source, featured: true)
            }
            KnowledgeSourcePill(label: "Apple Mail", detail: mailSupported
                                ? protectedDetail(.mail, selected: !appleMailAccounts.isEmpty, ready: nil) : "Requires macOS 26",
                                asset: "AppleMailMark", selected: !appleMailAccounts.isEmpty,
                                featured: true, locked: !mailSupported && appleMailAccounts.isEmpty) {
                if mailSupported { connectProtectedSource(.mail) }
                else { appleMailAccounts = ""; AppleMailResearchAccess.save(accounts: []) }
            }
            .saturation(mailSupported ? 1 : 0)
            .accessibilityValue(!mailSupported ? "Requires macOS 26 or later"
                : appleMailAccounts.isEmpty ? "Not selected"
                : "\(AppleMailSelection.accounts.count) \(AppleMailSelection.accounts.count == 1 ? "account" : "accounts") selected for analysis")
            .help(mailSupported ? "Choose which Apple Mail accounts to include."
                : "Apple Mail requires macOS 26 or later.")
        }
        .frame(minWidth: 235, maxWidth: .infinity, alignment: .leading)
    }

    private var calendarColumn: some View {
        VStack(alignment: .leading, spacing: 9) {
            KnowledgeSourcePill(label: "Google Calendar", detail: runCalendar && !SourceSelection.hostedSourceReady("calendar") ? "Connection needs attention · Manage" : nil,
                                asset: "GoogleCalendarMark", selected: runCalendar,
                                featured: true, locked: CodexAuth.connectorsLocked && !runCalendar) { showCalendarConnect = true }
            ForEach(connectorSources.filter { $0.serviceSlug == "outlook-calendar" }) { source in
                connectorPill(source, featured: true)
            }
            KnowledgeSourcePill(label: "Apple Calendar", detail: appleCalendarDetail,
                                asset: "AppleCalendarMark", selected: AppleCalendarSource.isEnabled,
                                featured: true) { showAppleCalendarConnect = true }
        }
        .frame(minWidth: 235, maxWidth: .infinity, alignment: .leading)
    }

    private var appleCalendarDetail: String? {
        let count = AppleCalendarSource.selectedIDs.count
        if count > 0 && !AppleCalendarSource.hasAccess { return "Calendar access needed · Manage" }
        if count > 0 && !calendarReadIssue.isEmpty && !PipelineActivity.shared.isRunning { return "Analysis needs attention · Manage" }
        return count > 0 ? "\(count) calendars selected · On this Mac" : nil
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
                    KnowledgeSourcePill(label: "Apple Notes", detail: protectedDetail(.notes, selected: runNotes, ready: nil),
                                        asset: "AppleNotesMark", selected: runNotes) {
                        if runNotes { runNotes = false } else { connectProtectedSource(.notes) }
                    }
                    if SiYuanSource.isInstalled || runSiYuan {
                        KnowledgeSourcePill(label: "SiYuan", detail: runSiYuan && !SiYuanSource.isInstalled ? "Workspace unavailable" : nil,
                                            asset: "SiYuanMark", selected: runSiYuan) {
                            runSiYuan.toggle()
                        }
                    }
                    // Connect More Apps is hidden for this release until discovery can
                    // reliably notice new hosted connections. Curated setup remains available.
                }
            }
        }
    }

    private func connectorPill(_ source: ConnectorSource, featured: Bool = false) -> some View {
        ConnectorPill(source: source,
                      locked: !ConnectorRegistry.isKBEnabled(source.connector?.slug ?? source.serviceSlug)
                        && (source.usesHostedConnection ? CodexAuth.connectorsLocked : CodexAuth.knowledgeBaseOnly),
                      featured: featured) { selectedConnector = source }
    }

    private func protectedDetail(_ source: ProtectedLocalSource, selected: Bool, ready: String?) -> String? {
        selected && !source.isReadable ? "Access or synced data needed · Manage" : ready
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

    // Selections are always revocable. The three-source requirement gates starting personal
    // setup, never a user's ability to stop reading a source in Settings.

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

/// Source-specific explanation, reached only by choosing a protected local source. No automatic
/// relaunch: the user can leave this pending while a Sidekick task continues in another window.
private struct SourceAccessSheet: View {
    let source: ProtectedLocalSource
    var onStopReading: (() -> Void)?
    var onReady: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect \(source.title)").display(22)
            Text("macOS protects \(source.title)’s local data with Full Disk Access. Allow Sentient in System Settings to choose what it can read from this source.")
                .font(.system(size: 13)).foregroundStyle(Theme.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your selection stays optional. Granting access does not select any other app or folder.")
                .font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
            if checked {
                Text("Access is not ready yet. If you already allowed Sentient, finish any active tasks and relaunch the app. Also make sure \(source.title) has data synced to this Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let onStopReading {
                Button("Stop reading \(source.title)", action: onStopReading)
            }
            Button("Open Full Disk Access Settings") { Permissions.openFullDiskAccessSettings() }
            Button("Relaunch Sentient") { _ = SafeAppRelaunch.shared.relaunchForPersonalSetup() }
                .disabled(!SafeAppRelaunch.shared.canRelaunch)
            if let reason = SafeAppRelaunch.shared.statusReason {
                Text(reason).font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
            }
            HStack {
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Check again") {
                    if source.isReadable { onReady() }
                    else { checked = true }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(30).frame(width: 440).background(Theme.bg)
    }
}
