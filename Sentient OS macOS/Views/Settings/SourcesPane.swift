//
//  SourcesPane.swift
//  Sentient OS macOS
//
//  Settings → Knowledge Sources: the real source picker, on the SAME keys as the Analysis
//  popover / Dev Tools / the 3am run (SourceSelection + CustomRoots). Folder chips toggle,
//  custom roots add/remove (persistent), WhatsApp & iMessage open the shared ChatPicker,
//  Gmail & Calendar open their connect sheets. Enforces the four-selection minimum on direct
//  toggles, and surfaces a fix-it line when Full Disk Access is missing.
//  Below the cloud chips sits the Connectors section (ConnectorsSection · ConnectorPill ·
//  ConnectorPopover): the hosted apps already linked to the user's engine account, detected by
//  ConnectorCensus, with the "+ Connect Apps" polling window and the per-connector
//  "Use for knowledge base" toggle (`mcp.<slug>.kb`).
//

import SwiftUI
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
            connectors = ConnectorRegistry.detectedForCurrentBackend()
            connectors = await ConnectorCensus.list()
        }
        // The connect window. Owning it here means leaving the pane cancels the polling
        // (structured concurrency, no cleanup call); census logs the stop reason.
        .task(id: watchStartedAt) {
            guard watchStartedAt != nil else { return }
            await ConnectorCensus.startWatching { connectors = $0 }
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

    // MARK: - Cloud sources

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
                }
            }
        }
    }

    // MARK: - Connectors (the hosted apps linked to the engine account)

    private var connectorsGroup: some View {
        ConnectorsSection(connectors: connectors,
                          locked: CodexAuth.connectorsLocked,
                          watching: watchStartedAt != nil,
                          refreshing: refreshingConnectors,
                          engineWord: engineWord,
                          onConnect: connectApps,
                          onRefresh: refreshConnectors)
    }

    private var engineWord: String {
        switch ModelBackend.current {
        case .claude:  return "Claude"
        case .chatgpt: return "ChatGPT"
        case .custom:  return "ChatGPT or Claude"   // the section is locked there; matches the tip
        }
    }

    /// Open the engine's connector directory and start the bounded polling window, so the new
    /// pill appears on its own once the user finishes linking. A re-press restarts the window.
    private func connectApps() {
        NSWorkspace.shared.open(ConnectorCensus.directoryURL)
        watchStartedAt = Date()
    }

    /// The header's Refresh — the one pane path that warm-runs codex for cache freshness.
    private func refreshConnectors() {
        guard !refreshingConnectors else { return }
        Task {
            refreshingConnectors = true
            connectors = await ConnectorCensus.refresh()
            refreshingConnectors = false
        }
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

// MARK: - The Connectors section (pure render; SourcesPane owns the state and the polling)

/// The hosted apps already linked to the user's ChatGPT/Claude account, as pills. Pills are
/// NOT source toggles: presence + health + a popover. The popover's KB toggle is what counts
/// toward the four-source minimum (SourceSelection reads `mcp.<slug>.kb`); turning it OFF is
/// deliberately un-guarded, matching the Gmail sheet's "Stop reading" precedent.
private struct ConnectorsSection: View {
    let connectors: [ConnectorCensus.DetectedConnector]
    let locked: Bool
    let watching: Bool
    let refreshing: Bool
    let engineWord: String
    let onConnect: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        SettingsGroup(label: "Connectors") {
            VStack(alignment: .leading, spacing: 12) {
                if connectors.isEmpty {
                    SettingsProse("Nothing connected yet. Link apps to your \(engineWord) and they appear here.")
                }
                ChipFlow {
                    ForEach(connectors) { connector in
                        ConnectorPill(connector: connector, locked: locked)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    SettingsChip(label: "+ Connect Apps", on: false, isAction: true,
                                 locked: locked) { onConnect() }
                }
                if watching {
                    MonoCaps("Watching for new apps", size: 8.5, tracking: 1.6,
                             color: .white.opacity(0.45))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: connectors)
            .animation(.easeInOut(duration: 0.25), value: watching)
        } trailing: {
            Button(action: onRefresh) {
                if refreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    MonoCaps("Refresh", size: 8.5, tracking: 1.6, color: .white.opacity(0.55))
                }
            }
            .buttonStyle(PressScaleStyle())
            .disabled(refreshing)
        }
    }
}

/// One detected connector: display name behind a live health LED. Deliberately NOT a
/// SettingsChip — a chip's green wash means "this source is selected", while a pill carries
/// presence + health and opens its popover — but the capsule geometry, type size, and press
/// behavior match SettingsChip exactly so the two rows read as one family.
private struct ConnectorPill: View {
    let connector: ConnectorCensus.DetectedConnector
    let locked: Bool

    @State private var showPopover = false
    @State private var lockHover = false

    @ViewBuilder var body: some View {
        if locked {
            pill
                .onHover { lockHover = $0 }
                .overlay(alignment: .top) {
                    if lockHover { LockedChipTip().offset(y: -32) }
                }
                .animation(.easeInOut(duration: 0.15), value: lockHover)
        } else {
            pill
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    ConnectorPopover(connector: connector)
                }
        }
    }

    private var pill: some View {
        Button { if !locked { showPopover = true } } label: {
            HStack(spacing: 7) {
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    HealthDot(color: connector.healthy ? Theme.Ink.green : HealthDot.warnAmber)
                }
                Text(ConnectorRegistry.pack(for: connector)?.displayName ?? connector.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(locked ? 0.55 : 1))
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .overlay(Capsule().strokeBorder(Color.white.opacity(locked ? 0.10 : 0.16), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// The pill's popover: identity, health, and the ONE toggle — "Use for knowledge base"
/// (`mcp.<slug>.kb`). On the Claude engine an uncurated connector must be classified before it
/// may switch on (fail closed: no read list, no toggle); that runs inline behind a spinner and
/// reverts quietly on failure. The key persists as true only AFTER a successful classification,
/// so dismissing the popover mid-run can never leave an unclassified connector enabled.
/// Landing ON also kicks off the first read (MCPReadActivity — dismissible, the read continues;
/// skipped when the bucket was already read or a pipeline run is active). OFF just stops
/// future reads: bucket and summaries remain, deletion is FactoryReset's job (the Gmail
/// disconnect precedent).
private struct ConnectorPopover: View {
    let connector: ConnectorCensus.DetectedConnector

    @State private var kbOn = false
    @State private var classifying = false
    @State private var classifyFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ConnectorRegistry.pack(for: connector)?.displayName ?? connector.displayName)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Text(connector.origin == .claude ? "Through your Claude" : "Through your ChatGPT")
                    .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
            }
            HStack(spacing: 7) {
                HealthDot(color: connector.healthy ? Theme.Ink.green : HealthDot.warnAmber)
                Text(connector.healthy ? "Connected" : "Not responding")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.statusInk)
            }
            SettingsHairline()
            HStack(spacing: 12) {
                Text("Use for knowledge base")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                Spacer(minLength: 12)
                if classifying {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: kbBinding)
                        .labelsHidden().toggleStyle(.switch).tint(Theme.Ink.green)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                MonoCaps("Reads nightly · read-only", size: 8, tracking: 1.6,
                         color: .white.opacity(0.5))
                if classifyFailed {
                    Text("Couldn't inspect this app's tools. Try again in a moment.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.Ink.body)
                }
                // The moment-of-connection read (kicked off when the toggle lands ON) — the
                // shared activity object keeps this line honest across dismiss/reopen.
                switch MCPReadActivity.shared.phase(for: connector.slug) {
                case .reading:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        MonoCaps("Reading now · keeps going if you close this", size: 8,
                                 tracking: 1.6, color: .white.opacity(0.5))
                    }
                case .done:
                    MonoCaps("First read done", size: 8, tracking: 1.6,
                             color: Theme.Ink.green.opacity(0.85))
                case .failed:
                    Text("Couldn't read it just now. I'll try again tonight.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.Ink.body)
                case nil:
                    EmptyView()
                }
            }
        }
        .padding(16)
        .frame(width: 270, alignment: .leading)
        .onAppear { kbOn = ConnectorRegistry.isKBEnabled(connector.slug) }
        .animation(.easeInOut(duration: 0.2), value: classifying)
        .animation(.easeInOut(duration: 0.2), value: classifyFailed)
        .animation(.easeInOut(duration: 0.2), value: MCPReadActivity.shared.phase(for: connector.slug))
    }

    private var kbBinding: Binding<Bool> {
        Binding(get: { kbOn }, set: { setKB($0) })
    }

    private func setKB(_ on: Bool) {
        classifyFailed = false
        guard on else {
            kbOn = false
            ConnectorRegistry.setKBEnabled(connector.slug, false)
            return
        }
        guard ConnectorRegistry.kbRequiresClassification(connector) else {
            kbOn = true
            ConnectorRegistry.setKBEnabled(connector.slug, true)
            MCPReadActivity.shared.beginInitialIfNeeded(slug: connector.slug)
            return
        }
        classifying = true
        Task {
            let ok = await ConnectorClassifier.ensureClassified(slug: connector.slug)
            classifying = false
            if ok {
                kbOn = true
                ConnectorRegistry.setKBEnabled(connector.slug, true)
                MCPReadActivity.shared.beginInitialIfNeeded(slug: connector.slug)
            } else {
                kbOn = false
                classifyFailed = true
            }
        }
    }
}

#Preview("Knowledge Sources pane") {
    SourcesPane()
        .background(Theme.bg)
        .frame(width: 720, height: 640)
}

