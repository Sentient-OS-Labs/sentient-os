//
//  VaultUpdater.swift
//  Sentient OS macOS
//
//  The iterative vault updater (Part II §B) — the day's-end cloud job that folds NEW survivor
//  summaries into the EXISTING vault. One `claude -p` call (Sonnet — daily updates are cheap;
//  Opus stays reserved for initial generation): the vault's skeleton tree + the unsynced
//  summaries go in over stdin, the agent explores only the notes it needs (Read/Glob/Grep)
//  and rewrites only what changed (Edit/Write), working directly on the LIVE vault — no
//  staging dir, because the inputs are tiny and edits are surgical. A cp -R snapshot is the
//  safety net: a thrown error mid-edit restores it (a usage limit does NOT — the half-edited
//  state is exactly what --resume continues from).
//
//  On success, EXACTLY the consumed rows are stamped (`Store.markSynced(ids:)`) — summaries
//  are versioned, so stamping by sourceID would be wrong. On usage limit nothing is stamped;
//  unstamped rows simply re-enter the queue (the pointer philosophy: self-healing, no failure
//  bookkeeping).
//
//  Doc: Documentation/Days-End Job (Living System).md
//

import Foundation

actor VaultUpdater {

    static let shared = VaultUpdater()

    enum UpdaterError: LocalizedError {
        case noVault
        case usageLimit(message: String, sessionID: String?)
        case cloudFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVault:
                return "No vault on disk yet — run the initial generation first."
            case .usageLimit(let m, _):
                return "Claude hit its usage limit — the next run resumes where it left off. (\(m.prefix(160)))"
            case .cloudFailed(let m):
                return "Vault update failed: \(m)"
            }
        }
    }

    /// A prior run's usage-limit session — the next trigger resumes it over the half-edited
    /// vault instead of starting over. In-memory only (an app restart just starts fresh; the
    /// unstamped queue makes that correct either way).
    private var resumeSessionID: String?

    /// Fold all unsynced summaries into the vault. Returns the number folded (0 = no-op, no
    /// cloud call). Throws `.usageLimit` (resumable) or `.cloudFailed` (vault restored).
    func runDailyUpdate(store: Store) async throws -> Int {
        let queue = await store.unsyncedSummaries()
        guard !queue.isEmpty else {
            Log("VaultUpdater: nothing unsynced — no-op.")
            return 0
        }
        let fm = FileManager.default
        let vault = VaultGenerator.vaultRoot
        guard fm.fileExists(atPath: vault.path) else { throw UpdaterError.noVault }

        // Safety net: snapshot the vault (it's KBs). Restored on a thrown error mid-edit;
        // deliberately NOT restored on a usage limit (resume continues the half-edited state).
        let snapshot = fm.temporaryDirectory
            .appendingPathComponent("vault-snapshot-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: snapshot)
        try fm.copyItem(at: vault, to: snapshot)
        defer { try? fm.removeItem(at: snapshot) }

        var invocation: ClaudeCLI.Invocation
        if let resumeSessionID {
            var inv = ClaudeCLI.Invocation(prompt: """
                Continue folding the new items into the vault exactly where you left off — the \
                edits you already made are still on disk. When everything is folded, reply with \
                one line: the number of notes you created or edited.
                """)
            inv.resumeSessionID = resumeSessionID
            invocation = inv
        } else {
            invocation = ClaudeCLI.Invocation(
                prompt: Self.updatePrompt(skeleton: Self.skeleton(of: vault), items: queue))
        }
        invocation.model = .sonnet                                   // daily updates are Sonnet [DECIDED]
        invocation.allowedTools = ["Read", "Glob", "Grep", "Write", "Edit"]
        invocation.cwd = vault.path
        invocation.timeout = 1_800                                   // a daily delta is minutes, not hours

        Log("VaultUpdater: reviewing \(queue.count) summaries against the vault…")
        do {
            let envelope = try await ClaudeCLI.shared.run(invocation)
            resumeSessionID = nil
            await store.markSynced(queue.map(\.persistentID))        // EXACTLY the rows we sent
            await MainActor.run { VaultActivity.shared.vaultDirty = true }
            Log("VaultUpdater: ✅ reviewed \(queue.count) (turns \(envelope.numTurns ?? -1), \(envelope.durationMS ?? -1)ms) — \(envelope.result.prefix(120))")
            return queue.count
        } catch let ClaudeCLI.CLIError.usageLimit(message, sessionID) {
            resumeSessionID = sessionID                              // stamp nothing; resume later
            throw UpdaterError.usageLimit(message: message, sessionID: sessionID)
        } catch {
            // Mid-edit failure → restore the pre-job vault; the unstamped queue self-heals.
            resumeSessionID = nil
            try? fm.removeItem(at: vault)
            try? fm.moveItem(at: snapshot, to: vault)
            throw UpdaterError.cloudFailed("\(error)")
        }
    }

    // MARK: Prompt

    /// The vault's current shape — a recursive ls of .md paths. The tree IS the index; the
    /// agent Reads only what it needs from here.
    static func skeleton(of root: URL) -> String {
        let paths = ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") && !$0.contains("/.") }
            .sorted()
        return paths.joined(separator: "\n")
    }

    /// The editing-flavored port of the Stage-2 core: same truth/attribution wisdom and
    /// source-trust tiers, scoped to a surgical update instead of a full build.
    private static func updatePrompt(skeleton: String, items: [SummaryItem]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(items.count)
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        for (i, s) in items.enumerated() {
            let (loc, src) = VaultGenerator.locSrc(s)
            let title = (s.title?.isEmpty == false) ? s.title! : "(untitled)"
            let when = s.itemDate.map { " · \(df.string(from: $0))" } ?? ""
            lines.append("#\(i + 1) · [\(src)] \(loc)\(when)\n\(title) — \(s.text)")
        }

        return """
        You are the **Sentient OS Knowledge Base Architect** — the cloud brain of a privacy-first \
        personal-intelligence product. You previously organized this user's digital life into the \
        Obsidian-style markdown vault that is your current working directory. While their Mac sat \
        idle, an on-device LLM privately summarized the user's NEW files, messages, and notes — \
        you are receiving today's survivors (junk and sensitive items were already discarded \
        on-device). Your job: fold them into the existing vault, surgically.

        ## The vault's current skeleton (a recursive ls — the tree IS the index)
        \(skeleton)

        ## How to work — surgical edits, not a rebuild
        - **You are the second sieve — not every item deserves the vault.** The on-device \
        model already dropped obvious junk, but it is a small, lenient model; YOU are the \
        quality bar, exactly as when you built this vault (curate ruthlessly). If an item adds \
        nothing durable — trivia, noise, redundancy an existing note already covers — SKIP it: \
        change nothing for that item. A run where nothing is worth folding is a perfectly good \
        run; reply "0".
        - **Explore only the notes you need.** Use Glob/Grep/Read to find where each new item \
        belongs; do not re-read the whole vault.
        - **Rewrite only what changed.** Prefer editing an existing note (Edit) over creating a \
        new one; create a new note ONLY when no existing note fits, following the existing \
        folder structure and naming style (`Domain/Specific — Topic.md`, frontmatter included).
        - **Never delete notes wholesale**, never reorganize folders, never rename existing \
        notes (links point at them). Keep every `[[wikilink]]` intact; add new ones where a new \
        item genuinely connects.
        - **Synthesize, don't append-dump.** Fold an item into the narrative of its note — \
        update facts, extend timelines, collapse redundancy. Multiple versions of the same item \
        (titles marked “— Edit”) show its evolution: the NEWEST version is the current truth.
        - If today's items genuinely change who the user is or what they're up to, update the \
        root `README.md` portrait — otherwise leave it untouched.

        ## ⚠️ TRUTH & ATTRIBUTION — the most important rule (unchanged from your first build)
        Other AIs will state these facts back to people as truth; a confident false claim is \
        worse than an omission. The `[source]` tag tells you how much to trust each item: the \
        user's own authored notes (Obsidian / user-authored / Apple Notes) are genuinely theirs; \
        screenshots and saved files are often about OTHER people, products, or topics — never \
        absorb someone else's biography, job, or project into the user. Chat summaries already \
        attribute facts per person — preserve that attribution. When ambiguous, omit or phrase \
        literally ("saved a screenshot of X") rather than "is/did X". Never include raw private \
        specifics (card/account numbers, passwords, exact medical or financial figures).

        ## Today's new items (each: `#index · [source] location · item date`, then `Title — summary`)

        \(lines.joined(separator: "\n\n"))

        Fold them in now. When you are done, reply with ONE line: the number of notes you \
        created or edited.
        """
    }
}
