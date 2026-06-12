//
//  VaultGenerator.swift
//  Sentient OS macOS
//
//  Stage 2 — the cloud vault (Arch §6). Takes the on-device survivor summaries and has a
//  frontier model organize them into an Obsidian-style markdown vault at
//  "~/Sentient OS -- The Vault/". Two routes behind one generate() call:
//
//   1. AGENTIC (default, Arch §5): the user's own Codex CLI via CodexCLI — the model
//      WRITES the .md files itself (file tools, sandbox-scoped to a staging dir),
//      which sidesteps per-message output caps and makes usage-limit resume natural. The
//      old vault is only replaced on success (staging → atomic swap).
//   2. DIRECT (fallback while the Bedrock tier doesn't exist): one streamed Opus API call
//      emitting a `=== NOTE: <path> ===` stream we parse and materialize ourselves.
//
//  The shared prompt core is the product of a multi-cycle eval against real data: truth/
//  attribution guardrails, source-trust tiers, ruthless synthesis, a root README portrait
//  written for an AI reader, [[wikilinks]].
//
//  Key methods:
//   - generate(summaries:resume:onProgress:)  → routes agentic/direct, returns stats
//   - vaultRoot                               → ~/Sentient OS -- The Vault
//   - parseNotes(_:)                          → splits the direct route's note stream
//
//  🔒 The direct route's API key lives in Secrets.swift (gitignored).
//  Doc: Documentation/Vault Generation (Stage 2).md
//

import Foundation

