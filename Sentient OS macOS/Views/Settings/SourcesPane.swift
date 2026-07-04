//
//  SourcesPane.swift
//  Sentient OS macOS
//
//  Settings → Knowledge Sources: the real source picker, on the SAME keys as the Analysis
//  popover / Dev Tools / the 3am run (SourceSelection + CustomRoots). Folder chips toggle,
//  custom roots add/remove (persistent), WhatsApp & iMessage open the shared ChatPicker,
//  Gmail & Calendar open their connect sheets. Enforces the three-connector minimum on direct
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
    @State private var flashMinimum = false

    private var customRoots: [URL] { CustomRoots.decode(customRootsRaw) }
    private var whatsappChats: Set<String> { Set(whatsappCSV.split(separator: ",").map(String.init)) }
    private var imessageChats: Set<String> { Set(imessageCSV.split(separator: ",").map(String.init)) }

    /// How many CONNECTORS are on (all folders together count as one). The three-source minimum
    /// is about breadth of life coverage, not folder count.
    private var connectorCount: Int {
        var n = 0
        if runDownloads || runDesktop || runDocuments || !customRoots.isEmpty { n += 1 }
        if runWhatsApp && !whatsappChats.isEmpty { n += 1 }
        if runIMessage && !imessageChats.isEmpty { n += 1 }
        if runNotes { n += 1 }
        if gmailConnected && runGmail { n += 1 }
        if calendarConnected && runCalendar { n += 1 }
        return n
    }

    var body: some View {
        SettingsPane(title: "Knowledge Sources.",
                     whisper: "What Sentient reads: always locally, always yours.") {
            VStack(alignment: .leading, spacing: 30) {
                if !fdaGranted { fdaLine }
                foldersGroup
                chatsGroup
                cloudGroup
                Text("Sentient needs at least three sources to truly know you.")
                    .font(.serif(11.5, weight: .regular)).italic()
                    .foregroundStyle(flashMinimum ? Theme.Ink.amber : Theme.Ink.deepMuted)
                    .animation(.easeInOut(duration: 0.25), value: flashMinimum)
            }
        }
        .task { fdaGranted = Permissions.hasFullDiskAccess() }
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
        .sheet(isPresented: $showGmailConnect) { GmailConnectSheet() }
        .sheet(isPresented: $showCalendarConnect) { CalendarConnectSheet() }
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
                SettingsChip(label: "Desktop", on: runDesktop) { toggleFolder($runDesktop) }
                SettingsChip(label: "Downloads", on: runDownloads) { toggleFolder($runDownloads) }
                SettingsChip(label: "Documents", on: runDocuments) { toggleFolder($runDocuments) }
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
        SettingsGroup(label: "Through Your ChatGPT") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsProse("Read through your own connectors, never our servers.")
                ChipFlow {
                    SettingsChip(label: "Gmail", on: gmailConnected && runGmail) { showGmailConnect = true }
                    SettingsChip(label: "Google Calendar", on: calendarConnected && runCalendar) { showCalendarConnect = true }
                }
            }
        }
    }

    // MARK: - Toggle guards (the three-connector minimum)

    /// The guard fires only on the 3 → 2 drop: onboarding guarantees users start at three or
    /// more, and a pre-onboarding dev state below three must never get trapped by the rule.
    private var atMinimum: Bool { connectorCount == 3 }

    /// Toggling a folder off is guarded only when it would kill the whole FILES connector
    /// (the last enabled folder) while at the minimum.
    private func toggleFolder(_ flag: Binding<Bool>) {
        if flag.wrappedValue {
            let foldersLeft = [runDesktop, runDownloads, runDocuments].filter(\.self).count - 1
            if foldersLeft == 0 && customRoots.isEmpty && atMinimum { return flash() }
        }
        flag.wrappedValue.toggle()
    }

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
        .frame(width: 720, height: 640)
}
