//
//  HomePopovers.swift
//  Sentient OS macOS
//
//  The two glanceable dropdowns hung off the home's top-bar nav (HomeView). They keep status
//  OFF the home itself — you open them only when curious:
//   · AnalysisPopover — the work glance: things understood, vault size, the synced stamp, an
//     Analyze Now control, and the source chips (sources are the INPUTS to analysis, so they
//     live under "Analysis").
//   · YourAIsPopover — the pitch + the glowing "Connect your AIs" CTA that opens the guided
//     setup window (ConnectAIsView owns sharing on/off, the link, and the prompt).
//  Pure presentation; harvested from the retired Constellation home. Demo strings (synced
//  stamp, access log) stand in until the real polls land; the vault counts ARE real (disk).
//

import SwiftUI
import AppKit

/// Which sources are armed to run — drives the Analysis popover's chips.
struct HomeSources {
    var files = true
    var whatsapp = false
    var imessage = false
    var notes = false
    var whatsappAvailable = true   // false → WhatsApp isn't installed on this Mac; hide its chip entirely
}

// MARK: - Analysis

struct AnalysisPopover: View {
    let thingsUnderstood: Int
    let sources: HomeSources               // for whatsappAvailable (hide the chip when WhatsApp isn't installed)
    let modelMissing: Bool
    let syncedLabel: String
    let pending: Int
    var onAnalyze: () -> Void
    var onPickWhatsApp: () -> Void = {}    // tapping WhatsApp / iMessage opens the chat picker (in HomeView)
    var onPickIMessage: () -> Void = {}
    var onPickGmail: () -> Void = {}       // tapping Gmail / Calendar opens the connect sheet (in HomeView)
    var onPickCalendar: () -> Void = {}
    var customRoots: [URL] = []            // session folders added in Dev Tools — shown so this mirrors the picker exactly

    // Live source selection — the SAME keys SourceSelection / DevTools use. @AppStorage so a tap toggles
    // the real selection AND the chip updates instantly. FDA is still enforced at run time (Analyze Now).
    @AppStorage("dbg.run.downloads")      private var runDownloads = true
    @AppStorage("dbg.run.desktop")        private var runDesktop = true
    @AppStorage("dbg.run.documents")      private var runDocuments = true
    @AppStorage("dbg.run.notes")          private var runNotes = false
    @AppStorage("dbg.whatsapp.chats")     private var whatsappCSV = ""
    @AppStorage("dbg.imessage.chats")     private var imessageCSV = ""
    @AppStorage("dbg.gmail.connected")    private var gmailConnected = false
    @AppStorage("dbg.run.gmail")          private var runGmail = false
    @AppStorage("dbg.calendar.connected") private var calendarConnected = false
    @AppStorage("dbg.run.calendar")       private var runCalendar = false

    @State private var vault: (notes: Int, domains: Int)?

