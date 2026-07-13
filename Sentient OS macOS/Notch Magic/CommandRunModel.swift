//
//  CommandRunModel.swift
//  Sentient OS macOS
//
//  Runs ONE "do this for me" task through the user's codex (computer use), streaming codex's latest
//  output line(s) into `statusLine`. `stop()` cancels the run (CodexCLI terminates codex). One run at a time.
//
//  Both ways to start a task — the home command bar AND the right-⌘ hotkey — drive the SAME instance
//  (owned by CommandCoordinator), so the prompt bar and the notch are two views of one run. `onFinished`
//  lets the coordinator move the notch from running → finishing. Everything also tees to Log()
//  (tail /tmp/sentient-dev.log). Doc: Documentation/Notch Magic/.
//
//  Key methods: start(_:mode:) · stop() · commandPrompt(task:mode:hasScreenshot:spoken:).
//

import Foundation

@MainActor @Observable
final class CommandRunModel {
    /// How a run ended — drives the notch's finishing glyph (and nothing else).
    enum Outcome: Equatable { case success, stopped, failed }

    var isRunning = false
    var statusLine = ""                          // the latest 1–2 codex lines, shown in the bar while running
    /// While codex is reading the knowledge base, the note it's on (relative path; "" = whole vault).
    /// Drives the gradient, blooming "Remembering …" in the notch. nil = not reading the KB.
    private(set) var remembering: String?
    private(set) var mode: AgentMode = .computer // the in-flight run's channel (the notch shows only for .computer)

    /// Set by the coordinator to learn when a run ends (running → finishing). Optional — the prompt bar
    /// alone doesn't need it.
    var onFinished: ((Outcome) -> Void)?

    private var recent: [String] = []
    private var section = ""                      // codex's current output section (user/codex/exec/…) — for filtering the bar
    private var task: Task<Void, Never>?
    private var rememberClear: Task<Void, Never>?   // keeps "Remembering" up ≥1.5s so its bloom completes
    private var source = "command"                // who triggered this run (promptBar / voice) — scoreboard tag
    private var runStarted = Date()              // for the scoreboard duration

