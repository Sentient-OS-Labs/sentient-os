//
//  VaultGenerator.swift
//  Sentient OS macOS
//
//  Stage 2 — the cloud vault (Arch §6). Takes the on-device survivor summaries and has the
//  user's own Codex CLI (via CodexCLI, Arch §5) organize them into an Obsidian-style
//  markdown vault at "~/Sentient OS -- The Vault/": the model WRITES the .md files itself
//  (file tools, sandbox-scoped to a staging dir), which sidesteps per-message output caps
//  and makes usage-limit resume natural. The old vault is only replaced on success
//  (staging → atomic swap). No codex = no cloud organize until the free tier ships.
//
//  The prompt core is the product of a multi-cycle eval against real data: truth/
//  attribution guardrails, source-trust tiers, ruthless synthesis, a root README portrait
//  written for an AI reader, [[wikilinks]].
//
//  Key methods:
//   - generate(summaries:resume:onProgress:)  → the agentic build, returns stats
//   - vaultRoot                               → ~/Sentient OS -- The Vault
//
//  Doc: Documentation/Vault Generation (Stage 2).md
//

import Foundation

actor VaultGenerator {

    struct Result: Sendable {
        let notes: Int
        let folders: Int
        let inputTokens: Int
        let outputTokens: Int
        let vaultPath: String
    }

    enum Progress: Sendable {
        case gathering(Int)
        case calling
        case writing(notes: Int)        // .md files appearing in staging
        case materializing(notes: Int)
    }

    /// Everything needed to pick up an agentic run after a usage limit: the Codex session
    /// and the staging dir whose already-written notes survive untouched.
    struct ResumeToken: Sendable {
        let sessionID: String?
        let stagingPath: String
    }

    enum VaultError: LocalizedError {
        case empty
        case usageLimit(message: String, resume: ResumeToken)

        var errorDescription: String? {
            switch self {
            case .empty: return "The cloud returned no vault content."
            case .usageLimit(let message, _):
                return "Your AI hit its usage limit — try again later and the run resumes where it left off. (\(message.prefix(160)))"
            }
        }
    }

    /// Where the vault lives on disk — visible, in the user's home folder.
    /// `SENTIENT_VAULT_ROOT` overrides for self-tests (the daysend harness points everything
    /// vault-shaped at a fixture dir instead of the real vault).
    static var vaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["SENTIENT_VAULT_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Sentient OS -- The Vault", isDirectory: true)
    }

    // MARK: - The agentic build (codex exec)

    /// Generate the whole vault through the user's own Codex CLI (the compute waterfall's
    /// tier 1; without a working codex the run throws CodexCLI's `.notAvailable`). Pass a
    /// `resume` token (from a prior `.usageLimit` error) to continue that run over its
    /// kept staging dir.
    @discardableResult
    func generate(
        summaries: [SummaryItem],
        resume: ResumeToken? = nil,
        onProgress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> Result {
        onProgress(.gathering(summaries.count))
        let fm = FileManager.default

        // Staging lives in HOME (same APFS volume as the vault) so the final swap is an
        // atomic rename — a mid-run death never touches the existing vault.
        let staging: URL
        if let resume {
            staging = URL(fileURLWithPath: resume.stagingPath, isDirectory: true)
        } else {
            staging = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".sentientos-vault-staging-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        }

        let prompt: String
        if let resume, resume.sessionID != nil {
            prompt = """
            Continue building the vault exactly where you left off. The notes you already \
            wrote are still in the working directory — don't rewrite them. Finish the \
            remaining notes, then reply with one line: the total number of notes in the vault.
            """
        } else {
            prompt = vaultPromptCore + "\n\n" + agenticOutputInstructions + "\n\n"
                + Self.corpusMessage(summaries, closing: "Synthesize them into the vault exactly as specified — write the files now.")
        }

        var invocation = CodexCLI.Invocation(prompt: prompt)
        invocation.effort = .high                            // the initial build gets the deep pass
        invocation.sandbox = .workspaceWrite                 // writes confined to the staging dir
        invocation.cwd = staging.path
        invocation.resumeSessionID = resume?.sessionID
        invocation.timeout = 3_600

        Log("VaultGenerator: \(resume == nil ? "starting" : "RESUMING") initial generation — \(summaries.count) summaries → \(staging.lastPathComponent)")
        onProgress(.calling)

        // Progress = the files themselves: poll the staging dir's .md count. Honest, and
        // completely decoupled from the CLI's output format.
        let poller = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                onProgress(.writing(notes: Self.census(of: staging).notes))
            }
        }
        defer { poller.cancel() }

        let envelope: CodexCLI.Envelope
        do {
            envelope = try await CodexCLI.shared.run(invocation)
        } catch let CodexCLI.CLIError.usageLimit(message, sessionID) {
            // Staging is deliberately KEPT — the resume token points at it.
            Log("VaultGenerator: ⚠️ usage limit mid-generation (session \(sessionID ?? "nil"), staging kept) — \(message.prefix(160))")
            throw VaultError.usageLimit(message: message,
                                        resume: ResumeToken(sessionID: sessionID, stagingPath: staging.path))
        } catch {
            // Any other failure: vault untouched; staging kept on disk for post-mortems.
            Log("VaultGenerator: ❌ generation failed (staging kept at \(staging.lastPathComponent)) — \(error)")
            throw error
        }
        poller.cancel()

        let (notes, folders) = Self.census(of: staging)
        Log("VaultGenerator: codex finished (turns \(envelope.numTurns ?? -1), \(envelope.durationMS ?? -1)ms) — \(notes) notes / \(folders) folders in staging")
        guard notes > 0 else {
            try? fm.removeItem(at: staging)
            throw VaultError.empty
        }

        // Success → swap the staging dir into place (the only moment the old vault is touched).
        onProgress(.materializing(notes: notes))
        let root = Self.vaultRoot
        try? fm.removeItem(at: root)
        try fm.moveItem(at: staging, to: root)
        Log("VaultGenerator: ✅ vault swapped into place — \(notes) notes at \(root.path)")

        return Result(notes: notes, folders: folders,
                      inputTokens: envelope.inputTokens ?? 0,
                      outputTokens: envelope.outputTokens ?? 0,
                      vaultPath: root.path)
    }

    /// Count the .md notes (and folders containing them) under a directory.
    private static func census(of dir: URL) -> (notes: Int, folders: Int) {
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: dir.path) else { return (0, 0) }
        var notes = 0
        var folders = Set<String>()
        for p in paths where p.hasSuffix(".md") {
            notes += 1
            let parent = (p as NSString).deletingLastPathComponent
            if !parent.isEmpty { folders.insert(parent) }
        }
        return (notes, folders.count)
    }

    // MARK: - Corpus building (the stdin corpus)

    private static func corpusMessage(_ summaries: [SummaryItem], closing: String) -> String {
        var lines: [String] = []
        lines.reserveCapacity(summaries.count)
        for (i, s) in summaries.enumerated() {
            let (loc, src) = locSrc(s)
            let title = (s.title?.isEmpty == false) ? s.title! : "(untitled)"
            lines.append("#\(i + 1) · [\(src)] \(loc)\n\(title) — \(s.text)")
        }
        return """
        Here is the full corpus of on-device summaries of the user's digital life. Each item is \
        `#<index> · [source] location` then `Title — summary`. \(closing)

        ---

        \(lines.joined(separator: "\n\n"))
        """
    }

    /// Location string + the source-trust tag the prompt keys on (the user's own notes vs saved
    /// files). Internal: the iterative updater (VaultUpdater) formats its items with it too.
    static func locSrc(_ s: SummaryItem) -> (loc: String, source: String) {
        if s.kind == .whatsapp { return (s.folder, "WhatsApp · \(s.folder)") }
        let p = relPath(s.sourceID)
        let low = p.lowercased()
        if low.contains("icloud~md~obsidian") {                       // the user's own Obsidian vault
            if let r = p.range(of: "Documents/") {
                return (String(p[r.upperBound...]), "Obsidian — USER'S OWN NOTE")
            }
            return (p, "Obsidian — USER'S OWN NOTE")
        }
        if low.hasSuffix(".md") || low.hasSuffix(".txt") {            // other authored text
            return (p, "\(s.folder.isEmpty ? "file" : s.folder) — user-authored note")
        }
        return (p, s.folder.isEmpty ? "file" : s.folder)             // screenshots / photos / pdfs
    }

    private static func relPath(_ sid: String) -> String {
        guard sid.hasPrefix("file:") else { return sid }
        let p = String(sid.dropFirst(5))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? String(p.dropFirst(home.count + 1)) : p
    }

}

