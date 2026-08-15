//
//  VaultCloud.swift
//  Sentient OS macOS
//
//  The iterative system's two knowledge-base cloud calls, through the user's own Codex CLI (CodexCLI):
//   • create    — "go make knowledge base exist": build the vault from scratch. Reuses
//                 VaultGenerator (staging dir + atomic swap + usage-limit resume).
//   • update    — "go update knowledge base": merge the cycle's new notes into the existing vault
//                 with surgical edits on the live vault (eval-validated prompt lifted from the old
//                 VaultUpdater; no store queue — the cycle's notes are wiped wholesale each cycle).
//
//  Proactive intelligence is its OWN module — see Proactive/ (ProactiveCycle owns the sequencing).
//  Connector-agnostic: operates on `CycleStore.notes()` regardless of source (files / notes / chats).
//  Create/update only MARK the vault dirty; MCP sync is a SEPARATE step (the dev "MCP SYNC" button →
//  MirrorClient.push, plus pushIfDirty() as the on-launch catch-up). Re-couple in markDirty() later.
//

import Foundation

/// A Sendable, store-agnostic description of one summary handed to a Codex call. Decouples the
/// cloud prompts from any particular store. Built from a CycleNoteItem (the iterative system).
/// Codable for CorpusSlicer's staging snapshot (multi-slice resume determinism).
struct CloudNote: Sendable, Codable {
    let kind: SourceKind
    let sourceID: String       // "file:<abs path>" / "notes:<uuid>" — VaultGenerator.locSrc keys on it
    let folder: String
    let title: String?
    let text: String
    let itemDate: Date?

    init(kind: SourceKind, sourceID: String, folder: String, title: String?, text: String, itemDate: Date?) {
        self.kind = kind; self.sourceID = sourceID; self.folder = folder
        self.title = title; self.text = text; self.itemDate = itemDate
    }

    /// From an iterative cycle note.
    init(_ n: CycleNoteItem) {
        self.init(kind: n.kind, sourceID: n.sourceID, folder: n.folder,
                  title: n.title, text: n.text, itemDate: n.itemDate)
    }
}

