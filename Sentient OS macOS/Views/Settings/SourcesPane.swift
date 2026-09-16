//
//  SourcesPane.swift
//  Sentient OS macOS
//
//  Settings → Knowledge Sources: the real source picker, on the SAME keys as the Analysis
//  popover / Dev Tools / the 3am run (SourceSelection + CustomRoots). Folder chips toggle,
//  custom roots add/remove (persistent), WhatsApp & iMessage open the shared ChatPicker,
//  Gmail & Calendar open their connect sheets. Enforces the four-selection minimum on direct
//  toggles, and surfaces a fix-it line when Full Disk Access is missing.
//  The curated catalog and detected accounts are grouped by their connection route.
//  Connector pills open their connection sheets; this pane owns discovery and refresh.
//
//  Doc: Documentation - Settings.md
//

import SwiftUI
import Combine
import AppKit

struct SourcesPane: View {
    // The shared selection keys (defaults must match SourceSelection).
    @AppStorage("dbg.run.downloads") private var runDownloads = true
    @AppStorage("dbg.run.desktop")   private var runDesktop = true
    @AppStorage("dbg.run.documents") private var runDocuments = true
    @AppStorage("dbg.run.notes")     private var runNotes = false
    @AppStorage("dbg.run.whatsapp")  private var runWhatsApp = false
    @AppStorage("dbg.whatsapp.chats") private var whatsappCSV = ""
    @AppStorage("dbg.run.imessage")  private var runIMessage = false
    @AppStorage("dbg.imessage.chats") private var imessageCSV = ""
    @AppStorage("dbg.gmail.connected") private var gmailConnected = false
    @AppStorage("dbg.run.gmail")       private var runGmail = false
    @AppStorage("dbg.calendar.connected") private var calendarConnected = false
    @AppStorage("dbg.run.calendar")       private var runCalendar = false
    @AppStorage(CustomRoots.key) private var customRootsRaw = ""
    // Re-renders the pane live when the engine changes (the cloud group's header and the
    // Connectors list both follow it), and keys the census reload below.
    @AppStorage(ModelBackend.key) private var backendRaw = ""

    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    @State private var connectors: [ConnectorCensus.DetectedConnector] = []
    @State private var selectedConnector: ConnectorSource?
    @State private var watchStartedAt: Date?          // non-nil = the connect window is polling
    @State private var refreshingConnectors = false
    @State private var showWhatsAppPicker = false
    @State private var showIMessagePicker = false
    @State private var showGmailConnect = false
    @State private var showCalendarConnect = false
    @State private var flashMinimum = false

    private var customRoots: [URL] { CustomRoots.decode(customRootsRaw) }
    private var whatsappChats: Set<String> { Set(whatsappCSV.split(separator: ",").map(String.init)) }
    private var imessageChats: Set<String> { Set(imessageCSV.split(separator: ",").map(String.init)) }
    private var connectorSources: [ConnectorSource] { ConnectorSource.catalog(with: connectors) }

    /// The shared minimum rule (SourceSelection.selectionCount — onboarding's ready screen
    /// enforces the same one). The @AppStorage copies above keep this body re-evaluating live.
    private var selectionCount: Int { SourceSelection.selectionCount }