/// Where For You artifacts live — `~/Library/Application Support/SentientOS/Briefings/`
/// [STARTING POINT], deliberately outside the vault (briefings are artifacts we generate,
/// not the user's knowledge base — they must never ride the mirror push). Written by the
/// welcome briefing today; proactive intelligence (rebuilt separately) writes here next.
enum Briefings {
    static var dir: URL {
        let d = URL.applicationSupportDirectory
            .appendingPathComponent("SentientOS/Briefings", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

actor VaultGenerator {

    struct Result: Sendable {
        let notes: Int
        let folders: Int
        let inputTokens: Int
        let outputTokens: Int
        let stopReason: String
        let vaultPath: String
    }

    enum Progress: Sendable {
        case gathering(Int)
        case calling
        case receiving(chars: Int)      // direct route: response streaming in
        case writing(notes: Int)        // agentic route: .md files appearing in staging
        case materializing(notes: Int)
    }

    /// Everything needed to pick up an agentic run after a usage limit: the Codex session
    /// and the staging dir whose already-written notes survive untouched.
    struct ResumeToken: Sendable {
        let sessionID: String?
        let stagingPath: String
    }

    enum VaultError: LocalizedError {
        case http(Int, String)
        case empty
        case usageLimit(message: String, resume: ResumeToken)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "Cloud returned HTTP \(code). \(body.prefix(300))"
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

    // MARK: - Route selection

    /// Generate the whole vault. Piggybacks on the user's Codex CLI when available
    /// (the compute waterfall's tier 1); otherwise falls back to the direct API call.
    /// Pass a `resume` token (from a prior `.usageLimit` error) to continue that run.
    @discardableResult
    func generate(
        summaries: [SummaryItem],
        resume: ResumeToken? = nil,
        effort: String = "xhigh",
        maxTokens: Int = 128_000,
        onProgress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> Result {
        if resume != nil {
            return try await generateAgentic(summaries: summaries, resume: resume, onProgress: onProgress)
        }
        if case .available = await CodexCLI.shared.validate() {
            return try await generateAgentic(summaries: summaries, resume: nil, onProgress: onProgress)
        }
        #if DEBUG
        Log("VaultGenerator: Codex unavailable → direct-API fallback")
        #endif
        return try await generateDirect(summaries: summaries, effort: effort,
                                        maxTokens: maxTokens, onProgress: onProgress)
    }

    // MARK: - Route 1: agentic file-writer (codex exec)

    private func generateAgentic(
        summaries: [SummaryItem],
        resume: ResumeToken?,
        onProgress: @Sendable @escaping (Progress) -> Void
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
            throw VaultError.usageLimit(message: message,
                                        resume: ResumeToken(sessionID: sessionID, stagingPath: staging.path))
        }
        poller.cancel()

        let (notes, folders) = Self.census(of: staging)
        guard notes > 0 else {
            try? fm.removeItem(at: staging)
            throw VaultError.empty
        }

        // Success → swap the staging dir into place (the only moment the old vault is touched).
        onProgress(.materializing(notes: notes))
        let root = Self.vaultRoot
        try? fm.removeItem(at: root)
        try fm.moveItem(at: staging, to: root)

        return Result(notes: notes, folders: folders,
                      inputTokens: envelope.inputTokens ?? 0,
                      outputTokens: envelope.outputTokens ?? 0,
                      stopReason: "completed",
                      vaultPath: root.path)
    }

    /// The welcome briefing — initial gen's second act ("here's what I learned about you"),
    /// For You's day-one artifact. A cheap medium-effort pass over the freshly built vault that lands
    /// ONE .md in the Briefings folder (outside the vault — it never rides the mirror push).
    /// Best-effort: a failure logs and moves on; the vault itself is already safe on disk.
    func writeWelcomeBriefing() async {
        let date: String = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
            return f.string(from: Date())
        }()
        let file = Briefings.dir.appendingPathComponent("\(date) — What I learned about you.md")

        var inv = CodexCLI.Invocation(prompt: """
            You just finished organizing a person's entire digital life into the Obsidian-style \
            knowledge vault that is your working directory. Now write them a welcome.

            Read the root README.md first, then explore a handful of the most interesting notes \
            (be selective, not exhaustive). Then write ONE markdown briefing to \
            this exact path:
            \(file.path)

            Shape: title "What I learned about you". Open with a warm, specific portrait of who \
            they are — a few real paragraphs, addressed to them as "you" (never "the user"). \
            Then 3–5 delightful cross-domain connections you noticed that they might not have \
            seen themselves (the screenshot trail that matches a note, the plan echoed across \
            chats…). Close with one short paragraph on what happens next: their vault now stays \
            current automatically, and their other AIs can read it the moment they connect. \
            Specific beats flattering; true beats complete. Never include raw private specifics.

            When the briefing is written, reply with one line: DONE.
            """)
        inv.sandbox = .workspaceWrite
        inv.cwd = Self.vaultRoot.path
        inv.addDirs = [Briefings.dir.path]
        inv.timeout = 600
        do {
            _ = try await CodexCLI.shared.run(inv)
            Log("VaultGenerator: welcome briefing → \(file.lastPathComponent)")
        } catch {
            Log("VaultGenerator: welcome briefing failed — \(error)")
        }
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

    // MARK: - Route 2: direct API (the code-preserved fallback)

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Internal (not private) so the self-test can force this route via SENTIENT_VAULT_ROUTE=direct.
    func generateDirect(
        summaries: [SummaryItem],
        effort: String,
        maxTokens: Int,
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async throws -> Result {
        onProgress(.gathering(summaries.count))

        // 1) Build the request.
        let userMessage = Self.corpusMessage(
            summaries,
            closing: "Synthesize them into the vault exactly as specified — emit ONLY the stream of `=== NOTE: path ===` markdown files, nothing else.")
        let body: [String: Any] = [
            "model": "claude-opus-4-8",
            "max_tokens": maxTokens,
            "system": vaultPromptCore + "\n\n" + directOutputFormat,
            "messages": [["role": "user", "content": userMessage]],
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": effort],
            "stream": true,
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(Secrets.anthropicKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 1800

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1800
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)

        onProgress(.calling)

        // 2) Stream-collect the SSE response (native URLSession keepalive avoids idle drops).
        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var err = ""
            for try await line in bytes.lines { err += line; if err.count > 1200 { break } }
            throw VaultError.http(http.statusCode, err)
        }

        var assembled = ""
        var inTok = 0, outTok = 0, stop = "unknown", lastReport = 0
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let d = payload.data(using: .utf8),
                  let ev = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let type = ev["type"] as? String else { continue }
            switch type {
            case "message_start":
                if let m = ev["message"] as? [String: Any], let u = m["usage"] as? [String: Any] {
                    inTok = u["input_tokens"] as? Int ?? 0
                }
            case "content_block_delta":
                if let delta = ev["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String {
                    assembled += t
                    if assembled.count - lastReport >= 1500 {
                        lastReport = assembled.count
                        onProgress(.receiving(chars: assembled.count))
                    }
                }
            case "message_delta":
                if let u = ev["usage"] as? [String: Any] { outTok = u["output_tokens"] as? Int ?? outTok }
                if let delta = ev["delta"] as? [String: Any], let sr = delta["stop_reason"] as? String { stop = sr }
            case "error":
                throw VaultError.http(0, payload)
            default:
                break
            }
        }
        guard !assembled.isEmpty else { throw VaultError.empty }

        // 3) Parse + materialize (full rebuild).
        let notes = Self.parseNotes(assembled)
        onProgress(.materializing(notes: notes.count))
        let root = Self.vaultRoot
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var folders = Set<String>()
        for (path, content) in notes {
            let dst = root.appendingPathComponent(path)
            let dir = dst.deletingLastPathComponent()
            if dir.path != root.path { folders.insert(dir.path) }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? content.write(to: dst, atomically: true, encoding: .utf8)
        }

        return Result(notes: notes.count, folders: folders.count,
                      inputTokens: inTok, outputTokens: outTok, stopReason: stop,
                      vaultPath: root.path)
    }

    // MARK: - Corpus building (shared by both routes)

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

    // MARK: - Note-stream parser (direct route)

    /// Splits the `=== NOTE: <path> ===` stream into (vault-relative path, file content) pairs.
    /// Ignores any prose before the first sentinel. Truncation-safe: every COMPLETE note survives.
    static func parseNotes(_ text: String) -> [(path: String, content: String)] {
        var out: [(String, String)] = []
        var currentPath: String?
        var buf: [Substring] = []
        func flush() {
            defer { buf.removeAll() }
            guard let p = currentPath, let safe = sanitizePath(p) else { return }
            let content = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { out.append((safe, content + "\n")) }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("=== NOTE:") && t.hasSuffix("===") {
                flush()
                var inner = t.dropFirst("=== NOTE:".count)
                if let r = inner.range(of: "===", options: .backwards) { inner = inner[..<r.lowerBound] }
                currentPath = inner.trimmingCharacters(in: .whitespaces)
            } else if currentPath != nil {
                buf.append(line)
            }
        }
        flush()
        return out
    }

    /// Strip leading slash, drop `..`/`.` components, ensure a `.md` extension. nil if empty.
    private static func sanitizePath(_ raw: String) -> String? {
        var comps = raw.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != ".." && $0 != "." }
        guard !comps.isEmpty else { return nil }
        if !comps[comps.count - 1].lowercased().hasSuffix(".md") { comps[comps.count - 1] += ".md" }
        return comps.joined(separator: "/")
    }
}

// MARK: - The locked Stage-2 prompt core (validated over a multi-cycle eval; Arch §6)
// Shared by both routes. The output-format sections below tailor it per route.

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

/// Direct route: one giant text response, parsed by parseNotes().
private let directOutputFormat = """
## Output format — read carefully
Emit a **stream of markdown files and NOTHING else.** No prose, no preamble, no code fences before or after. Each file is introduced by a sentinel line carrying its full vault-relative path:

```
=== NOTE: <folder>/<subfolder>/<Title>.md ===
---
title: <human-readable title>
tags: [<a-few>, <kebab-case>, <tags>]
refs: [<the #index numbers this note synthesizes>]
---
# <Title>

<rich markdown body — use [[Other Note Title]] wikilinks freely to connect the graph.>
```

Repeat the `=== NOTE: … ===` block for every note. The path on the sentinel line determines the folders (created implicitly). **Start with `=== NOTE: README.md ===`** (the root portrait + map), then emit the rest of the vault. Begin now.
"""