    func start(_ text: String, mode: AgentMode, source: String = "command") {
        guard !isRunning else { return }
        let task0 = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task0.isEmpty else { return }
        self.mode = mode
        self.source = source
        self.runStarted = Date()
        isRunning = true
        recent = []
        section = ""
        remembering = nil
        rememberClear?.cancel()
        statusLine = "Starting \(mode.promptPhrase)…"
        Log("──────── 🤖 \(mode.label.uppercased()) · command ────────")
        let started = Date()
        task = Task { [weak self] in
            // Snap the screen NOW so computer use sees exactly what the user is looking at (nil if the
            // Screen Recording grant is missing → runs text-only). Deleted the moment codex is done.
            let shot = await ScreenCapture.grab()
            defer { ScreenCapture.discard(shot) }
            let prompt = Self.commandPrompt(task: task0, mode: mode, hasScreenshot: shot != nil,
                                            spoken: source == "voice")
            Log("CMD: launching codex exec (gpt-5.6-sol · \(mode.promptPhrase) · bypass sandbox · screenshot: \(shot != nil))…")
            #if DEBUG   // B7: prompt + live output + final carry the user's command, KB context, and codex
                        // play-by-play — DEBUG-only so they can never become a Release breadcrumb.
            Log("CMD: prompt ↓\n\(prompt)")
            #endif
            Log("──────────────── live codex output ↓ ────────────────")
            do {
                let out = try await CodexCLI.shared.runAgentCommand(prompt, imagePath: shot?.path) { line in
                    Task { @MainActor in
                        #if DEBUG
                        Log("CMD │ \(line)")
                        #endif
                        self?.push(line)
                    }
                }
                let secs = Int(Date().timeIntervalSince(started))
                Log("──────── 🤖 ✓ DONE in \(secs)s ────────")
                #if DEBUG
                Log("CMD: final → \(out.suffix(1200))")
                #endif
                self?.complete(.success, line: "✓ done")
            } catch {
                let secs = Int(Date().timeIntervalSince(started))
                if Task.isCancelled {
                    Log("──────── 🤖 ■ STOPPED after \(secs)s ────────")
                    self?.complete(.stopped, line: "■ stopped")
                } else {
                    Log("──────── 🤖 ✗ FAILED after \(secs)s ────────")
                    Log("CMD: \(ErrorLabel(error))")
                    self?.complete(.failed, line: "✗ \(Self.short(error))")
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        clearRemembering()
        statusLine = "Stopping…"
        task?.cancel()
    }

    private func push(_ line: String) {
        guard isRunning else { return }

        // Strip codex's stderr channel tag — BEFORE trimming, so a bare "stderr:" (empty line) vanishes
        // instead of flashing in the bar.
        var t = line
        if t.hasPrefix("stderr: ")      { t = String(t.dropFirst("stderr: ".count)) }
        else if t.hasPrefix("stderr:")  { t = String(t.dropFirst("stderr:".count)) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)

        // The confirmation-policy dump's tail lingers — show a clean status for that whole loading beat.
        if t.range(of: "avoid redundant confirmations", options: .caseInsensitive) != nil {
            recent = ["Thinking through your task"]
            statusLine = "Thinking through your task"
            return
        }

        // codex's human-readable output is sectioned by bare headers; track (and never show) them.
        if Self.sectionHeaders.contains(t.lowercased()) { section = t.lowercased(); return }

        // exec section: surface knowledge-base reads as the "Remembering" state; drop all other shell output.
        if section == "exec" {
            if let note = Self.knowledgeBaseRead(t) { setRemembering(note) }
            return
        }

        guard let shown = Self.barLine(t, section: section) else { return }   // drop chrome / echo / output
        recent.append(shown)
        if recent.count > 2 { recent.removeFirst() }
        statusLine = recent.joined(separator: "\n")
    }

    /// Hold the "Remembering" state on the note codex is reading, refreshing a ≥1.5s minimum so the bloom
    /// animation completes even when only a single file is read.
    private func setRemembering(_ note: String) {
        remembering = note
        rememberClear?.cancel()
        rememberClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if let self, !Task.isCancelled { self.remembering = nil }
        }
    }

    private func clearRemembering() {
        rememberClear?.cancel(); rememberClear = nil
        remembering = nil
    }

    private static let sectionHeaders: Set<String> = ["user", "codex", "exec", "thinking", "tokens used"]
    private static let knowledgeBaseName = VaultGenerator.vaultRoot.lastPathComponent

    /// If this `exec` line is a knowledge-base read, the note's relative path ("People/Serena.md"), or ""
    /// for a whole-vault read (grep/ls). nil = not a read. Command-agnostic: it keys off the vault PATH,
    /// not `cat`, so sed/head/grep/etc. all work — and it requires the path be shell-QUOTED (only the
    /// command quotes the spaced folder; grep/ls OUTPUT prints it bare → ignored).
    private static func knowledgeBaseRead(_ line: String) -> String? {
        guard let r = line.range(of: knowledgeBaseName + "/") else {
            return line.contains(knowledgeBaseName) ? "" : nil          // grep/ls the whole vault → generic
        }
        let after = line[r.upperBound...]
        guard let end = after.firstIndex(where: { $0 == "'" || $0 == "\"" }) else { return nil }   // unquoted ⇒ output
        return after[..<end].trimmingCharacters(in: .whitespaces)
    }

    /// What to show in the bar for a NON-exec codex line (nil = drop). Keeps codex's narration + tool
    /// actions; hides the CLI chrome — the startup banner, the user-prompt echo, reasoning, counts.
    private static func barLine(_ line: String, section: String) -> String? {
        guard !line.isEmpty else { return nil }
        if line.allSatisfy({ $0 == "-" }) { return nil }                    // "---" / "--------" rules
        switch section {
        case "user", "thinking", "tokens used":
            return nil                                                      // prompt echo · reasoning · counts
        case "":
            let chrome = ["Reading additional input", "OpenAI Codex", "workdir:", "model:", "provider:",
                          "approval:", "sandbox:", "reasoning effort:", "reasoning summaries:", "session id:"]
            return chrome.contains(where: { line.hasPrefix($0) }) ? nil : line   // startup banner
        default:
            return line                                                    // "codex" narration + mcp/action lines
        }
    }

    private func complete(_ outcome: Outcome, line: String) {
        // §7.19: feed the executor scoreboard (this IS the command-bar / voice computer-use path).
        // Skip .stopped — that's a user cancel, not a health outcome. `fired` = codex exited 0
        // (claimed done), NOT verified.
        if let board: ExecutorScoreboard.Outcome = (outcome == .success ? .fired : (outcome == .failed ? .failed : nil)) {
            ExecutorScoreboard.record(method: "computer", source: source, outcome: board,
                                      durationS: Date().timeIntervalSince(runStarted))
        }
        // Core tier: how long the agent worked this run — EVERY outcome (a stopped run still had
        // the notch lit that long). floatValue sums server-side into total agent-seconds, the
        // "Sidekick saved users N hours" headline.
        let outcomeTag = outcome == .success ? "success" : (outcome == .stopped ? "stopped" : "failed")
        Analytics.signal("ComputerUse.finished",
                         parameters: ["source": source, "method": mode.rawValue, "outcome": outcomeTag],
                         floatValue: Date().timeIntervalSince(runStarted), tier: .core)
        clearRemembering()
        statusLine = line
        isRunning = false
        task = nil
        onFinished?(outcome)
        Task { [weak self] in            // let the final status linger a moment, then clear the bar
            try? await Task.sleep(for: .seconds(outcome == .success ? 2.5 : 4.5))
            if let self, !self.isRunning { self.statusLine = "" }
        }
    }

    private static func short(_ error: Error) -> String {
        String(((error as? LocalizedError)?.errorDescription ?? "\(error)").prefix(160))
    }

    /// Build the command prompt: `mode.promptPhrase` ("computer use") leads and the typed/spoken task fills
    /// the rest. The agent is told to do the TASK via computer use (not AppleScript GUI-scripting), and to
    /// read the knowledge base (path resolved from `~`) with its shell/file tools — NOT by opening it in a
    /// GUI app like Obsidian. When `hasScreenshot`, a frame of the user's live screen is attached (via
    /// `codex exec -i`), so the prompt tells the agent to ground "this"/"here" in what it can see.
    /// When `spoken` (Sidekick's hold-to-talk), the agent is told the task is a speech-to-text transcript,
    /// so it reads through mis-transcriptions instead of taking them literally — but doesn't gamble on an
    /// uncertain reading when the outcome would be non-trivial.
    nonisolated static func commandPrompt(task: String, mode: AgentMode, hasScreenshot: Bool,
                                          spoken: Bool = false) -> String {
        let voiceLine = spoken
            ? "\nThe task above was spoken by me and transcribed with speech-to-text. Use common sense for anything that may have been mis-transcribed; but if picking the wrong reading could have a non-trivial outcome, don't act on a guess.\n"
            : ""
        let screenLine = hasScreenshot
            ? "\nAttached is a screenshot of my screen exactly as it looks right now. Use it to see what I'm currently looking at — resolve any \"this\", \"here\", \"that form\", etc. against what's on screen before you act.\n"
            : ""
        // The user's standing Sidekick context (Settings → Proactive & Sidekick) — preferred apps,
        // browser, norms. Empty string when they've set none, so the prompt is unchanged by default.
        let context = CustomInstructions.sidekick
        let contextLine = context.isEmpty ? ""
            : "\nStanding preferences I've set for you (apply them wherever they're relevant to this task): \(context)\n"
        return """
        Using \(mode.promptPhrase), \(task)
        \(voiceLine)\(screenLine)
        Carry out the task itself with \(mode.promptPhrase) — drive the real apps and websites directly (open them, click, type, navigate). Do NOT fake it with AppleScript, osascript, or other GUI-scripting shortcuts.

        You will not be able to ask me follow-up questions to clarify: in this harness, the moment you stop responding I see the task attempt as completed. So don't stop to ask trivial follow-up questions. Either do the task, or if it's genuinely too ambiguous to act on, just don't — say what was unclear instead. No follow-up questions.
        \(contextLine)
        For context about me, my knowledge base is a folder of markdown files at '\(VaultGenerator.vaultRoot.path)'. When you need it, read it directly with your shell/file tools — `ls`, `cat`, and `grep` the .md files. Do NOT open it in Obsidian or any GUI app to read it.
        """
    }
}
