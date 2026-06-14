//
//  VaultCloud.swift
//  Sentient OS macOS
//
//  The iterative system's three cloud calls, all through the user's own Codex CLI (CodexCLI):
//   • create    — "go make knowledge base exist": build the vault from scratch. Reuses
//                 VaultGenerator (staging dir + atomic swap + usage-limit resume).
//   • update    — "go update knowledge base": fold the cycle's new notes into the existing vault
//                 with surgical edits on the live vault (eval-validated prompt lifted from the old
//                 VaultUpdater; no store queue — the cycle's notes are wiped wholesale each cycle).
//   • proactive — "proactive system": send the reminder-flagged notes to a PLACEHOLDER proactive
//                 pass and return how many were sent (the real system isn't built yet).
//
//  Connector-agnostic: operates on `CycleStore.notes()` regardless of source (files / notes / chats).
//  After create/update the mirror is pushed (same rule as the retired DaysEndJob.pushIfDirty).
//

import Foundation

/// A Sendable, store-agnostic description of one summary handed to a Codex call. Decouples the
/// cloud prompts from any particular store. Built from a CycleNoteItem (the iterative system) — and
/// from a legacy SummaryItem (used only by the self-test's vault mode against the old Store).
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

    /// From a legacy old-Store summary (self-test vault mode only).
    init(_ s: SummaryItem) {
        self.init(kind: s.kind, sourceID: s.sourceID, folder: s.folder,
                  title: s.title, text: s.text, itemDate: s.itemDate)
    }
}

