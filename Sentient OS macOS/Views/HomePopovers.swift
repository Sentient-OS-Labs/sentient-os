//
//  HomePopovers.swift
//  Sentient OS macOS
//
//  The two glanceable dropdowns hung off the home's top-bar nav (HomeView). They keep status
//  OFF the home itself — you open them only when curious:
//   · AnalysisPopover — the work glance: things understood, vault size, the synced stamp, an
//     Analyze Now control, and the source chips (sources are the INPUTS to analysis, so they
//     live under "Analysis"). A discreet Dev Tools link sits at the bottom.
//   · YourAIsPopover — the access-log glance ("ChatGPT read 5 notes yesterday") + the glowing
//     "Connect your AIs" CTA that opens the setup window.
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
                .font(.system(size: 21, design: .serif)).foregroundStyle(.white)
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
                    SourceChip("Gmail",    on: gmailConnected && runGmail,       action: onPickGmail)
                    SourceChip("Calendar", on: calendarConnected && runCalendar, action: onPickCalendar)
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
        if modelMissing { return "The on-device model is missing — see Dev Tools" }
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

/// The MCP glance + control. Wires straight to MirrorClient: an on/off toggle (mint pill) that
/// mints the token + pushes the vault (or deletes the cloud copy), live access stats when on, and
/// Copy Link / Copy System Prompt — the two things the user pastes into ChatGPT/Claude. Same
/// MirrorClient the Dev Tools MCP panel drives, so the home and Dev Tools are one system.
struct YourAIsPopover: View {
    @State private var enabled = false
    @State private var url: String?
    @State private var stats: MirrorClient.Stats?
    @State private var busy = false
    @State private var note: String?       // transient feedback (copied / turned on) — overrides the footer
    @State private var flashID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MonoCaps("Connect AIs", size: 10, tracking: 2.4, color: Theme.Ink.label)
                Spacer()
                togglePill
            }

            Text(headline)
                .font(.system(size: 20, design: .serif)).foregroundStyle(.white)
                .padding(.top, 11)
            if let sub = subLineText {
                MonoCaps(sub, size: 10, tracking: 1.0, color: Theme.Ink.body).padding(.top, 7)
            }

            actions.padding(.top, 18)

            MonoCaps(note ?? "Your whole life · offered to every AI", size: 8.5, tracking: 1.6,
                     color: note == nil ? Theme.Ink.deepMuted : Theme.Ink.green)
                .padding(.top, 13)
        }
        .padding(20)
        .frame(width: 300)
        .background(Theme.Ink.cardBG)
        .task { await refresh() }
    }

    // MARK: Pieces

    /// The on/off toggle — a tappable mint pill mirroring the Analysis popover's synced stamp.
    private var togglePill: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                if busy { ProgressView().controlSize(.mini) }
                else { Circle().fill(enabled ? Theme.Ink.green : Theme.Ink.deepMuted).frame(width: 6, height: 6) }
                Text(enabled ? "ON" : "OFF")
            }
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced)).tracking(1.4)
            .foregroundStyle(enabled ? Theme.Ink.green : Theme.Ink.label)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .overlay(Capsule().strokeBorder((enabled ? Theme.Ink.green : Theme.Ink.label).opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var headline: String {
        if !enabled { return "Offer your life to every AI." }
        if let n = stats?.notesRead24h, n > 0 { return "Read \(n) note\(n == 1 ? "" : "s") today." }
        return "Connected. Ready for your AIs."
    }

    /// The mono sub-line — shown only when ON (live access stats). OFF shows nothing; the footer
    /// already carries the "offered to every AI" pitch, so no "private · no account · lease" line.
    private var subLineText: String? {
        guard enabled else { return nil }
        if let s = stats, s.toolCalls24h > 0 || s.lastAccess != nil {
            let last = s.lastAccess.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }
            return "\(s.toolCalls24h) calls" + (last.map { " · \($0)" } ?? "")
        }
        return "No reads yet · paste your link into ChatGPT"
    }

    /// On → Copy Link + Copy System Prompt (the two things to paste). Off → the glow CTA that turns it on.
    @ViewBuilder private var actions: some View {
        if enabled {
            HStack(spacing: 8) {
                CopyPill(title: "Copy Link", systemImage: "link", action: copyLink)
                CopyPill(title: "Copy Prompt", systemImage: "text.quote", action: copyPrompt)
            }
        } else {
            GlowButton(title: "Connect your AIs", systemImage: "link", glowIntensity: 0.28, action: toggle)
        }
    }

    // MARK: Actions (all through MirrorClient — the SAME path Dev Tools uses)

    @MainActor private func refresh() async {
        enabled = await MirrorClient.shared.isEnabled
        url = await MirrorClient.shared.shareURL
        stats = enabled ? (try? await MirrorClient.shared.stats()) : nil
    }

    private func toggle() {
        guard !busy else { return }
        Task { @MainActor in
            busy = true
            if enabled {
                await MirrorClient.shared.disable()
                flash("Mirror off · cloud copy deleted")
            } else {
                do {
                    _ = try await MirrorClient.shared.enable()
                    try await MirrorClient.shared.push()
                    VaultActivity.shared.vaultDirty = false
                    flash("On · your knowledge is live")
                } catch MirrorClient.MirrorError.noVault {
                    flash("On · syncs on your first analysis")
                } catch MirrorClient.MirrorError.tokenGenerationFailed, MirrorClient.MirrorError.keychainWriteFailed {
                    flash("Couldn't turn on — try again")
                } catch {
                    flash("On · sync will retry")
                }
            }
            await refresh()
            busy = false
        }
    }

    private func copyLink() {
        guard let url else { return }
        setPasteboard(url); flash("Link copied · add it as a connector")
    }
    private func copyPrompt() {
        setPasteboard(MirrorClient.systemPrompt); flash("Prompt copied · paste into custom instructions")
    }
    private func setPasteboard(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }

    /// Show a transient feedback line in place of the footer, then revert (unless superseded).
    private func flash(_ s: String) {
        note = s; flashID += 1; let id = flashID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            if flashID == id { note = nil }
        }
    }
}

/// A quiet outlined copy button (the popover's secondary action — glow is reserved for the ON CTA).
private struct CopyPill: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 9))
                Text(title)
            }
            .font(.system(size: 9.5, weight: .medium, design: .monospaced)).tracking(0.5)
            .foregroundStyle(.white.opacity(0.82))
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(Capsule().fill(.white.opacity(hover ? 0.08 : 0.04)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Shared bits

/// A source pill (✓ when armed). Tappable when an `action` is set (toggles a source / opens a
/// chat or connect sheet). Harvested from the Constellation.
struct SourceChip: View {
    let name: String
    let on: Bool
    var action: (() -> Void)? = nil    // tappable when set (toggles a source / opens the chat picker)

    @State private var hover = false

    init(_ name: String, on: Bool, action: (() -> Void)? = nil) {
        self.name = name; self.on = on; self.action = action
    }

    var body: some View {
        let chip = HStack(spacing: 5) {
            if on { Text("✓").foregroundStyle(Theme.Ink.green) }
            Text(name).foregroundStyle(on ? Theme.Ink.chipInk : .white.opacity(0.28))
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.8)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(hover && action != nil ? 0.06 : 0)))
        .overlay(Capsule().strokeBorder(Theme.Ink.chipBorder, lineWidth: 1))
        .contentShape(Capsule())

        if let action {
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