actor VaultCloud {

    static let shared = VaultCloud()

    // DURABLE resume handles for BOTH build and update (B11): each carries a codex session id + the
    // staging dir holding the work-in-progress, persisted to UserDefaults so a usage limit or an app
    // restart RESUMES instead of re-running the expensive codex call from scratch. Both the build and
    // update paths now stage-then-swap (the live vault is never mutated mid-run), so a lost handle is
    // only wasteful, never corrupting.
    private var createResume: VaultGenerator.ResumeToken?
    private var updateResume: VaultGenerator.ResumeToken?
    private static let createResumeKey = "vault.create.resume"
    private static let updateResumeKey = "vault.update.resume"

    init() {
        createResume = Self.loadResume(Self.createResumeKey)
        updateResume = Self.loadResume(Self.updateResumeKey)
    }

    /// Load a persisted resume token, discarding it (and its stale key) if it can't actually resume:
    /// nothing durable to continue (no session to reopen AND no completed slices in staging), or
    /// the staging dir is gone (deleted / disk cleaned).
    private static func loadResume(_ key: String) -> VaultGenerator.ResumeToken? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let t = try? JSONDecoder().decode(VaultGenerator.ResumeToken.self, from: data),
              t.sessionID != nil || (t.sliceIndex ?? 0) > 0,
              FileManager.default.fileExists(atPath: t.stagingPath) else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return t
    }

    private func setCreateResume(_ t: VaultGenerator.ResumeToken?) { createResume = t; Self.persistResume(t, Self.createResumeKey) }
    private func setUpdateResume(_ t: VaultGenerator.ResumeToken?) { updateResume = t; Self.persistResume(t, Self.updateResumeKey) }

    /// Persist (only a resumable token — a session id to reopen, or completed slices whose fold
    /// lives in staging) or clear the handle on disk.
    private static func persistResume(_ t: VaultGenerator.ResumeToken?, _ key: String) {
        if let t, t.sessionID != nil || (t.sliceIndex ?? 0) > 0, let data = try? JSONEncoder().encode(t) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    enum CloudError: LocalizedError {
        case empty
        case noVault
        case usageLimit(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .empty:             return "No summaries yet; run the on-device pass first."
            case .noVault:           return "No knowledge base on disk yet; run \"go make knowledge base exist\" first."
            case .usageLimit(let m): return "Your AI hit its usage limit; try again later to resume. (\(m.prefix(160)))"
            case .failed(let m):     return m
            }
        }
    }

    // MARK: Create — "go make knowledge base exist"

    @discardableResult
    func create(notes: [CloudNote],
                onProgress: @Sendable @escaping (VaultGenerator.Progress) -> Void = { _ in },
                onLine: (@Sendable (String) -> Void)? = nil) async throws -> VaultGenerator.Result {
        guard !notes.isEmpty else { throw CloudError.empty }
        do {
            let result = try await VaultGenerator().generate(notes: notes, resume: createResume, onProgress: onProgress, onLine: onLine)
            setCreateResume(nil)
            await markDirty()
            return result
        } catch let VaultGenerator.VaultError.usageLimit(message, resume) {
            setCreateResume(resume)   // DURABLE now (B11) — a restart resumes the build over its staging dir
            throw CloudError.usageLimit(message)
        }
    }

    // MARK: Update — "go update knowledge base"

    /// Merge the current cycle's notes into the existing vault. Returns the number of notes sent.
    ///
    /// STAGE-THEN-SWAP (B11): codex edits a COPY of the vault in a staging dir; the LIVE vault is
    /// never touched until an atomic swap on success. A usage limit / crash / non-fatal failure can't
    /// corrupt the real vault — worst case the staging copy is discarded (or kept for a durable
    /// resume). This replaced the old in-place edit + `.bak` restore (B1), which is now obsolete.
    @discardableResult
    func update(notes: [CloudNote],
                onProgress: @Sendable @escaping (VaultGenerator.Progress) -> Void = { _ in },
                onLine: (@Sendable (String) -> Void)? = nil) async throws -> Int {
        guard !notes.isEmpty else { return 0 }
        let fm = FileManager.default
        let vault = VaultGenerator.vaultRoot
        guard fm.fileExists(atPath: vault.path) else { throw CloudError.noVault }

        // Edit-sync seam: don't start a merge while the user is actively editing in the Knowledge
        // editor — skip and let the notes ride to the next cycle (they stay in CycleStore). Saves an
        // expensive codex call that the freshness check below would just abort anyway.
        if await MainActor.run(body: { VaultActivity.shared.editorBusy }) {
            Log("VaultCloud.update: editor busy — skipping this cycle (notes retried next run)")
            return 0
        }

        // Reuse the resume's staging dir (loadResume already verified it's usable), else seed a
        // fresh staging dir with a COPY of the live vault so codex has the notes to edit.
        // `baseline` is the live vault's fingerprint at seed time — the freshness check compares
        // against it at swap; carried in the resume token so it survives a usage-limit resume.
        // The cycle's notes are sliced under codex's 1 MiB turn-input cap (a vacation backlog
        // crosses it) — each slice is one sequential merge run over the SAME staging; the
        // freshness check + atomic swap happen ONCE, after the last slice.
        let staging: URL
        let baseline: String
        let slices: [[CloudNote]]
        var next: Int                                   // the next unfed slice
        let inFlight: String?                           // a session to resume first
        if let token = updateResume {
            staging = URL(fileURLWithPath: token.stagingPath, isDirectory: true)
            baseline = token.vaultFingerprint ?? VaultGenerator.vaultFingerprint(vault)
            inFlight = token.sessionID
            if let idx = token.sliceIndex {
                guard let corpus = CorpusSlicer.loadCorpus(from: staging) else {
                    // Snapshot gone — the fold can't be continued safely; restart the merge fresh.
                    Log("VaultCloud.update: ⚠️ resume snapshot missing — restarting the merge fresh")
                    setUpdateResume(nil)
                    try? fm.removeItem(at: staging)
                    return try await update(notes: notes, onProgress: onProgress, onLine: onLine)
                }
                slices = CorpusSlicer.slice(corpus)
                next = min(idx, slices.count)
            } else {
                slices = []                             // pre-slicing / single-slice token: session-resume only
                next = 0
            }
        } else {
            staging = try VaultGenerator.newStagingDir(seedFrom: vault)
            baseline = VaultGenerator.vaultFingerprint(vault)       // captured at seed (vault == staging)
            slices = CorpusSlicer.slice(notes)
            next = 0
            if slices.count > 1 {
                try CorpusSlicer.saveCorpus(notes, in: staging)
                Log("VaultCloud.update: cycle sliced into \(slices.count) parts (budget \(CorpusSlicer.budget) bytes)")
            }
            inFlight = nil
        }

        /// The shared per-run configuration every merge invocation gets.
        func configure(_ prompt: String) -> CodexCLI.Invocation {
            var i = CodexCLI.Invocation(prompt: prompt)
            i.feature = "vault"
            i.effort = .high                                    // incremental KB update (gpt-5.6-sol → high)
            i.sandbox = .workspaceWrite                        // edits confined to the staging dir
            i.cwd = staging.path
            i.timeout = 1_800
            return i
        }

        Log("VaultCloud.update: merging \(notes.count) notes in staging (\(updateResume == nil ? "fresh" : "resume"))…")
        do {
            // Finish the in-flight slice's session first (or, for a pre-slicing token, the whole run).
            if let sid = inFlight {
                var invocation = configure("""
                    Continue merging the new items into the vault exactly where you left off — the edits \
                    you already made are still in the working directory. When everything is merged, reply \
                    with one line: the number of notes you created or edited.
                    """)
                invocation.resumeSessionID = sid
                invocation.diag = ["slices": "\(max(slices.count, 1))", "slice_index": "\(max(next - 1, 0))"]
                do {
                    _ = try await VaultGenerator().runCodexInStaging(invocation, staging: staging, onLine: onLine)
                } catch let VaultGenerator.VaultError.usageLimit(message, token) {
                    var t = token; t.sliceIndex = updateResume?.sliceIndex   // unchanged — still the same slice
                    throw VaultGenerator.VaultError.usageLimit(message: message, resume: t)
                }
            }

            // Feed the remaining slices, one fresh merge session each, over the same staging.
            while next < slices.count {
                try Task.checkCancellation()                     // the user's STOP, between slices
                if slices.count > 1 { onProgress(.folding(part: next + 1, of: slices.count)) }
                var invocation = configure(Self.updatePrompt(skeleton: Self.skeleton(of: staging), notes: slices[next]))
                invocation.diag = ["corpus_chars": "\(invocation.prompt.utf8.count)",
                                   "slices": "\(slices.count)", "slice_index": "\(next)"]
                if slices.count > 1 {
                    Log("VaultCloud.update: feeding slice \(next + 1)/\(slices.count) — \(slices[next].count) summaries")
                }
                do {
                    _ = try await VaultGenerator().runCodexInStaging(invocation, staging: staging, onLine: onLine)
                } catch let VaultGenerator.VaultError.usageLimit(message, token) {
                    guard slices.count > 1 else { throw VaultGenerator.VaultError.usageLimit(message: message, resume: token) }
                    // A session that never started can't be resumed — its slice stays the next unfed.
                    var t = token; t.sliceIndex = (token.sessionID != nil) ? next + 1 : next
                    throw VaultGenerator.VaultError.usageLimit(message: message, resume: t)
                }
                next += 1
            }

            // Freshness check (B11): did the live vault change under us — i.e. did the user save a note
            // in the Knowledge editor during the run? If so, our staging snapshot is stale and swapping
            // would CLOBBER their edit. Discard staging instead; the notes stay in CycleStore and the
            // next cycle re-seeds from the now-current vault (their edit included).
            guard VaultGenerator.vaultFingerprint(vault) == baseline else {
                Log("VaultCloud.update: ⚠️ vault changed during the run (editor?) — swap aborted, re-run next cycle")
                // Working as designed (the freshness check doing its job) — a counter for
                // TelemetryDeck, not a Sentry issue (2026-07-12).
                Analytics.signal("KnowledgeBase.staleSwapAverted")
                setUpdateResume(nil)
                try? fm.removeItem(at: staging)
                return 0
            }
            CorpusSlicer.deleteCorpus(in: staging)              // the snapshot must never enter the vault
            try VaultGenerator.swapStagingIntoVault(staging)    // atomic; live vault untouched until here
            setUpdateResume(nil)
            await markDirty()
            Log("VaultCloud.update: ✅ \(notes.count) notes merged")
            return notes.count
        } catch let VaultGenerator.VaultError.usageLimit(message, resume) {
            // Staging is kept; the live vault was never touched. Carry the seed baseline forward so a
            // resume's swap still detects a concurrent editor edit. Durable resume continues next run.
            var t = resume; t.vaultFingerprint = baseline
            setUpdateResume(t)
            throw CloudError.usageLimit(message)
        } catch {
            // Any other failure: discard the staging copy; the live vault was NEVER modified — no
            // restore dance needed (the whole point of stage-then-swap). Rethrow the TYPED error —
            // wrapping it in a string used to blind OvernightCaution.classify to the actual kind.
            setUpdateResume(nil)
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // MARK: Mirror push

    /// Flag the vault as changed (so a later sync knows there's something to push) WITHOUT pushing.
    /// MCP sync is currently a SEPARATE manual step — the dev "MCP SYNC" button calls
    /// `MirrorClient.push()`, and `pushIfDirty()` runs on app launch as the catch-up. To restore
    /// auto-push-after-KB-update, just call `await Self.pushIfDirty()` here.
    private func markDirty() async {
        await MainActor.run { VaultActivity.shared.vaultDirty = true }
    }

    /// Push the vault to the mirror IFF the mirror is enabled AND there's an unsynced change
    /// (`VaultActivity.vaultDirty`). Clears the dirty flag only on a successful push; a failure
    /// leaves it set so the next trigger retries. Called after every create/update AND once on app
    /// launch (`SentientOSApp`) — that launch call is the durable catch-up for a push that failed
    /// or never ran (e.g. the app quit between a KB update and its push). No-op when the mirror is
    /// off or the vault is already in sync, so it's safe to call anytime.
    static func pushIfDirty() async {
        guard await MirrorClient.shared.isEnabled else { return }
        guard await MainActor.run(body: { VaultActivity.shared.vaultDirty }) else { return }
        do {
            try await MirrorClient.shared.push()
            await MainActor.run { VaultActivity.shared.vaultDirty = false }
            Log("VaultCloud: mirror pushed ✓")
        } catch {
            // §7.18: this swallows + retries forever, leaving the mirror stale (the user's AIs read
            // old data). Emit the HTTP status only — never the response body (MirrorError.http's 2nd
            // arg embeds it). Status 0 = no HTTP response (B4); "n/a" = a non-HTTP error (zip/network).
            var status = "n/a"
            if case MirrorClient.MirrorError.http(let code, _) = error { status = String(code) }
            CrashReporting.captureEvent("mirror.push_failed", level: .warning,
                tags: ["error": String(describing: type(of: error))],
                extra: ["http_status": status],
                fingerprint: ["mirror", "push_failed"])
            Log("VaultCloud: mirror push failed — \(ErrorLabel(error)) (retries next trigger)")
        }
    }

    // MARK: Prompts

    /// The vault's current shape — a recursive ls of .md paths (the tree IS the index).
    static func skeleton(of root: URL) -> String {
        (((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") && !$0.contains("/.") }
            .sorted()).joined(separator: "\n")
    }

    /// The editing-flavored Stage-2 prompt — lifted verbatim from the old VaultUpdater
    /// (eval-validated), fed CloudNotes. Surgical edits, not a rebuild. Internal (not private):
    /// a sliced first build reuses it verbatim for slices 1+ — folding a batch into the staged
    /// vault is the same job as folding a night into the live one.
    static func updatePrompt(skeleton: String, notes: [CloudNote]) -> String {
        let df = CorpusSlicer.dateFormatter()
        let lines = notes.enumerated().map { i, n in CorpusSlicer.render(n, index: i, df: df) }

        return """
        You are the **Sentient OS Knowledge Base Architect** — the cloud brain of a privacy-first \
        personal-intelligence product. You previously organized this user's digital life into the \
        Obsidian-style markdown vault that is your current working directory. While their Mac sat \
        idle, an on-device LLM privately summarized the user's NEW items — you are receiving today's \
        survivors (junk and sensitive items were already discarded on-device). Your job: merge them \
        into the existing vault, surgically.

        ## The vault's current skeleton (a recursive ls — the tree IS the index)
        \(skeleton)

        ## How to work — surgical edits, not a rebuild
        - **You are the second sieve — not every item deserves the vault.** The on-device model \
        already dropped obvious junk, but it is a small, lenient model; YOU are the quality bar, \
        exactly as when you built this vault (curate ruthlessly). Change the vault ONLY where an \
        item genuinely makes the knowledge base more VALUABLE. If an item adds nothing durable — \
        trivia, noise, redundancy an existing note already covers — SKIP it: change nothing for that \
        item. A run where nothing is worth merging is a perfectly good run; reply "0".
        - **Explore only the notes you need.** Search the tree to find where each new item belongs; \
        do not re-read the whole vault.
        - **Consolidate, hard — as much as possible, fold new items into EXISTING notes.** For \
        roughly 90% of worthwhile items the right move is editing the info into a relevant EXISTING \
        note; creating a NEW note (or, very rarely, a new folder) is right in maybe ~5% of cases — \
        only when something TRULY deserves its own file and belongs nowhere that already exists. \
        NEVER default to spawning a new note for a small piece of new info — a sprawl of tiny new \
        notes is exactly what we're avoiding: after six months of nightly merges this vault must \
        still be tight and navigable, not a mess of files. When you DO create one, follow the \
        existing folder structure and naming style (`Domain/Specific — Topic.md`, no frontmatter — \
        open with the `# Title` H1).
        - **Preserve the vault's tight shape.** A healthy vault stays compact: at most ~10 root \
        folders, a few subfolders per domain, a handful (~2–5) of substantial notes per subfolder. \
        If a merge would push a folder past that shape, fold the info into an existing note instead \
        of adding a file — the vault should grow in KNOWLEDGE, not in file count.
        - **Never delete notes wholesale**, never reorganize folders, never rename existing notes \
        (links point at them). Keep every `[[wikilink]]` intact; add new ones where a new item \
        genuinely connects.
        - **Synthesize, don't append-dump.** Work an item into the narrative of its note — update \
        facts, extend timelines, collapse redundancy.
        - **Never use em dashes (—) in the note text you write.** Use a semicolon, colon, comma, or \
        period instead.
        - If today's items genuinely change who the user is or what they're up to, update the root \
        `README.md` portrait — otherwise leave it untouched.

        ## ⚠️ TRUTH & ATTRIBUTION — the most important rule (unchanged from your first build)
        Other AIs will state these facts back to people as truth; a confident false claim is worse \
        than an omission. The `[source]` tag tells you how much to trust each item: the user's own \
        authored notes (Obsidian / user-authored / Apple Notes) are genuinely theirs; screenshots \
        and saved files are often about OTHER people, products, or topics — never absorb someone \
        else's biography, job, or project into the user. When ambiguous, omit or phrase literally \
        ("saved a screenshot of X") rather than "is/did X". Never include raw private specifics \
        (card/account numbers, passwords, exact medical or financial figures).

        ## Today's new items (each: `#index · [source] location · item date`, then `Title — summary`)

        \(lines.joined(separator: "\n\n"))

        Merge them in now. When you are done, reply with ONE line: the number of notes you created \
        or edited.
        """
    }

}
