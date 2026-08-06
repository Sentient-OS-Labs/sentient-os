//
//  SourcesPane.swift
//  Sentient OS macOS
//
//  Settings → Knowledge Sources: the real source picker, on the SAME keys as the Analysis
//  popover / Dev Tools / the 3am run (SourceSelection + CustomRoots). Folder chips toggle,
//  custom roots add/remove (persistent), WhatsApp & iMessage open the shared ChatPicker,
//  Gmail & Calendar open their connect sheets. Enforces the four-selection minimum on direct
//  toggles, and surfaces a fix-it line when Full Disk Access is missing.
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

    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    @State private var showWhatsAppPicker = false
    @State private var showIMessagePicker = false
    @State private var showGmailConnect = false
    @State private var showCalendarConnect = false
    @State private var showAccessHistory = false
    @State private var flashMinimum = false
    @State private var accessReceipts: [CodexAccessReceipt] = []
    @State private var provenanceState: VaultProvenanceState = .empty
    @State private var gmailLastAccess: Date?
    @State private var calendarLastAccess: Date?

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
            }
        }
        .task {
            fdaGranted = Permissions.hasFullDiskAccess()
            await refreshCloudFacts()
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
        .sheet(isPresented: $showAccessHistory) { CodexAccessHistoryView(receipts: accessReceipts) }
        .onChange(of: gmailConnected) { _, _ in Task { await refreshCloudFacts() } }
        .onChange(of: runGmail) { _, _ in Task { await refreshCloudFacts() } }
        .onChange(of: calendarConnected) { _, _ in Task { await refreshCloudFacts() } }
        .onChange(of: runCalendar) { _, _ in Task { await refreshCloudFacts() } }
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
        SettingsGroup(label: "Connected account sources") {
            VStack(alignment: .leading, spacing: 14) {
                SettingsProse("ChatGPT sign-in authenticates the model. It does not give Sentient blanket access to your account. Gmail and Calendar are enabled independently; web access is limited to proactive research, and computer use requires a user-initiated action.")
                SettingsProse("Not accessed by Sentient: ordinary ChatGPT conversations, saved memories, custom instructions, projects, uploaded files, unrelated account apps, and user-configured MCP servers.")
                cloudStatusRow(source: .gmail, connected: gmailConnected, selected: runGmail,
                               lastAccess: gmailLastAccess,
                               mayContain: provenanceState.mayContain(.gmail)) {
                    showGmailConnect = true
                }
                cloudStatusRow(source: .calendar, connected: calendarConnected, selected: runCalendar,
                               lastAccess: calendarLastAccess,
                               mayContain: provenanceState.mayContain(.calendar)) {
                    showCalendarConnect = true
                }
                Button("View data-access history") { showAccessHistory = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Ink.bright)
            }
        }
    }

    private func cloudStatusRow(source: SourceSelection.CloudSource, connected: Bool, selected: Bool,
                                lastAccess: Date?, mayContain: Bool,
                                action: @escaping () -> Void) -> some View {
        let sentientStatus = SourceSelection.isAuthorized(source) ? "enabled"
            : (selected && connected ? "unavailable on the current model backend" : "not enabled")
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(source.displayName).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(connected ? "Manage" : "Connect", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(CodexAuth.connectorsLocked)
            }
            Text("OpenAI link: \(connected ? "last verified available" : "not verified") · Sentient: \(sentientStatus)")
                .foregroundStyle(Theme.faint)
            Text(lastAccess.map { "Last successful access: \($0.formatted(date: .abbreviated, time: .shortened))" }
                 ?? "Last successful access: none recorded")
                .foregroundStyle(Theme.faint)
            Text(mayContain ? "Current knowledge base may contain this source." : "Current knowledge base does not record this source.")
                .foregroundStyle(mayContain ? Theme.Ink.amber : Theme.faint)
        }
        .font(.system(size: 11))
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.035)))
    }

    private func refreshCloudFacts() async {
        async let receipts = CodexAccessLedger.shared.snapshot()
        async let provenance = VaultProvenanceStore.shared.state()
        async let gmail = CodexAccessLedger.shared.lastSuccessfulAccess(to: .gmail)
        async let calendar = CodexAccessLedger.shared.lastSuccessfulAccess(to: .calendar)
        let values = await (receipts, provenance, gmail, calendar)
        await MainActor.run {
            accessReceipts = values.0
            provenanceState = values.1
            gmailLastAccess = values.2
            calendarLastAccess = values.3
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

private struct CodexAccessHistoryView: View {
    let receipts: [CodexAccessReceipt]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Data-access history").font(.title2.weight(.semibold))
                    Text("Capability and lifecycle only. Prompts, queries, arguments, and results are never stored.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            if receipts.isEmpty {
                ContentUnavailableView("No recorded Codex access", systemImage: "checkmark.shield")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(receipts) { receipt in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(receipt.feature.rawValue).font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Text(receipt.outcome.rawValue).font(.caption)
                                }
                                Text(receipt.timestamp.formatted(date: .abbreviated, time: .standard))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text("Declared: " + (receipt.declaredCapabilities.isEmpty
                                     ? "none" : receipt.declaredCapabilities.map(\.rawValue).joined(separator: ", ")))
                                    .font(.caption)
                                Text("Observed: \(Self.observationSummary(receipt.observations))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Session: \(receipt.session.rawValue) · policy v\(receipt.policyVersion)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.04)))
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 520)
        .background(Theme.bg)
    }

    private static func observationSummary(_ observations: [CodexAccessObservation]) -> String {
        guard !observations.isEmpty else { return "none" }
        return observations.map { observation in
            let capability: String
            switch observation.kind {
            case .web: capability = "web"
            case .hostedApp:
                let app = observation.app == .gmail ? "gmail" : "calendar"
                capability = "\(app).\(observation.tool?.rawValue ?? "unknown")"
            case .unknownMCP: capability = "unknown-mcp"
            case .computerUse: capability = "computer-use (detail unavailable)"
            }
            return "\(capability):\(observation.lifecycle.rawValue)"
        }.joined(separator: ", ")
    }
}

#Preview("Knowledge Sources pane") {
    SourcesPane()
        .background(Theme.bg)
        .frame(width: 720, height: 640)
}
