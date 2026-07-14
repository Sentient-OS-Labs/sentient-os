//
//  OnboardingReadyView.swift
//  Sentient OS macOS
//
//  Onboarding's final step — "ready to process". The source tiles are the SAME Settings-grade
//  groups (SettingsGroup + SettingsChip) the Knowledge Sources pane uses, on the SAME dbg.run.*
//  keys and the SAME picker/connect sheets — so this IS the real selection (it persists and
//  feeds the 3am run too), styled to make connecting sources feel like the main event: we WANT
//  a bunch connected before the first analysis. Desktop, Documents, and Downloads ship armed;
//  at least 4 SELECTIONS must be armed to start (SourceSelection.selectionCount — the same rule
//  Settings enforces; every folder/chat/notes/connector counts as one), so the default three
//  folders alone never light the button. The big Start Analysis button
//  fires the exact run the home's Analyze Now fires, but wears the full-brightness glow (the
//  popover's copy is deliberately subdued).
//

import SwiftUI
import AppKit

struct OnboardingReadyView: View {
    let onStart: () -> Void

    // The live selection — the same keys SourceSelection / the popover / Settings / 3am all share.
    @AppStorage("dbg.run.downloads")      private var runDownloads = true
    @AppStorage("dbg.run.desktop")        private var runDesktop = true
    @AppStorage("dbg.run.documents")      private var runDocuments = true
    @AppStorage("dbg.run.notes")          private var runNotes = false
    @AppStorage("dbg.run.whatsapp")       private var runWhatsApp = false
    @AppStorage("dbg.run.imessage")       private var runIMessage = false
    @AppStorage("dbg.whatsapp.chats")     private var whatsappCSV = ""
    @AppStorage("dbg.imessage.chats")     private var imessageCSV = ""
    @AppStorage("dbg.gmail.connected")    private var gmailConnected = false
    @AppStorage("dbg.run.gmail")          private var runGmail = false
    @AppStorage("dbg.calendar.connected") private var calendarConnected = false
    @AppStorage("dbg.run.calendar")       private var runCalendar = false
    @AppStorage(CustomRoots.key)          private var customRootsRaw = ""

    @State private var showWhatsAppPicker = false
    @State private var showIMessagePicker = false
    @State private var showGmailConnect = false
    @State private var showCalendarConnect = false

    private var customRoots: [URL] { CustomRoots.decode(customRootsRaw) }
    private var whatsappChats: Set<String> { Set(whatsappCSV.split(separator: ",").map(String.init)) }
    private var imessageChats: Set<String> { Set(imessageCSV.split(separator: ",").map(String.init)) }

    /// The shared minimum: at least 4 SELECTIONS (each folder, chat source, Notes, or connector
    /// counts as one) — the three default folders alone deliberately don't light the button.
    /// (A still-downloading model deliberately doesn't gate this: Start Analysis hands off to
    /// the downloading-model screen, which waits honestly.)
    private var selectionCount: Int { SourceSelection.selectionCount }
    private var canStart: Bool { selectionCount >= SourceSelection.minimumSelections }

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            OnboardingWhisper("READY")

            Text("Sentient is ready to understand your life.\nConnect as much as you can; everything stays on this Mac.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            // The Settings-grade source groups (same components as the Knowledge Sources pane) —
            // connecting sources IS this screen's main event, so the tiles get real presence.
            VStack(alignment: .leading, spacing: 26) {
                SettingsGroup(label: "Folders") {
                    ChipFlow {
                        SettingsChip(label: "Desktop", on: runDesktop) { runDesktop.toggle() }
                        SettingsChip(label: "Documents", on: runDocuments) { runDocuments.toggle() }
                        SettingsChip(label: "Downloads", on: runDownloads) { runDownloads.toggle() }
                        ForEach(customRoots, id: \.self) { url in
                            SettingsChip(label: url.lastPathComponent, detail: "✕", on: true) {
                                CustomRoots.remove(url)
                            }
                        }
                        SettingsChip(label: "+ Add Folder", on: false, isAction: true) { addFolder() }
                    }
                }
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
                        SettingsChip(label: "Apple Notes", on: runNotes) { runNotes.toggle() }
                    }
                }
                SettingsGroup(label: "Through Your ChatGPT") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsProse("Read through your own connectors, never our servers.")
                        ChipFlow {
                            SettingsChip(label: "Gmail", on: gmailConnected && runGmail,
                                         locked: CodexAuth.knowledgeBaseOnly) { showGmailConnect = true }
                            SettingsChip(label: "Google Calendar", on: calendarConnected && runCalendar,
                                         locked: CodexAuth.knowledgeBaseOnly) { showCalendarConnect = true }
                        }
                    }
                }
                if selectionCount < SourceSelection.minimumSelections {
                    MonoCaps("keep at least 4 sources on", size: 8.5, tracking: 1.6, color: Theme.Ink.amber)
                }
            }
            .frame(width: 640)

            GlowButton(title: "Start Analysis", active: canStart, action: onStart)
                .frame(maxWidth: 380)

            Spacer()

            OnboardingTrustFooter()
        }
        .padding(40)
        .sheet(isPresented: $showWhatsAppPicker) {
            ChatPicker(sourceName: "WhatsApp", loadChats: { try WhatsAppSource().listChats() },
                       initialSelection: Set(whatsappCSV.split(separator: ",").map(String.init))) { sel in
                whatsappCSV = sel.sorted().joined(separator: ","); runWhatsApp = !sel.isEmpty
            }
        }
        .sheet(isPresented: $showIMessagePicker) {
            ChatPicker(sourceName: "iMessage", loadChats: { try iMessageSource().listChats() },
                       initialSelection: Set(imessageCSV.split(separator: ",").map(String.init))) { sel in
                imessageCSV = sel.sorted().joined(separator: ","); runIMessage = !sel.isEmpty
            }
        }
        .sheet(isPresented: $showGmailConnect) { CloudConnectSheet(.gmail) }
        .sheet(isPresented: $showCalendarConnect) { CloudConnectSheet(.calendar) }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { CustomRoots.add(url) }
    }
}

#Preview("Onboarding — ready to process") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        OnboardingReadyView(onStart: {})
    }
    .frame(width: 1180, height: 880)
    .preferredColorScheme(.dark)
}
