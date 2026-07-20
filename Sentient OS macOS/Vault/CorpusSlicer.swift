//
//  CorpusSlicer.swift
//  Sentient OS macOS
//
//  Slices a summary corpus into byte-budgeted parts so no single codex prompt can exceed the
//  server-side 1 MiB turn-input cap (large first runs cross it). Deterministic and dumb on
//  purpose: entries are walked in order and a slice closes when the next entry's rendered cost
//  would cross the budget — identical input always re-derives identical slices, which is what
//  makes mid-sequence resume bookkeeping safe. Also owns the staging-dir corpus snapshot that
//  guarantees that determinism across app restarts (CycleStore returns notes newest-first, so a
//  fresh fetch after more ingestion would shift every boundary).
//
//  Key methods:
//   - slice(_:budget:)  → [[CloudNote]] (never splits an entry)
//   - render(_:index:df:) → the EXACT corpus entry text (shared with the vault prompts, so
//     measurement and rendering can never drift)
//   - saveCorpus / loadCorpus / deleteCorpus → the .sentient-corpus.json staging snapshot
//
//  Doc: Documentation/Vault Generation (Stage 2).md
//

import Foundation

enum CorpusSlicer {

    /// UTF-8 bytes of rendered corpus per slice. Headroom math: the vault prompt core + output
    /// instructions + a merge skeleton stay well under the 1,048,576-char server cap with ~33%
    /// margin (the server counts "characters" — measured within ~0.4% of UTF-8 bytes on this
    /// corpus shape; the margin also absorbs Unicode counting ambiguity). Shared with Proactive's
    /// window trim. Don't shave it.
    static let defaultBudget = 700_000

    /// The live budget — `SENTIENT_SLICE_BUDGET` overrides in DEBUG so self-tests can force
    /// multi-slice runs from a tiny corpus (Release ignores the env, like SENTIENT_VAULT_ROOT).
    static var budget: Int {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SENTIENT_SLICE_BUDGET"],
           let n = Int(raw), n > 0 { return n }
        #endif
        return defaultBudget
    }

    /// One corpus entry, exactly as the build/update prompts render it. When measuring, `index`
    /// is the entry's position in the FULL corpus; per-prompt numbering restarts at 1 and is never
    /// longer, so measured cost ≥ rendered cost — budget-safe either way.
    static func render(_ n: CloudNote, index: Int, df: DateFormatter) -> String {
        let (loc, src) = VaultGenerator.locSrc(kind: n.kind, folder: n.folder, sourceID: n.sourceID)
        let title = (n.title?.isEmpty == false) ? n.title! : "(untitled)"
        let when = n.itemDate.map { " · \(df.string(from: $0))" } ?? ""
        return "#\(index + 1) · [\(src)] \(loc)\(when)\n\(title) — \(n.text)"
    }

    /// The prompts' shared date style — one formatter per batch (DateFormatter init is expensive).
    static func dateFormatter() -> DateFormatter {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        return df
    }

    /// Walk entries in order, closing a slice when the next entry would cross the budget. Never
    /// splits an entry; an oversized single entry gets its own slice (loudly). No ranking, no
    /// sampling — a resume must re-derive identical slices from identical notes.
    static func slice(_ notes: [CloudNote], budget: Int = budget) -> [[CloudNote]] {
        guard !notes.isEmpty else { return [] }
        let df = dateFormatter()
        var slices: [[CloudNote]] = []
        var current: [CloudNote] = []
        var bytes = 0
        for (i, n) in notes.enumerated() {
            let cost = render(n, index: i, df: df).utf8.count + 2      // + the "\n\n" joiner
            if cost > budget {
                Log("CorpusSlicer: ⚠️ one entry (\(cost) bytes) exceeds the \(budget)-byte budget — it gets its own slice")
            }
            if !current.isEmpty, bytes + cost > budget {
                slices.append(current); current = []; bytes = 0
            }
            current.append(n); bytes += cost
        }
        slices.append(current)
        return slices
    }

    // MARK: - The staging snapshot (resume determinism)

    private static let snapshotName = ".sentient-corpus.json"

    /// Persist the sliced corpus inside the staging dir, so a resume after a usage limit or an app
    /// restart re-slices the EXACT same entries in the same order. Written only for multi-slice
    /// runs; deleted before the staging → vault swap (it must never ride into the knowledge base
    /// or the mirror), and the orphan-staging sweep takes it along for free. Notes that arrive
    /// between attempts stay unfed, exactly as with a session-only resume.
    static func saveCorpus(_ notes: [CloudNote], in staging: URL) throws {
        let data = try JSONEncoder().encode(notes)
        try data.write(to: staging.appendingPathComponent(snapshotName), options: .atomic)
    }

    static func loadCorpus(from staging: URL) -> [CloudNote]? {
        guard let data = try? Data(contentsOf: staging.appendingPathComponent(snapshotName)) else { return nil }
        return try? JSONDecoder().decode([CloudNote].self, from: data)
    }

    /// Remove the snapshot — call before swapping staging into the live vault.
    static func deleteCorpus(in staging: URL) {
        try? FileManager.default.removeItem(at: staging.appendingPathComponent(snapshotName))
    }
}
