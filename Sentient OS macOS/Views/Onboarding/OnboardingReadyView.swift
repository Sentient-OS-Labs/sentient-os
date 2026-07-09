//
//  OnboardingReadyView.swift
//  Sentient OS macOS
//
//  Onboarding's final step — "ready to process". The source chips write the SAME dbg.run.* keys
//  and open the SAME picker/connect sheets the Analysis popover uses, so this IS the real
//  selection (it persists and feeds the 3am run too). Desktop, Documents, and Downloads ship
//  armed; at least 3 FOLDERS must stay armed (apps are extra on top). The big Start Analysis
//  button fires the exact run the home's Analyze Now fires, but wears the full-brightness glow
//  (the popover's copy is deliberately subdued).
//

import SwiftUI
import AppKit

struct OnboardingReadyView: View {
    let modelMissing: Bool
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

    /// The min-3 rule counts FOLDERS only (defaults + custom); apps are extra on top.
    private var folderCount: Int {
        [runDownloads, runDesktop, runDocuments].count(where: { $0 }) + customRoots.count
    }
    private var canStart: Bool { folderCount >= 3 && !modelMissing }

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            OnboardingWhisper("READY")

            Text("Sentient is ready to understand your life.\nPick what it can read. Everything stays on this Mac.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            VStack(alignment: .leading, spacing: 10) {
                MonoCaps("Sources", size: 9, tracking: 2.2, color: Theme.Ink.label)
                HStack(spacing: 8) {
                    SourceChip("Desktop",   on: runDesktop)   { runDesktop.toggle() }
                    SourceChip("Documents", on: runDocuments) { runDocuments.toggle() }
                    SourceChip("Downloads", on: runDownloads) { runDownloads.toggle() }
                    ForEach(customRoots, id: \.self) { url in
                        SourceChip(url.lastPathComponent, on: true) { CustomRoots.remove(url) }
                    }
                    SourceChip("+ Add Folder", on: false, action: addFolder)
                }
                HStack(spacing: 8) {
                    if WhatsAppSource.isInstalled {
                        SourceChip("WhatsApp", on: runWhatsApp && !whatsappCSV.isEmpty) { showWhatsAppPicker = true }
                    }
                    SourceChip("iMessage", on: runIMessage && !imessageCSV.isEmpty) { showIMessagePicker = true }
                    SourceChip("Notes",    on: runNotes) { runNotes.toggle() }
                    SourceChip("Gmail",    on: gmailConnected && runGmail,
                               locked: CodexAuth.knowledgeBaseOnly) { showGmailConnect = true }
                    SourceChip("Calendar", on: calendarConnected && runCalendar,
                               locked: CodexAuth.knowledgeBaseOnly) { showCalendarConnect = true }
                }
                if folderCount < 3 {
                    MonoCaps("keep at least 3 folders on", size: 8.5, tracking: 1.6, color: Theme.Ink.amber)
                        .padding(.top, 2)
                }
            }

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
        .sheet(isPresented: $showGmailConnect) { GmailConnectSheet() }
        .sheet(isPresented: $showCalendarConnect) { CalendarConnectSheet() }
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
        OnboardingReadyView(modelMissing: false, onStart: {})
    }
    .frame(width: 1180, height: 880)
    .preferredColorScheme(.dark)
}