actor VaultCloud {

    static let shared = VaultCloud()

    // In-memory resume handles (an app restart just starts fresh — correct, since the cycle's notes
    // stay in CycleStore until the proactive button wipes them).
    private var createResume: VaultGenerator.ResumeToken?
    private var updateResumeSessionID: String?

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
            await markDirtyAndPush()
            return result
        } catch let VaultGenerator.VaultError.usageLimit(message, resume) {
            createResume = resume
            throw CloudError.usageLimit(message)
        }
    }

    // MARK: Update — "go update knowledge base"

    /// Fold the current cycle's notes into the existing vault. Returns the number of notes sent.
    @discardableResult
    func update(notes: [CloudNote]) async throws -> Int {
        guard !notes.isEmpty else { return 0 }
        let fm = FileManager.default
        let vault = VaultGenerator.vaultRoot
        guard fm.fileExists(atPath: vault.path) else { throw CloudError.noVault }

        // Safety net: snapshot the vault (KBs). Restored on a thrown error; NOT on a usage limit
        // (a resume continues the half-edited state, which is exactly what's on disk).
        let snapshot = fm.temporaryDirectory.appendingPathComponent("vault-snapshot-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: snapshot)
        try fm.copyItem(at: vault, to: snapshot)
        defer { try? fm.removeItem(at: snapshot) }

        var invocation: CodexCLI.Invocation
        if let updateResumeSessionID {
            var inv = CodexCLI.Invocation(prompt: """
                Continue folding the new items into the vault exactly where you left off — the edits \
                you already made are still on disk. When everything is folded, reply with one line: \
                the number of notes you created or edited.
                """)
            inv.resumeSessionID = updateResumeSessionID
            invocation = inv
        } else {
            invocation = CodexCLI.Invocation(prompt: Self.updatePrompt(skeleton: Self.skeleton(of: vault), notes: notes))
        }
        invocation.effort = .medium                                   // daily updates are cheap
        invocation.sandbox = .workspaceWrite                         // edits confined to the vault
        invocation.cwd = vault.path
        invocation.timeout = 1_800

        Log("VaultCloud.update: folding \(notes.count) notes into the vault…")
        do {
            let envelope = try await CodexCLI.shared.run(invocation)
            updateResumeSessionID = nil
            await markDirtyAndPush()
            Log("VaultCloud.update: ✅ \(notes.count) notes (turns \(envelope.numTurns ?? -1)) — \(envelope.result.prefix(120))")
            return notes.count
        } catch let CodexCLI.CLIError.usageLimit(message, sessionID) {
            updateResumeSessionID = sessionID                        // resume later; vault left as-is
            throw CloudError.usageLimit(message)
        } catch {
            updateResumeSessionID = nil
            try? fm.removeItem(at: vault)                            // mid-edit failure → restore
            try? fm.moveItem(at: snapshot, to: vault)
            throw CloudError.failed("\(error)")
        }
    }

    // MARK: Proactive — placeholder scaffold

    /// Send the reminder-flagged notes to a proactive pass and return how many were sent. The real
    /// proactive intelligence system isn't built yet — this is a deliberate scaffold (CodexCLI,
    /// read-only sandbox) that proves the wiring end to end.
    /// TODO: real proactive (cloud judge → tier-1 reminders / tier-2 briefings).
    @discardableResult
    func proactive(reminderNotes: [CloudNote]) async throws -> Int {
        guard !reminderNotes.isEmpty else {
            Log("VaultCloud.proactive: no reminder-flagged notes — nothing to send.")
            return 0
        }
        var inv = CodexCLI.Invocation(prompt: Self.proactivePrompt(reminderNotes))
        inv.effort = .medium
        inv.sandbox = .readOnly
        inv.timeout = 600
        Log("VaultCloud.proactive: sending \(reminderNotes.count) reminder candidate(s) to codex (placeholder)…")
        do {
            let envelope = try await CodexCLI.shared.run(inv)
            Log("VaultCloud.proactive: ✅ sent \(reminderNotes.count) — \(envelope.result.prefix(120))")
        } catch let CodexCLI.CLIError.usageLimit(message, _) {
            throw CloudError.usageLimit(message)
        } catch {
            throw CloudError.failed("\(error)")
        }
        return reminderNotes.count
    }

    // MARK: Mirror push (same rule as the retired DaysEndJob.pushIfDirty)

    private func markDirtyAndPush() async {
        await MainActor.run { VaultActivity.shared.vaultDirty = true }
        guard await MirrorClient.shared.isEnabled else { return }
        do {
            try await MirrorClient.shared.push()
            await MainActor.run { VaultActivity.shared.vaultDirty = false }
            Log("VaultCloud: mirror pushed ✓")
        } catch {
            Log("VaultCloud: mirror push failed — \((error as? LocalizedError)?.errorDescription ?? "\(error)") (retries next time)")
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
        survivors (junk and sensitive items were already discarded on-device). Your job: fold them \
        into the existing vault, surgically.

        ## The vault's current skeleton (a recursive ls — the tree IS the index)
        \(skeleton)

        ## How to work — surgical edits, not a rebuild
        - **You are the second sieve — not every item deserves the vault.** The on-device model \
        already dropped obvious junk, but it is a small, lenient model; YOU are the quality bar, \
        exactly as when you built this vault (curate ruthlessly). If an item adds nothing durable — \
        trivia, noise, redundancy an existing note already covers — SKIP it: change nothing for that \
        item. A run where nothing is worth folding is a perfectly good run; reply "0".
        - **Explore only the notes you need.** Search the tree to find where each new item belongs; \
        do not re-read the whole vault.
        - **Rewrite only what changed.** Prefer editing an existing note over creating a new one; \
        create a new note ONLY when no existing note fits, following the existing folder structure \
        and naming style (`Domain/Specific — Topic.md`, frontmatter included).
        - **Never delete notes wholesale**, never reorganize folders, never rename existing notes \
        (links point at them). Keep every `[[wikilink]]` intact; add new ones where a new item \
        genuinely connects.
        - **Synthesize, don't append-dump.** Fold an item into the narrative of its note — update \
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

        Fold them in now. When you are done, reply with ONE line: the number of notes you created \
        or edited.
        """
    }

    /// Placeholder proactive prompt — proves the codex wiring; replaced when the real proactive
    /// system lands.
    private static func proactivePrompt(_ notes: [CloudNote]) -> String {
        var lines: [String] = []
        for (i, n) in notes.enumerated() {
            let title = (n.title?.isEmpty == false) ? n.title! : "(untitled)"
            lines.append("#\(i + 1) \(title) — \(n.text)")
        }
        return """
        [PLACEHOLDER — Sentient OS proactive intelligence is not built yet. This is a wiring test.]

        Below are on-device "potential reminder" candidates the local model flagged as possibly \
        time-sensitive or worth the user's attention. The real proactive system (a cloud judge that \
        decides which deserve a reminder or a briefing) will replace this prompt. For now, simply \
        acknowledge receipt and reply with ONE line: the number of candidates you received.

        \(lines.joined(separator: "\n"))
        """
    }
}