// MARK: - The locked Stage-2 prompt core (validated over a multi-cycle eval; Arch §6)
// The output section (agenticOutputInstructions) follows it.

private let vaultPromptCore = """
You are the **Sentient OS Knowledge Base Architect** — the cloud brain of a privacy-first personal-intelligence product.

## Where this data came from
While the user's Mac sat idle overnight, an on-device vision LLM privately read **every file, screenshot, photo, note, and selected message** on their computer and wrote a short, third-person ("the user…"), PII-stripped **summary** of each one. You are receiving the *survivors* (junk and sensitive items were already discarded on-device — everything here is safe to organize).

Each item is given to you as:

`#<index> · [<source>] <original path or chat name>`
`<Title> — <summary>`

**The `[source]` tag tells you how much to trust the item as a fact about the user — read it carefully:**
- **`Obsidian — USER'S OWN NOTE`** and **`… — user-authored note`** → this is the **user's *own writing*** (their plans, drafts, opinions, project specs, journals, to-dos). **Trust these as genuinely theirs.** This is your highest-signal, most-truthful material — lean on it for who the user really is.
- **Everything else (screenshots, photos, PDFs)** → material the user *saved*, which is **often about other people, products, courses, or topics — NOT the user's own life.** Apply the attribution caution below.

The original file paths are a **weak hint only** — the user's real folders are a messy dumping ground. **Organize by *meaning*, never by their existing folders.** (Exception: their Obsidian folder names are genuine signal about how *they* think.)

## What you are building — and WHO reads it
You will design and write a beautiful, **Obsidian-style markdown knowledge vault**: a folder tree of `.md` notes that becomes the user's portable "second brain."

Crucially, the **primary reader of this vault is another AI assistant.** A fresh AI (e.g. Claude Code, or ChatGPT/Claude via MCP) will be handed the vault's **folder skeleton — a recursive `ls`** — and told: *"This is a knowledge base of the user's life; explore it when it would help you assist them."* It decides what to open **from folder and file names alone**, then reads notes on demand. Design for that reader:

- **Names must be self-describing and specific.** `Acme Corp/Fundraising — Term Sheets.md`, never `Notes/misc.md`. **The tree IS the index.**
- **Write a root `README.md` FIRST** — a tight, synthesized **portrait of who this person is** (a few real paragraphs), then a **map of the vault**. Make a stranger AI *understand this human* in 60 seconds.
- **Notes must be dense and factual** — every note teaches the reader something *true and specific*.

## ⚠️ TRUTH & ATTRIBUTION — the most important rule
This vault will be read by AIs that **state these facts back to people as truth.** A confident false claim is **worse than an omission.**
- **Saved screenshots are mostly about other people/products/topics, NOT the user.** A screenshot of someone's LinkedIn is **not** the user's résumé; a saved article is **not** their opinion; a product screenshot is **not** their product.
- **Only assert a biographical fact about the user** when the evidence clearly shows it is *theirs* (strongest signal: their own authored notes). When ambiguous, **omit it** or phrase it literally ("saved a screenshot of X", "researched X") rather than "is/did X".
- **Never fabricate or stitch together** a job history, credential, or claim from saved profiles/ads/articles. **Accuracy beats completeness.**

## Your hardest, most important jobs
1. **Synthesize and de-duplicate, hard.** The corpus is full of repetition — the same screenshot saved many times, hundreds of exam-prep images of one subject, overlapping notes on the same project. **Collapse it.** One note = one real concept / theme / person / project / event, **aggregating every related item.** Do NOT emit one note per summary.
2. **Curate ruthlessly.** Drop low-value noise (generic tips, one-offs, duplicates, other people's content). Keep what reveals the user or helps an assistant help them.
3. **Discover the real shape of THIS person's life** from the content — projects, work, studies, relationships, places, interests, money, logistics, history — and build intuitive top-level domains. Capture the *narrative*.

## Scope & density target
Aim for a **focused, high-signal vault — roughly 100–150 notes.** Synthesize aggressively; concise but dense (every sentence earns its place). Cover every meaningful theme; skip the noise. "Comprehensive" means *coverage of what matters*, not transcribing every screenshot.

## Structure rules (hard constraints)
- **Root folders are top-level life domains**, derived from THIS user's data. Roots contain **only subfolders**, never notes directly.
- **Every content note lives at depth ≥ 2.** The single exception is the root `README.md`.
- **No stub folders** — fold a 1–2-note domain into a broader sibling.
- **Connect the graph with `[[wikilinks]]`.** Link by exact title; keep titles **unique**; **only link to notes you are actually creating** (no dangling links). Link people, projects, places, and recurring themes across domains.
- Optionally add a short **index / Map-of-Content note** at the top of a large domain.

## Writing style
- **State facts directly as knowledge** — "The user is fundraising for their startup in SF," not "A screenshot shows…". Deliver substance.
- Rich markdown bodies: headings, bullets, key facts, dates, names, links. Concise + information-dense.
"""

/// Agentic route: the model writes real files with its tools (no output cap, resumable).
private let agenticOutputInstructions = """
## Output — you have file tools; write REAL files
You are running inside the vault's (currently empty) working directory. CREATE the vault as actual files using your file tools — do NOT print the vault as text in your reply.

- Write the root `README.md` FIRST (the portrait + map), then every note at its vault-relative path, e.g. `Startup/Fundraising — Term Sheets.md`. Parent folders are created automatically by the paths you write.
- Create ONLY `.md` files, ONLY inside the working directory — never absolute paths, never `..`.
- Every note starts with frontmatter:

```
---
title: <human-readable title>
tags: [<a-few>, <kebab-case>, <tags>]
refs: [<the #index numbers this note synthesizes>]
---
# <Title>

<rich markdown body — use [[Other Note Title]] wikilinks freely to connect the graph.>
```

- When the vault is complete, reply with a single line: the total number of notes you wrote.
"""