#if DEBUG
private extension ConnectorCensus.DetectedConnector {
    /// Preview fixture. DEBUG-only, so every preview using it sits inside #if DEBUG too
    /// (the release-preview trap in the dev rules).
    static func mock(_ slug: String, origin: Origin = .claude, healthy: Bool = true) -> Self {
        .init(slug: slug,
              displayName: ConnectorCensus.titleCased(slug),
              origin: origin,
              serverURL: origin == .claude ? "https://example.googleapis.com/mcp/v1" : nil,
              catalogID: origin == .chatgpt ? "connector_0123456789abcdef0123456789abcdef" : nil,
              iconPath: nil,
              healthy: healthy,
              lastSeen: Date())
    }
}

#Preview("Connectors · three healthy") {
    ConnectorsSection(connectors: [.mock("google-drive"), .mock("notion"), .mock("slack")],
                      locked: false, watching: false, refreshing: false, engineWord: "Claude",
                      onConnect: {}, onRefresh: {})
        .padding(38).frame(width: 640).background(Theme.bg)
}

#Preview("Connectors · empty") {
    ConnectorsSection(connectors: [], locked: false, watching: false, refreshing: false,
                      engineWord: "Claude", onConnect: {}, onRefresh: {})
        .padding(38).frame(width: 640).background(Theme.bg)
}

#Preview("Connectors · one unhealthy, watching") {
    ConnectorsSection(connectors: [.mock("google-drive"), .mock("notion", healthy: false)],
                      locked: false, watching: true, refreshing: false, engineWord: "Claude",
                      onConnect: {}, onRefresh: {})
        .padding(38).frame(width: 640).background(Theme.bg)
}

#Preview("Connectors · locked") {
    ConnectorsSection(connectors: [.mock("finances", origin: .chatgpt),
                                   .mock("google-drive", origin: .chatgpt)],
                      locked: true, watching: false, refreshing: false, engineWord: "ChatGPT",
                      onConnect: {}, onRefresh: {})
        .padding(38).frame(width: 640).background(Theme.bg)
}

#Preview("Connector popover") {
    ConnectorPopover(connector: .mock("google-drive"))
        .background(Theme.bg)
}
#endif
