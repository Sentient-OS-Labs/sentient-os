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
//  Proactive intelligence is its OWN module — see Proactive.swift (Arch §6: own module + trigger).
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

    // In-memory resume handle for create (an app restart just starts fresh — correct, since the
    // cycle's notes stay in CycleStore until the proactive button wipes them).
    private var createResume: VaultGenerator.ResumeToken?

    // Update's resume handle is DURABLE (UserDefaults, B1): the update path edits the LIVE vault, so
    // a crash/quit mid-merge must be resumable across a restart — otherwise a half-merged vault is
    // silently abandoned. Loaded on init; routed through setMidEdit() so memory + disk never diverge.
    private var updateResumeSessionID: String?
    private static let midEditKey = "vault.update.midEditSessionID"

    init() {
        updateResumeSessionID = UserDefaults.standard.string(forKey: Self.midEditKey)
    }

    /// Set (or clear) the durable mid-edit resume handle, keeping memory and UserDefaults in sync.
    private func setMidEdit(_ sessionID: String?) {
        updateResumeSessionID = sessionID
        if let sessionID { UserDefaults.standard.set(sessionID, forKey: Self.midEditKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.midEditKey) }
    }

    /// The vault's same-volume backup sibling (`…/Sentient OS - Knowledge Base.bak`). Same volume →
    /// FileManager copy/move are reliable (no cross-volume failures). Built explicitly rather than
    /// via `appendingPathExtension` (which misbehaves on a trailing-slash directory URL).
    private static func backupURL(for vault: URL) -> URL {
        vault.deletingLastPathComponent()
            .appendingPathComponent(vault.lastPathComponent + ".bak", isDirectory: true)
    }

    enum CloudError: LocalizedError {
        case empty
        case noVault
        case usageLimit(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .empty:             return "No summaries yet — run the on-device pass first."
            case .noVault:           return "No knowledge base on disk yet — run \"go make knowledge base exist\" first."
            case .usageLimit(let m): return "Your AI hit its usage limit — try again later to resume. (\(m.prefix(160)))"
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
            createResume = nil
            await markDirty()
            return result
        } catch let VaultGenerator.VaultError.usageLimit(message, resume) {
            createResume = resume
            throw CloudError.usageLimit(message)
        }
    }

    // MARK: Update — "go update knowledge base"

    /// Merge the current cycle's notes into the existing vault. Returns the number of notes sent.
    @discardableResult
    func update(notes: [CloudNote]) async throws -> Int {
        guard !notes.isEmpty else { return 0 }
        let fm = FileManager.default
        let vault = VaultGenerator.vaultRoot
        let backup = Self.backupURL(for: vault)

        // Crash-restore recovery (B1): if a prior run died between removing the vault and copying
        // the backup back in, the vault is missing but the durable .bak survives — restore it before
        // anything else, so a partial restore is never permanent.
        if !fm.fileExists(atPath: vault.path), fm.fileExists(atPath: backup.path) {
            Log("VaultCloud.update: vault missing but backup present — restoring from .bak")
            try? fm.copyItem(at: backup, to: vault)
        }
        guard fm.fileExists(atPath: vault.path) else { throw CloudError.noVault }

        // Safety net (B1): a DURABLE pre-edit backup as a same-volume sibling (.bak). Unlike the old
        // temp snapshot, it is NEVER auto-deleted (no `defer`) — it must outlive a failed restore so
        // we can never end up with neither a vault nor a backup. Reuse an existing .bak (left by a
        // usage-limit pause or a crash) — it already holds the clean pre-edit state; overwriting it
        // with a half-edited vault would throw the good copy away.
        if !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: vault, to: backup)
        }

        var invocation: CodexCLI.Invocation
        if let updateResumeSessionID {
            var inv = CodexCLI.Invocation(prompt: """
                Continue merging the new items into the vault exactly where you left off — the edits \
                you already made are still on disk. When everything is merged, reply with one line: \
                the number of notes you created or edited.
                """)
            inv.resumeSessionID = updateResumeSessionID
            invocation = inv
        } else {
            invocation = CodexCLI.Invocation(prompt: Self.updatePrompt(skeleton: Self.skeleton(of: vault), notes: notes))
        }
        invocation.feature = "vault"
        invocation.effort = .high                                     // incremental KB update (gpt-5.5 → high)
        invocation.sandbox = .workspaceWrite                         // edits confined to the vault
        invocation.cwd = vault.path
        invocation.timeout = 1_800

        Log("VaultCloud.update: merging \(notes.count) notes into the vault…")
        do {
            let envelope = try await CodexCLI.shared.run(invocation)
            setMidEdit(nil)
            try? fm.removeItem(at: backup)                           // verified success → drop the backup
            await markDirty()
            Log("VaultCloud.update: ✅ \(notes.count) notes (turns \(envelope.numTurns ?? -1)) — \(envelope.result.prefix(120))")
            return notes.count
        } catch let CodexCLI.CLIError.usageLimit(message, sessionID) {
            // Resume later; the vault is left half-edited on disk (a resume continues it) and the
            // .bak is KEPT as the recovery point until the resume commits. The session id is now
            // durable, so a restart before the resume doesn't silently abandon the merge.
            setMidEdit(sessionID)
            throw CloudError.usageLimit(message)
        } catch {
            setMidEdit(nil)
            // Mid-edit failure → restore the pre-edit vault from the durable backup. removeItem then
            // COPY (never move) and delete .bak ONLY after the copy verifiably succeeds — so a failed
            // restore always leaves .bak intact and recoverable, never the B1 total loss.
            do {
                try fm.removeItem(at: vault)
                try fm.copyItem(at: backup, to: vault)
                try? fm.removeItem(at: backup)
                Log("VaultCloud.update: restored vault from backup after error")
            } catch let restoreError {
                // .bak is still on disk; the top-of-method recovery will restore it next run.
                Log("VaultCloud.update: ⚠️ restore FAILED — backup preserved (.bak), recoverable next run: \(restoreError)")
                CrashReporting.capture(restoreError)                 // TODO(P2): structured `vault_restore_failed`
            }
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
        - **Rewrite only what changed.** Prefer editing an existing note over creating a new one; \
        create a new note ONLY when no existing note fits, following the existing folder structure \
        and naming style (`Domain/Specific — Topic.md`, no frontmatter — open with the `# Title` H1).
        - **Never delete notes wholesale**, never reorganize folders, never rename existing notes \
        (links point at them). Keep every `[[wikilink]]` intact; add new ones where a new item \
        genuinely connects.
        - **Synthesize, don't append-dump.** Work an item into the narrative of its note — update \
        facts, extend timelines, collapse redundancy.
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
