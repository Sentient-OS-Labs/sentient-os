//
//  VaultView.swift
//  Sentient OS macOS
//
//  The Stage-2 home-screen surface: the "Create Knowledge Vault" glow CTA, a simple working
//  state while Opus 4.8 organizes your life in the cloud (the *fancy* processing UX comes later),
//  and a done state that reveals the vault in Finder. Drives VaultGenerator (Arch §8).
//
//  Vault is written to ~/Sentient OS -- The Vault/.
//

import SwiftUI
import AppKit

/// MainActor-isolated (→ Sendable) model so the generator's progress callback can update UI safely.
@MainActor
@Observable
final class VaultModel {
    enum Phase: Equatable { case idle, gathering, calling, receiving, writing, materializing, done, failed }

    var phase: Phase = .idle
    var summaryCount = 0
    var chars = 0                                          // direct route: streamed chars
    var notes = 0                                          // agentic route: .md files written so far
    var result: VaultGenerator.Result?
    var errorMsg: String?
    /// Set when an agentic run hit a usage limit — "Try again" resumes that session
    /// (its staging dir, with every note already written, is kept). Cleared on success.
    var resumeToken: VaultGenerator.ResumeToken?

    func loadCount(_ store: Store) async {
        summaryCount = await store.counts().sources   // distinct sources = the corpus size
    }

    func run(_ store: Store) async {
        errorMsg = nil; chars = 0; notes = 0; phase = .gathering
        let summaries = await store.survivorSummaries()
        guard !summaries.isEmpty else { phase = .idle; return }
        phase = .calling
        do {
            let res = try await VaultGenerator().generate(summaries: summaries, resume: resumeToken) { [weak self] p in
                Task { @MainActor in
                    guard let self else { return }
                    switch p {
                    case .calling:          self.phase = .calling
                    case .receiving(let c): self.chars = c; self.phase = .receiving
                    case .writing(let n):   self.notes = n; self.phase = .writing
                    case .materializing:    self.phase = .materializing
                    case .gathering:        break
                    }
                }
            }
            result = res
            resumeToken = nil
            // Stamp exactly what this full generation represented (corpus rows + the versions
            // they supersede) — anything newer stays queued for the iterative updater.
            await store.markCorpusSynced(summaries)
            phase = .done
        } catch let VaultGenerator.VaultError.usageLimit(message, resume) {
            resumeToken = resume
            errorMsg = "Claude hit its usage limit — \"Try again\" later will resume right where it left off. (\(message.prefix(160)))"
            phase = .failed
        } catch {
            // Keep any resume token: a failed resume attempt can still be retried.
            errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed
        }
    }
}

struct VaultView: View {
    let store: Store
    @State private var model = VaultModel()

    var body: some View {
        VStack(spacing: 12) {
            switch model.phase {
            case .idle:   idle
            case .done:   done
            case .failed: failed
            default:      working
            }
        }
        .frame(maxWidth: 360)
        .animation(.easeInOut(duration: 0.3), value: model.phase)
        .task { await model.loadCount(store) }
    }

    // MARK: States

    private var idle: some View {
        VStack(spacing: 10) {
            GlowButton(title: "Create Knowledge Base",
                       systemImage: "point.3.connected.trianglepath.dotted",
                       active: model.summaryCount > 0,
                       reversed: true,
                       colors: Theme.magicGlow) { Task { await model.run(store) } }
                .frame(maxWidth: 300)
            Text(model.summaryCount > 0
                 ? "Weave your \(model.summaryCount) summaries into the beautiful knowledge base of your life."
                 : "Analyze some sources first, then build your knowledge base.")
                .font(.caption).foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var working: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(Theme.accent)
            Text(primaryLine).font(.callout.weight(.medium)).foregroundStyle(.white)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("This takes a few minutes.")
                .font(.caption2).foregroundStyle(Theme.faint)
            if model.phase == .receiving {
                Text("\(model.chars.formatted()) characters woven…")
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.secondary)
            }
            if model.phase == .writing && model.notes > 0 {
                Text("\(model.notes) notes written…")
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(18).frame(maxWidth: 340).glassCard()
    }

    private var done: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 30))
                .foregroundStyle(Theme.verdictColor(.survivor))
            Text("Your knowledge base is ready").font(.serif(19)).italic().foregroundStyle(.white)
            if let r = model.result {
                Text("\(r.notes) notes across \(r.folders) folders")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 10) {
                Button { NSWorkspace.shared.open(VaultGenerator.vaultRoot) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Regenerate") { Task { await model.run(store) } }
                    .buttonStyle(.bordered).tint(.white)
            }
        }
        .padding(18).frame(maxWidth: 340).glassCard()
    }

    private var failed: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 26)).foregroundStyle(.orange)
            Text("Knowledge base generation failed").font(.callout.weight(.semibold)).foregroundStyle(.white)
            if let e = model.errorMsg {
                Text(e).font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).lineLimit(4).textSelection(.enabled)
            }
            Button("Try again") { Task { await model.run(store) } }
                .buttonStyle(.bordered).tint(Theme.accent)
        }
        .padding(18).frame(maxWidth: 340).glassCard()
    }

    private var primaryLine: String {
        switch model.phase {
        case .gathering:           return "Gathering your summaries…"
        case .calling, .receiving: return "Claude is thinking deeply across your whole life."
        case .writing:             return "Claude is writing your knowledge base, note by note."
        case .materializing:       return "Writing your notes to disk…"
        default:                   return "Working…"
        }
    }
}