    private var anyArmed: Bool {
        runDownloads || runDesktop || runDocuments || runNotes || !customRoots.isEmpty
            || !whatsappCSV.isEmpty || !imessageCSV.isEmpty
            || (gmailConnected && runGmail) || (calendarConnected && runCalendar)
    }
    private var armed: Bool { anyArmed && !modelMissing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MonoCaps("Analysis", size: 10, tracking: 2.4, color: Theme.Ink.label)
                Spacer()
                MonoCaps(syncedLabel, size: 8.5, tracking: 1.4, color: Theme.Ink.green)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(Theme.Ink.green.opacity(0.3), lineWidth: 1))
            }

            Text(understoodLine)
                .display(21).foregroundStyle(.white)
                .padding(.top, 13)
            MonoCaps(vaultLine, size: 9, tracking: 1.6, color: Theme.Ink.deepMuted)
                .padding(.top, 7)

            analyzeButton.padding(.top, 16)
            MonoCaps(runHint, size: 9, tracking: 1.6, color: Theme.Ink.deepMuted)
                .padding(.top, 11)

            Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.vertical, 16)

            MonoCaps("Sources", size: 9, tracking: 2.2, color: Theme.Ink.label)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SourceChip("Downloads", on: runDownloads) { runDownloads.toggle() }
                    SourceChip("Desktop",   on: runDesktop)   { runDesktop.toggle() }
                    SourceChip("Documents", on: runDocuments) { runDocuments.toggle() }
                }
                // Session folders added in Dev Tools — shown (✓) so the popover mirrors the picker
                // exactly; add/remove still lives in Dev Tools (the owner of the session roots).
                ForEach(Array(stride(from: 0, to: customRoots.count, by: 2)), id: \.self) { i in
                    HStack(spacing: 8) {
                        ForEach(customRoots[i..<min(i + 2, customRoots.count)], id: \.self) { url in
                            SourceChip(url.lastPathComponent, on: true)
                        }
                    }
                }
                HStack(spacing: 8) {
                    if sources.whatsappAvailable { SourceChip("WhatsApp", on: !whatsappCSV.isEmpty, action: onPickWhatsApp) }
                    SourceChip("iMessage", on: !imessageCSV.isEmpty, action: onPickIMessage)
                }
                HStack(spacing: 8) {
                    SourceChip("Notes",    on: runNotes) { runNotes.toggle() }
                    SourceChip("Gmail",    on: gmailConnected && runGmail,
                               locked: CodexAuth.knowledgeBaseOnly, action: onPickGmail)
                    SourceChip("Calendar", on: calendarConnected && runCalendar,
                               locked: CodexAuth.knowledgeBaseOnly, action: onPickCalendar)
                }
            }
            .padding(.top, 11)
        }
        .padding(20)
        .frame(width: 328)
        .background(Theme.Ink.cardBG)
        .task { vault = HomeStats.countVault() }
    }

    private var understoodLine: String {
        switch thingsUnderstood {
        case 0:  "Ready to begin."
        case 1:  "1 thing understood."
        default: "\(thingsUnderstood.formatted()) things understood."
        }
    }
    private var vaultLine: String {
        guard let v = vault, v.notes > 0 else { return "No vault yet · your first analysis builds it" }
        return "\(v.notes) notes · \(v.domains) domains in your knowledge"
    }
    private var runHint: String {
        if modelMissing { return "The on-device model is missing; see Dev Tools" }
        return armed ? "\(pending) pending · runs when your Mac rests" : "No sources armed"
    }

    private var analyzeButton: some View {
        Button(action: onAnalyze) {
            Text("Analyze Now")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(armed ? .black : .white.opacity(0.35))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule(style: .continuous)
                    .fill(armed ? Color.white : Color.white.opacity(0.08)))
                .overlay(Capsule(style: .continuous)
                    .stroke(armed ? .clear : .white.opacity(0.1), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .background(GlowHalo(active: armed, intensity: 0.28))
        .disabled(!armed)
    }
}

// MARK: - Your AIs

/// The MCP door. One job: the glowing "Connect your AIs" CTA, always shown, opening the guided
/// setup window — ConnectAIsView owns sharing on/off, the private link, and the system prompt,
/// so the popover carries no state and no controls of its own.
struct YourAIsPopover: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoCaps("Connect AIs", size: 10, tracking: 2.4, color: Theme.Ink.label)

            Text("Offer your knowledge to every AI.")
                .display(20).foregroundStyle(.white)
                .padding(.top, 11)

            GlowButton(title: "Connect your AIs", systemImage: "link", glowIntensity: 0.28) {
                openWindow(id: ConnectAIsView.windowID)
            }
            .padding(.top, 18)

            MonoCaps("Your whole knowledge · offered to every AI", size: 8.5, tracking: 1.6,
                     color: Theme.Ink.deepMuted)
                .padding(.top, 13)
        }
        .padding(20)
        .frame(width: 300)
        .background(Theme.Ink.cardBG)
    }
}

// MARK: - Shared bits

/// A source pill (✓ when armed). Tappable when an `action` is set (toggles a source / opens a
/// chat or connect sheet). `locked` (knowledge-base-only mode's Gmail/Calendar) renders a dim
/// lock chip that ignores its action and explains itself on hover. Harvested from the Constellation.
struct SourceChip: View {
    let name: String
    let on: Bool
    var locked: Bool = false
    var action: (() -> Void)? = nil    // tappable when set (toggles a source / opens the chat picker)

    @State private var hover = false

    init(_ name: String, on: Bool, locked: Bool = false, action: (() -> Void)? = nil) {
        self.name = name; self.on = on; self.locked = locked; self.action = action
    }

    var body: some View {
        let chip = HStack(spacing: 5) {
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.white.opacity(0.28))
            } else if on {
                Text("✓").foregroundStyle(Theme.Ink.green)
            }
            Text(name).foregroundStyle(on && !locked ? Theme.Ink.chipInk : .white.opacity(0.28))
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.8)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(hover && action != nil && !locked ? 0.06 : 0)))
        .overlay(Capsule().strokeBorder(Theme.Ink.chipBorder, lineWidth: 1))
        .contentShape(Capsule())

        if locked {
            chip
                .onHover { hover = $0 }
                .overlay(alignment: .top) {
                    if hover { LockedChipTip().offset(y: -26) }
                }
                .animation(.easeInOut(duration: 0.15), value: hover)
        } else if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
        } else {
            chip
        }
    }
}

enum HomeStats {
    /// Counts the real vault on disk (notes = .md files, domains = top-level folders).
    static func countVault() -> (notes: Int, domains: Int)? {
        let fm = FileManager.default
        let root = VaultGenerator.vaultRoot
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        var notes = 0
        for case let url as URL in walker where url.pathExtension == "md" { notes += 1 }
        let domains = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter {
                !$0.lastPathComponent.hasPrefix(".")
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.count) ?? 0
        return (notes, domains)
    }
}

#Preview("Analysis") {
    ZStack { Theme.bg
        AnalysisPopover(thingsUnderstood: 3339, sources: .init(files: true, whatsapp: true, imessage: true, notes: true),
                        modelMissing: false, syncedLabel: "Synced · 3:41 AM",
                        pending: 214, onAnalyze: {})
    }.frame(width: 380, height: 460).preferredColorScheme(.dark)
}

#Preview("Your AIs") {
    ZStack { Theme.bg
        YourAIsPopover()
    }.frame(width: 360, height: 300).preferredColorScheme(.dark)
}
