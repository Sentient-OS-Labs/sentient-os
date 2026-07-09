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
struct CloudNote: Sendable {
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
    /// no session id to reopen, or the staging dir is gone (deleted / disk cleaned).
    private static func loadResume(_ key: String) -> VaultGenerator.ResumeToken? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let t = try? JSONDecoder().decode(VaultGenerator.ResumeToken.self, from: data),
              t.sessionID != nil, FileManager.default.fileExists(atPath: t.stagingPath) else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return t
    }

    private func setCreateResume(_ t: VaultGenerator.ResumeToken?) { createResume = t; Self.persistResume(t, Self.createResumeKey) }
    private func setUpdateResume(_ t: VaultGenerator.ResumeToken?) { updateResume = t; Self.persistResume(t, Self.updateResumeKey) }

    /// Persist (only a resumable token — one with a session id) or clear the handle on disk.
    private static func persistResume(_ t: VaultGenerator.ResumeToken?, _ key: String) {
        if let t, t.sessionID != nil, let data = try? JSONEncoder().encode(t) {
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
                onProgress: @Sendable @escaping (VaultGenerator.Progress) -> Void = { _ in }) async throws -> VaultGenerator.Result {
        guard !notes.isEmpty else { throw CloudError.empty }
        do {
            let result = try await VaultGenerator().generate(notes: notes, resume: createResume, onProgress: onProgress)
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
    func update(notes: [CloudNote]) async throws -> Int {
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

        // Reuse the resume's staging dir (loadResume already verified it exists + has a session), else
        // seed a fresh staging dir with a COPY of the live vault so codex has the notes to edit.
        // `baseline` is the live vault's fingerprint at seed time — the freshness check compares
        // against it at swap; carried in the resume token so it survives a usage-limit resume.
        let staging: URL
        let baseline: String
        let inv: CodexCLI.Invocation
        if let token = updateResume {
            staging = URL(fileURLWithPath: token.stagingPath, isDirectory: true)
            baseline = token.vaultFingerprint ?? VaultGenerator.vaultFingerprint(vault)
            var i = CodexCLI.Invocation(prompt: """
                Continue merging the new items into the vault exactly where you left off — the edits \
                you already made are still in the working directory. When everything is merged, reply \
                with one line: the number of notes you created or edited.
                """)
            i.resumeSessionID = token.sessionID
            inv = i
        } else {
            staging = try VaultGenerator.newStagingDir(seedFrom: vault)
            baseline = VaultGenerator.vaultFingerprint(vault)       // captured at seed (vault == staging)
            inv = CodexCLI.Invocation(prompt: Self.updatePrompt(skeleton: Self.skeleton(of: staging), notes: notes))
        }
        var invocation = inv
        invocation.feature = "vault"
        invocation.effort = .high                                    // incremental KB update (gpt-5.6-sol → high)
        invocation.sandbox = .workspaceWrite                        // edits confined to the staging dir
        invocation.cwd = staging.path
        invocation.timeout = 1_800

        Log("VaultCloud.update: merging \(notes.count) notes in staging (\(updateResume == nil ? "fresh" : "resume"))…")
        do {
            let envelope = try await VaultGenerator().runCodexInStaging(invocation, staging: staging)
            // Freshness check (B11): did the live vault change under us — i.e. did the user save a note
            // in the Knowledge editor during the run? If so, our staging snapshot is stale and swapping
            // would CLOBBER their edit. Discard staging instead; the notes stay in CycleStore and the
            // next cycle re-seeds from the now-current vault (their edit included).
            guard VaultGenerator.vaultFingerprint(vault) == baseline else {
                Log("VaultCloud.update: ⚠️ vault changed during the run (editor?) — swap aborted, re-run next cycle")
                CrashReporting.captureEvent("vault.update.stale_swap_averted", level: .info,
                    fingerprint: ["vault", "update", "stale_swap_averted"])
                setUpdateResume(nil)
                try? fm.removeItem(at: staging)
                return 0
            }
            try VaultGenerator.swapStagingIntoVault(staging)        // atomic; live vault untouched until here
            setUpdateResume(nil)
            await markDirty()
            Log("VaultCloud.update: ✅ \(notes.count) notes (turns \(envelope.numTurns ?? -1)) — \(envelope.result.prefix(120))")
            return notes.count
        } catch let VaultGenerator.VaultError.usageLimit(message, resume) {
            // Staging is kept; the live vault was never touched. Carry the seed baseline forward so a
            // resume's swap still detects a concurrent editor edit. Durable resume continues next run.
            setUpdateResume(VaultGenerator.ResumeToken(sessionID: resume.sessionID,
                                                       stagingPath: resume.stagingPath,
                                                       vaultFingerprint: baseline))
            throw CloudError.usageLimit(message)
        } catch {
            // Any other failure: discard the staging copy; the live vault was NEVER modified — no
            // restore dance needed (the whole point of stage-then-swap).
            setUpdateResume(nil)
            try? fm.removeItem(at: staging)
            throw CloudError.failed("\(error)")
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
            Log("VaultCloud: mirror push failed — \((error as? LocalizedError)?.errorDescription ?? "\(error)") (retries next trigger)")
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
    /// (eval-validated), fed CloudNotes. Surgical edits, not a rebuild.
    private static func updatePrompt(skeleton: String, notes: [CloudNote]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(notes.count)
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        for (i, n) in notes.enumerated() {
            let (loc, src) = VaultGenerator.locSrc(kind: n.kind, folder: n.folder, sourceID: n.sourceID)
            let title = (n.title?.isEmpty == false) ? n.title! : "(untitled)"
            let when = n.itemDate.map { " · \(df.string(from: $0))" } ?? ""
            lines.append("#\(i + 1) · [\(src)] \(loc)\(when)\n\(title) — \(n.text)")
        }

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
        exactly as when you built this vault (curate ruthlessly). If an item adds nothing durable — \
        trivia, noise, redundancy an existing note already covers — SKIP it: change nothing for that \
        item. A run where nothing is worth merging is a perfectly good run; reply "0".
        - **Explore only the notes you need.** Search the tree to find where each new item belongs; \
        do not re-read the whole vault.
        - **Consolidate, hard — as much as possible, fold new items into EXISTING notes.** Editing \
        an existing note is almost always better than spawning a new one; a sprawl of tiny new notes \
        is exactly what we're avoiding. You CAN create a new note (or, rarely, a new folder) when an \
        item genuinely belongs nowhere that already exists — but treat that as the exception, not the \
        reflex. When you do, follow the existing folder structure and naming style \
        (`Domain/Specific — Topic.md`, no frontmatter — open with the `# Title` H1).
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
