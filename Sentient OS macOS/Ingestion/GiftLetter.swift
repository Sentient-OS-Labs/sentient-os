//
//  GiftLetter.swift
//  Sentient OS macOS  ·  Ingestion/
//
//  The welcome "gift" — the day-one "letter from Sentient" card (Arch §6). One Codex call
//  (gpt-5.5, high, workspace-write over the user's OWN knowledge base) reads the synthesized
//  cross-life portrait and WRITES the finished letter as "Gift from Sentient.md" in the vault folder.
//  We read that file back, persist it, and delete it so nothing strays into the user's notes. The
//  letter is plain-English Markdown (a title, a couple of sections, ✦ bullets) — rendered by the
//  welcome/envelope card via `Briefing(fromGiftMarkdown:)`. Hermetic: no web, no MCP — grounded only
//  in their own life.
//
//  Key methods:
//   - generate() async throws -> String   (reads the KB, runs Codex, reads back the letter, persists)
//   - latest() -> String?                 (the last generated letter; nil if never run)
//
//  The prompt is iterated by the team in Our_Stuff/Gift Card Prompt.md — keep the two in sync.
//

import Foundation

actor GiftLetter {

    static let shared = GiftLetter()

    /// The file the model writes the letter into (inside the knowledge-base folder, per the prompt).
    static let fileName = "Gift from Sentient.md"

    enum GiftError: LocalizedError {
        case noVault
        case empty
        case usageLimit(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noVault:           return "No knowledge base on disk yet — build it first, then the welcome gift can be written."
            case .empty:             return "The model didn't produce a letter."
            case .usageLimit(let m): return "Your AI hit its usage limit — try again later. (\(m.prefix(160)))"
            case .failed(let m):     return m
            }
        }
    }

    /// Read the knowledge base and write the welcome gift letter. The model writes it to
    /// "Gift from Sentient.md" in the vault folder; we read it back, persist it, and DELETE the file so
    /// no stray note ever lingers (or gets mirrored). Hermetic — no web, no user MCP. Throws on
    /// no-vault / empty / usage-limit / failure.
    @discardableResult
    func generate() async throws -> String {
        let vault = VaultGenerator.vaultRoot
        let fm = FileManager.default
        guard fm.fileExists(atPath: vault.path) else { throw GiftError.noVault }

        let giftFile = vault.appendingPathComponent(Self.fileName)
        try? fm.removeItem(at: giftFile)               // clear any stale copy before the run
        defer { try? fm.removeItem(at: giftFile) }     // never leave it behind, on ANY exit path

        var inv = CodexCLI.Invocation(prompt: Self.prompt(vaultPath: vault.path))
        inv.feature = "giftletter"
        inv.effort = .high                  // the gift should feel like magic — give it the deep pass
        inv.sandbox = .workspaceWrite       // it WRITES "Gift from Sentient.md" into the vault folder
        inv.cwd = vault.path                // the knowledge base is the working dir → reads + writes here
        inv.webSearch = false               // grounded ONLY in their own life — no external facts
        inv.includeUserConfig = false       // hermetic — no user MCP servers, nothing leaks in
        inv.timeout = 1_200

        Log("GiftLetter: writing the welcome gift from the knowledge base at \(vault.lastPathComponent)…")
        do {
            let env = try await CodexCLI.shared.run(inv)
            // The letter is the file the model wrote; fall back to its final message if it skipped it.
            let fromFile = (try? String(contentsOf: giftFile, encoding: .utf8)) ?? ""
            let letter = Self.cleanMarkdown(fromFile.isEmpty ? env.result : fromFile)
            guard !letter.isEmpty else { throw GiftError.empty }
            Log("GiftLetter: ✅ welcome letter (\(letter.count) chars, turns \(env.numTurns ?? -1), \(env.outputTokens ?? -1) out-tokens)")
            Self.saveLatest(letter)
            return letter
        } catch let CodexCLI.CLIError.usageLimit(message, _) {
            throw GiftError.usageLimit(message)
        } catch let e as GiftError {
            throw e
        } catch {
            throw GiftError.failed("\(error)")
        }
    }

    // MARK: Persistence (the home reads this to render the welcome card)

    private static let latestKey = "gift.latestLetter"

    static func saveLatest(_ letter: String) {
        UserDefaults.standard.set(letter, forKey: latestKey)
    }

    /// The last generated letter (markdown), or nil if it's never run (so the cycle writes it once).
    static func latest() -> String? {
        let s = UserDefaults.standard.string(forKey: latestKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// Forget the welcome letter (the dev "Reset everything" path) — so it's rewritten next cycle.
    static func clear() { UserDefaults.standard.removeObject(forKey: latestKey) }

    // MARK: Output cleanup

    /// Strip a wrapping ```/```markdown fence if the model added one around the whole letter.
    private static func cleanMarkdown(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNL = s.firstIndex(of: "\n") { s = String(s[s.index(after: firstNL)...]) }
            if let fence = s.range(of: "```", options: .backwards) { s = String(s[..<fence.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The prompt (team-iterated in Our_Stuff/Gift Card Prompt.md — keep in sync)

    private static func prompt(vaultPath: String) -> String {
        """
        You are the heart of Sentient OS — an AI that lives on the user's own Mac and has quietly read their ENTIRE life: their files, messages, notes, calendar, email, etc. You're about to use that to give them a small, delightful gift (a "letter from Sentient") that shows up the first time they open Sentient after its knowledge base creation is complete.

        THE KNOWLEDGE BASE — GO READ IT WELL!
        The user's whole life has been synthesized into a knowledge base: a folder of markdown notes at this exact path on this Mac (it is also your current working directory):

            \(vaultPath)

        Read it thoroughly FIRST — open README.md, then read the notes across EVERY folder — before you write a single word. Every claim in your letter MUST be grounded in what you actually find there. If it isn't in the knowledge base, you may not say it. Never invent.

        YOUR TASK
        Find a few of the most interesting, genuinely true **delightful** patterns about this person — the kind they would never have noticed themselves, because each one only becomes visible when everything about their life sits in one place. Then write them up as a short letter.

        WHAT MAKES A GREAT PATTERN
        - It connects different corners of their life (e.g. a trait at work shows up again in a hobby; a habit in their messages echoes in their files). Single-topic observations are weak — reach across.
        - It is genuinely surprising — something they probably haven't put into words about themselves. NOT obvious filler like "you work hard" or "you care about your family."
        - It is specific and unmistakably about THEM. Name the real things — the actual project, person, place, app, habit — so it reads as obviously true, not generic.
        - It's delightful -- reading this "letter from Sentient" must make them smile :D
        - It's personal!

        LANGUAGE
        No using buzz words nor AI-isms:
        - No em-dashes
        - No "it's not just x, it's y"
        - A genuine feeling letter that a 25 year old may have written. No buzzwords nor jargon. Understandable by a 12 year old.
        - Each pattern = a short bold headline (about 3–7 words, ending in a period) then ONE sentence (about 15–25 words) that explains it with a concrete real detail.
        - These are real examples of the BAD writing we are fixing — NEVER write like this: "You spec hardware in numbers and music in feelings." / "Your optimization points outward." They sound clever and say almost nothing. Banned.
        - Talk to the user as "you." Warm and plain, like a friend who noticed something cool about them.

        Explore a **ton** of MD files, and think **deep** about the most delightful, incredible letter before you write anything.

        **Important: quality matters much more than quantity! 3-4 high-quality points are wayy better than 6 points you aren't as confident about (the disconnect would ruin the whole point).**

        OUTPUT — A SINGLE MARKDOWN LETTER

        Example of a great result:
        ```
        # The System Builder's Map

        I just analyzed your entire digital life to understand you. So much stands out :)
        ### Something you might not know about yourself

        **Your real pattern is not just building AI products; it is turning recurring ambiguity into reusable systems.**
        In IB Math AA HL, you made decision-tree guides for integration, trig, logs, complex numbers, and proofs. For Jacob, you made timetables, exam calendars, custom AI prompts, and even an ICSE CS textbook. Sentient OS is the same reflex at startup scale: take the chaos of screenshots, files, notes, and messages, then compress it into a queryable vault.

        ## Also noticed

        ✦ Your breakout projects keep starting from Apple-shaped constraints: Writing Tools as an open-source Apple Intelligence port, iPadOS on iPhone, and Sentient's on-device macOS/iOS layer.
        ✦ You care about assistants having the right "operating manual" for a person: you maintain prompts across ChatGPT, Claude, Gemini, Perplexity, and tailored prompts for Jacob.
        ✦ Your public technical credibility is unusually concrete: 30,000+ Writing Tools users, 28+ publications, WIRED coverage, and a 2025 UMass Tech Challenge win.

        -- Your Sentient
        ```

        When you're done reading and thinking, write this as `Gift from Sentient.md` in this directory. It'll be displayed in the Sentient UI.
        """
    }
}
