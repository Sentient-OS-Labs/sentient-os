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
    let sources: HomeSources
    let analyzeEnabled: Bool
    let modelMissing: Bool
    let syncedLabel: String
    let pending: Int
    var onAnalyze: () -> Void

    @State private var vault: (notes: Int, domains: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MonoCaps("Analysis", size: 10, tracking: 2.4, color: Theme.Ink.label)
                Spacer()
                MonoCaps(syncedLabel, size: 8.5, tracking: 1.4, color: Theme.Ink.mint)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(Theme.Ink.mint.opacity(0.3), lineWidth: 1))
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
                    SourceChip("Files", on: sources.files)
                    if sources.whatsappAvailable { SourceChip("WhatsApp", on: sources.whatsapp) }
                    SourceChip("iMessage", on: sources.imessage)
                }
                HStack(spacing: 8) {
                    SourceChip("Notes", on: sources.notes)
                    SourceChip("Gmail", on: false, soon: true)
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
        return analyzeEnabled ? "\(pending) pending · runs when your Mac rests" : "No sources armed"
    }

    private var analyzeButton: some View {
        Button(action: onAnalyze) {
            Text("Analyze Now")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(analyzeEnabled ? .black : .white.opacity(0.35))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule(style: .continuous)
                    .fill(analyzeEnabled ? Color.white : Color.white.opacity(0.08)))
                .overlay(Capsule(style: .continuous)
                    .stroke(analyzeEnabled ? .clear : .white.opacity(0.1), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .background(GlowHalo(active: analyzeEnabled))
        .disabled(!analyzeEnabled)
    }
}

// MARK: - Your AIs

struct YourAIsPopover: View {
    let notesRead: Int
    let logLine: String
    var onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoCaps("Your AIs", size: 10, tracking: 2.4, color: Theme.Ink.label)
            (Text("Read ") + Text("\(notesRead) notes").italic() + Text(" yesterday."))
                .font(.system(size: 20, design: .serif)).foregroundStyle(.white)
                .padding(.top, 11)
            HStack(spacing: 0) {
                Text("CHATGPT · ").foregroundStyle(Theme.Ink.label)
                Text(logLine).foregroundStyle(Theme.Ink.body)
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.top, 7)

            GlowButton(title: "Connect your AIs", systemImage: "link", action: onConnect)
                .padding(.top, 18)

            MonoCaps("Your whole life · offered to every AI", size: 8.5, tracking: 1.6,
                     color: Theme.Ink.deepMuted)
                .padding(.top, 13)
        }
        .padding(20)
        .frame(width: 300)
        .background(Theme.Ink.cardBG)
    }
}

// MARK: - Shared bits

/// A source pill (✓ when armed, dashed + dim when "soon"). Harvested from the Constellation.
struct SourceChip: View {
    let name: String
    let on: Bool
    var soon = false

    init(_ name: String, on: Bool, soon: Bool = false) {
        self.name = name; self.on = on; self.soon = soon
    }

    var body: some View {
        HStack(spacing: 5) {
            if on { Text("✓").foregroundStyle(Theme.Ink.mint) }
            Text(name).foregroundStyle(soon ? Theme.Ink.deepMuted : on ? Theme.Ink.chipInk : .white.opacity(0.28))
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.8)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(Theme.Ink.chipBorder,
                                        style: StrokeStyle(lineWidth: 1, dash: soon ? [3, 3] : [])))
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
                        analyzeEnabled: true, modelMissing: false, syncedLabel: "Synced · 3:41 AM",
                        pending: 214, onAnalyze: {})
    }.frame(width: 380, height: 460).preferredColorScheme(.dark)
}

#Preview("Your AIs") {
    ZStack { Theme.bg
        YourAIsPopover(notesRead: 5, logLine: "Tokyo Trip, Visa…", onConnect: {})
    }.frame(width: 360, height: 300).preferredColorScheme(.dark)
}
