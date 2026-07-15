//
//  HomePopovers.swift
//  Sentient OS macOS
//
//  The two glanceable dropdowns hung off the home's top-bar nav (HomeView). They keep status
//  OFF the home itself — you open them only when curious:
//   · AnalysisPopover — the work glance: things understood, vault size, an Analyze Now control
//     with the last/next-run footer, and the source chips (sources are the INPUTS to analysis,
//     so they live under "Analysis").
//   · ShareKnowledgePopover — the pitch + the glowing CTA ("Set up in 2 minutes"; "Configure"
//     once sharing is on) that opens the guided setup window (ConnectAIsView owns sharing
//     on/off, the link, and the prompt).
//  Pure presentation; harvested from the retired Constellation home. The vault counts ARE real
//  (disk); the demo deck substitutes its showcase last-run stamp.
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
    let lastRun: String                    // last full cycle, pre-formatted by HomeView (deck-aware)
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
            MonoCaps("Analysis", size: 10, tracking: 2.4, color: Theme.Ink.label)

            Text(understoodLine)
                .display(21).foregroundStyle(.white)
                .padding(.top, 13)
            MonoCaps(vaultLine, size: 9, tracking: 1.6, color: Theme.Ink.deepMuted)
                .padding(.top, 7)

            analyzeButton.padding(.top, 16)
            runFooter.padding(.top, 11)

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
        .frame(width: 360)
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
    /// Under the button: last run + when the next one comes, or the reason nothing can run.
    @ViewBuilder private var runFooter: some View {
        if modelMissing {
            MonoCaps("The on-device model is missing; see Dev Tools", size: 9, tracking: 1.6, color: Theme.Ink.deepMuted)
        } else if !armed {
            MonoCaps("No sources armed", size: 9, tracking: 1.6, color: Theme.Ink.deepMuted)
        } else {
            // Labels whisper, values speak: tiny mono-caps labels, sentence-case sans values.
            // The Grid gives wrapped value lines a hanging indent under the value column for free.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    MonoCaps("Last run", size: 9, tracking: 1.6, color: Theme.Ink.deepMuted)
                    footerValue(String(lastRun.prefix(1)).uppercased() + lastRun.dropFirst())
                }
                GridRow {
                    MonoCaps("Next run", size: 9, tracking: 1.6, color: Theme.Ink.deepMuted)
                    footerValue("Tonight at \(Self.overnightTime), if your Mac's plugged in & Sentient's open in the menu bar")
                }
            }
        }
    }

    /// The footer's value voice — quiet plain sans next to the mono-caps labels. The infinity
    /// frame makes the Grid's value column claim the full width right of the labels.
    private func footerValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.body)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The scheduler's configured time-of-day ("3 AM"; "3:15 AM" off the hour) — live, so a dev
    /// override of the overnight time shows the truth.
    private static var overnightTime: String {
        let minutes = OvernightScheduler.configuredMinutes
        var comps = DateComponents(); comps.hour = minutes / 60; comps.minute = minutes % 60
        let f = DateFormatter(); f.dateFormat = minutes % 60 == 0 ? "h a" : "h:mm a"
        return f.string(from: Calendar.current.date(from: comps) ?? Date())
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

// MARK: - Give AIs Knowledge

/// The MCP door. One job: the glowing CTA ("Set up in 2 minutes"; "Configure" once sharing is
/// on), always shown, opening the guided setup window — ConnectAIsView owns sharing on/off, the
/// private link, and the system prompt, so the popover carries no controls of its own.
struct ShareKnowledgePopover: View {
    @Environment(\.openWindow) private var openWindow

    @State private var enabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoCaps("Give AIs Knowledge", size: 10, tracking: 2.4, color: Theme.Ink.label)

            Text("Offer your knowledge base to your ChatGPT or Claude.")
                .display(20).foregroundStyle(.white)
                .padding(.top, 11)

            GlowButton(title: enabled ? "Configure" : "Set up in 2 minutes",
                       systemImage: "link", glowIntensity: 0.28) {
                openWindow(id: ConnectAIsView.windowID)
            }
            .padding(.top, 18)

            MonoCaps("Private · over MCP · two simple steps", size: 8.5, tracking: 1.6,
                     color: Theme.Ink.deepMuted)
                .padding(.top, 13)
        }
        .padding(20)
        .frame(width: 300)
        .background(Theme.Ink.cardBG)
        .task { enabled = await MirrorClient.shared.isEnabled }
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
                        modelMissing: false, lastRun: "3:41 AM", onAnalyze: {})
    }.frame(width: 380, height: 460).preferredColorScheme(.dark)
}

#Preview("Give AIs Knowledge") {
    ZStack { Theme.bg
        ShareKnowledgePopover()
    }.frame(width: 360, height: 300).preferredColorScheme(.dark)
}