    var body: some View {
        SettingsPane(title: "Knowledge Sources",
                     whisper: "Your files never leave your Mac. Your Sentient uses an on-device LLM to understand your life overnight.") {
            VStack(alignment: .leading, spacing: 30) {
                // Tucked tight under the whisper so the two lines read as ONE header block,
                // with the full 30pt group gap only after it.
                Text("Your Sentient needs at least four sources to truly know you.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(flashMinimum ? Theme.Ink.amber : .white.opacity(0.72))
                    .animation(.easeInOut(duration: 0.25), value: flashMinimum)
                    .padding(.top, -16)
                if !fdaGranted { fdaLine }
                foldersGroup
                chatsGroup
                cloudGroup
                connectorsGroup
            }
        }
        .task { fdaGranted = Permissions.hasFullDiskAccess() }
        // Paint the persisted census instantly, then confirm live (cheap path: one subprocess
        // on Claude, a disk read on codex, nothing on custom — never a model call).
        .task(id: backendRaw) {
            updateConnectors()
            _ = await ConnectorCensus.list()
            updateConnectors()
        }
        // The connect window. Owning it here means leaving the pane cancels the polling
        // (structured concurrency, no cleanup call); census logs the stop reason.
        .task(id: watchStartedAt) {
            guard watchStartedAt != nil else { return }
            await ConnectorCensus.startWatching { _ in updateConnectors() }
            watchStartedAt = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaGranted = Permissions.hasFullDiskAccess()   // may have changed in System Settings
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
            ConnectorConnectSheet(source: source, connectors: $connectors,
                                  onRefresh: refreshConnectors, onConnect: connectApps,
                                  refreshing: refreshingConnectors)
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

    // MARK: - Sources connected through the selected engine

    private var cloudGroup: some View {
        SettingsGroup(label: ModelBackend.current == .claude ? "Through Your Claude"
                                                             : "Through Your ChatGPT") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsProse("Read through your own connectors, never our servers.")
                ChipFlow {
                    SettingsChip(label: "Gmail", on: gmailConnected && runGmail,
                                 locked: CodexAuth.connectorsLocked) { showGmailConnect = true }
                    SettingsChip(label: "Google Calendar", on: calendarConnected && runCalendar,
                                 locked: CodexAuth.connectorsLocked) { showCalendarConnect = true }
                    ForEach(connectorSources.filter(\.usesHostedConnection)) { source in
                        ConnectorPill(source: source, locked: CodexAuth.connectorsLocked) {
                            selectedConnector = source
                        }
                    }
                    SettingsChip(label: "+ Connect Apps", on: false, isAction: true,
                                 locked: CodexAuth.connectorsLocked, action: connectApps)
                }
                if watchStartedAt != nil {
                    MonoCaps("Watching for new apps", size: 8.5, tracking: 1.6,
                             color: .white.opacity(0.45))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: connectors)
            .animation(.easeInOut(duration: 0.25), value: watchStartedAt != nil)
        } trailing: {
            Button { Task { await refreshConnectors() } } label: {
                if refreshingConnectors {
                    ProgressView().controlSize(.mini)
                } else {
                    MonoCaps("Refresh", size: 8.5, tracking: 1.6, color: .white.opacity(0.55))
                }
            }
            .buttonStyle(PressScaleStyle())
            .disabled(refreshingConnectors)
        }
    }

    // MARK: - Connectors set up directly in Sentient

    private var connectorsGroup: some View {
        ConnectorsSection(sources: connectorSources.filter { !$0.usesHostedConnection },
                          locked: CodexAuth.knowledgeBaseOnly,
                          onSelect: { selectedConnector = $0 })
    }

    /// Open the engine's connector directory and start the bounded polling window, so the new
    /// pill appears on its own once the user finishes linking. A re-press restarts the window.
    private func connectApps() {
        NSWorkspace.shared.open(ConnectorCensus.directoryURL)
        watchStartedAt = Date()
    }

    /// The header's Refresh — the one pane path that warm-runs codex for cache freshness.
    private func refreshConnectors() async {
        guard !refreshingConnectors else { return }
        refreshingConnectors = true
        defer { refreshingConnectors = false }
        _ = await ConnectorCensus.refresh()
        for connection in DirectMCPStore.connections() where connection.state != .reconnect && connection.state != .verifying {
            guard !Task.isCancelled else { return }
            _ = try? await DirectMCPConnections.verifyAccount(connection)
        }
        guard !Task.isCancelled else { return }
        updateConnectors()
    }

    private func updateConnectors() {
        connectors = ConnectorRegistry.detectedForCurrentBackend().filter { $0.origin != .direct }
            + DirectMCPStore.connections().map(\.detected)
    }

    // MARK: - Toggle guards (the four-selection minimum)

    /// The guard fires only on the 4 → 3 drop: onboarding guarantees users start at four or
    /// more, and a pre-onboarding dev state below four must never get trapped by the rule.
    private var atMinimum: Bool { selectionCount == SourceSelection.minimumSelections }

    /// Every selection counts as one (folders included), so one guard covers every chip.
    private func toggleConnector(_ flag: Binding<Bool>) {
        if flag.wrappedValue && atMinimum { return flash() }
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

#Preview("Knowledge Sources pane") {
    SourcesPane()
        .background(Theme.bg)
        .frame(width: 720, height: 720)
}
