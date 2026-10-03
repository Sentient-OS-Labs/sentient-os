//
//  ClaudeCLI.swift
//  Sentient OS macOS
//
//  The `claude -p` engine — Claude Code as the frontier-model harness, the parallel spine to
//  CodexCLI (the user's own Claude subscription powers Sentient the way ChatGPT does through
//  codex). Deliberately a CONCRETE sibling, not a protocol: it speaks the same types
//  (CodexCLI.Invocation in, CodexCLI.Envelope out, CodexCLI.CLIError thrown) and rides the same
//  engine-neutral process plumbing (CodexCLI.executeAsync / executeStreaming), so every caller
//  goes through FrontierRun's one dispatch switch and nothing else changes shape.
//
//  The dialect map (codex → claude):
//   - `--json` JSONL            → `--output-format stream-json --verbose`; the last line is a
//                                 `result` object (result text, session_id, is_error, usage)
//   - `--output-schema <file>`  → `--json-schema <inline>` (validated; answer in structured_output)
//   - `-s read-only`            → `--permission-mode dontAsk` + read-only tool set
//   - `-s workspace-write`      → `--permission-mode acceptEdits`, cwd = the staging dir
//   - `--dangerously-bypass-…`  → `--dangerously-skip-permissions` (computer use only, same law)
//   - `--ignore-user-config`    → `--setting-sources "" --disable-slash-commands` always, plus
//                                 `--strict-mcp-config` when the run must be fully hermetic
//   - usage-limit string scrape → structured `rate_limit_event` (resetsAt!) + marker fallback
//   - `exec resume <sid>`       → `--resume <sid>`
//
//  Key methods:
//   - locateBinary() / install(onLine:) / update(onLine:) / installedVersion
//   - startLogin / loginStatus   → `claude auth login` (browser OAuth) + ClaudeAuth's status read
//   - validate(force:)           → Availability (binary + login; no model tokens burned)
//   - run(_:)                    → Envelope (blocking stream-json mode)
//   - Computer use runs through CodexCLI and ClaudeSubscriptionBridge (official Claude login).
//
//  Doc: Documentation - Cloud - ClaudeCLI (the claude -p engine).md
//

import Foundation

actor ClaudeCLI {

    /// One shared instance so the per-launch availability cache is app-wide.
    static let shared = ClaudeCLI()

    // MARK: Models

    /// Claude Code model IDs: Opus and Sonnet are pinned to 5.5; Haiku keeps its alias.
    enum Model: String, Sendable {
        case opus = "claude-opus-5-5" // the heavy legs: vault build/update, proactive research
        case sonnet = "claude-sonnet-5-5" // everything else (the gpt-6-sol seat)
        case haiku     // the light tier (the gpt-6-luna seat)
    }

    /// The ONE model-resolution choke point for the Claude engine — the backendTuned twin.
    /// Tier map: astra/sol/terra → sonnet, luna → haiku; a caller that earns Opus says so explicitly
    /// (Invocation.claudeModel — the vault and research legs). Pro plans downshift opus → sonnet
    /// (Pro's Opus window is tiny; the terra-downshift twin). Effort rides through 1:1 — codex's
    /// low/medium/high/xhigh are exactly Claude Code's `--effort` values.
    static func tuned(for inv: CodexCLI.Invocation) -> (modelID: String, effortArg: String) {
        var model: Model = inv.claudeModel ?? {
            switch inv.model {
            case .gpt6astra, .gpt6sol, .gpt56terra: return .sonnet
            case .gpt6luna: return .haiku
            }
        }()
        if model == .opus, ClaudeAuth.isPro { model = .sonnet }
        return (model.rawValue, inv.effort.rawValue)
    }

    /// The computer-use pair: the Speed slider's Claude mapping, plus the same Pro downshift.
    static func agentTuned() -> (modelID: String, effortArg: String) {
        let (m, effort) = ComputerUseSpeed.current.claudeModelAndEffort
        var model = m
        if model == .opus, ClaudeAuth.isPro { model = .sonnet }
        return (model.rawValue, effort.rawValue)
    }

    // MARK: The hosted connectors (claude.ai Gmail / Google Calendar)

    /// The permission rules for the claude.ai connectors. Ground truth (measured 2026-08-23 on
    /// this codebase's first linked account): headless, NOTHING approves a connector tool call
    /// except an explicit allow rule — `auto` mode denies them too. So connector READ runs
    /// pre-approve exactly the read tools, by name, fail-closed: a tool Anthropic adds or
    /// renames stays denied until it's curated here (a probe reading NO is visible; a stray
    /// write would not be).
    enum ConnectorTools {
        /// The claude.ai Gmail connector's read-only tools — the full 28-tool surface was
        /// captured live 2026-08-23; these five are everything that doesn't mutate (the rest is
        /// send/reply/forward/draft/label/spam/trash territory and stays denied on read runs).
        static let gmailReads = ["get_message", "get_thread", "list_drafts", "list_labels",
                                 "search_threads"].map { "mcp__claude_ai_Gmail__\($0)" }

        /// The claude.ai Google Calendar connector's read-only tools — the full 9-tool surface
        /// was captured live 2026-08-23 (suggest_time only computes free slots; the other four
        /// are create/update/delete/RSVP and stay denied on read runs).
        static let calendarReads = ["get_event", "list_calendars", "list_events",
                                    "search_events", "suggest_time"]
            .map { "mcp__claude_ai_Google_Calendar__\($0)" }

        #if DEBUG
        /// Ground truth for the retained connector classification fixture.
        static let gmailWriteDenies = ["apply_sensitive_message_label",
                                       "apply_sensitive_thread_label", "create_draft",
                                       "create_filter", "create_label", "delete_filter",
                                       "delete_label", "forward", "label_message",
                                       "label_thread", "mark_message_spam", "mark_thread_spam",
                                       "reply", "send_message", "trash_message", "trash_thread",
                                       "unlabel_message", "unlabel_thread",
                                       "unmark_message_spam", "unmark_thread_spam",
                                       "untrash_message", "untrash_thread", "update_draft",
                                       "update_label", "update_message_labels"]
            .map { "mcp__claude_ai_Gmail__\($0)" }
        #endif
    }

    // MARK: Environment

    /// Kill switches for EVERY claude spawn: their auto-updater (ours runs the updates) and
    /// their telemetry and error reporting (never on a Sentient user's machine on our behalf).
    /// Merged over the sanitized/rich env by the shared plumbing.
    /// ⚠️ CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC must NEVER be "1" here: Claude Code counts
    /// the claude.ai CONNECTOR FETCH as non-essential traffic, so the flag starts every run
    /// connector-blind and the Gmail/Calendar probes read an honest-but-wrong NO [FIELD-FOUND
    /// 2026-08-23, the first live connector link]. It's pinned to "" instead: the spawn env
    /// inherits the app's, so a parent Claude Code session exporting =1 (dev shells,
    /// self-tests) would otherwise blind every child run the same way. Empty reads as unset;
    /// any non-empty value, even "0", reads as set (both measured 2026-08-23).
    static let baseEnv: [String: String] = [
        "DISABLE_AUTOUPDATER": "1",
        "DISABLE_TELEMETRY": "1",
        "DISABLE_ERROR_REPORTING": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "",
    ]

    static func environment(for invocation: CodexCLI.Invocation) -> [String: String] {
        var environment = baseEnv
        if invocation.mcpAttachServer != nil || invocation.mcpActionServer != nil || !invocation.mcpReadConnectors.isEmpty {
            // Headless connector work needs a settled tool surface before its first query.
            // Keep the wait bounded; failed connections still fail closed in the readers.
            environment["MCP_CONNECTION_NONBLOCKING"] = "0"
            environment["MCP_CONNECT_TIMEOUT_MS"] = "30000"
        }
        if invocation.mcpAttachServer != nil || invocation.mcpActionServer == "slack"
            || (invocation.connectorOnlyRead && !invocation.mcpReadConnectors.isEmpty)
            || Microsoft365Connector.contains(invocation.mcpAttachServer ?? "") || Microsoft365Connector.contains(invocation.mcpActionServer ?? "")
            || invocation.mcpReadConnectors.contains(where: Microsoft365Connector.contains) {
            // Inventory must inspect every schema. Source reads expose only their small
            // reviewed subset, so deferred tool search adds cost and can hide that subset.
            environment["ENABLE_TOOL_SEARCH"] = "false"
        }
        return environment
    }

    // MARK: Discovery

    private static let pathCacheKey = "claudecli.binaryPath"

    /// Where Anthropic's official installer puts the native binary — the same managed-binary
    /// convention as codex. The ONE copy Sentient installs and keeps current.
    static let managedBinaryPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/claude"

    /// Is the binary every run resolves to OUR managed install (vs. the user's own brew/npm
    /// claude)? The daily updater only ever touches the managed copy.
    static var usingManagedBinary: Bool { locateBinary() == managedBinaryPath }

    /// The managed install first (unconditionally), then cache, known locations, the nvm scan
    /// (`npm i -g @anthropic-ai/claude-code` under nvm), then a login-shell `which` — the exact
    /// codex discovery ladder pointed at `claude`.
    static func locateBinary() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        if fm.isExecutableFile(atPath: managedBinaryPath) { return managedBinaryPath }
        if let cached = UserDefaults.standard.string(forKey: pathCacheKey),
           fm.isExecutableFile(atPath: cached) {
            return cached
        }
        var known = [
            "\(home)/.claude/local/claude",    // older native installs
            "/opt/homebrew/bin/claude",        // brew / npm -g (Apple Silicon)
            "/usr/local/bin/claude",
        ]
        let nvmBin = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmBin) {
            known += versions.sorted(by: >).map { "\(nvmBin)/\($0)/bin/claude" }
        }
        let found = known.first(where: { fm.isExecutableFile(atPath: $0) })
            ?? CodexCLI.whichViaLoginShell("which claude")
        if let found { UserDefaults.standard.set(found, forKey: pathCacheKey) }
        return found
    }

    // MARK: Install

    /// Install Claude Code via Anthropic's official installer (`claude.ai/install.sh` — verified
    /// fully non-interactive when piped; refuses sudo; drops the binary at `~/.local/bin/claude`).
    /// Same resilience posture as the codex installer: outer curl fails fast on a dead link, the
    /// budget is generous for a slow one. Every pipeline stage must succeed, and the managed
    /// binary must report a valid version afterward. Existing installs use update(onLine:).
    static func install(onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        let pipeline = #"curl -fsSL --connect-timeout 30 --max-time 60 https://claude.ai/install.sh | bash"#
        let out = try await CodexCLI.executeStreaming(binary: "/bin/bash", args: ["-o", "pipefail", "-c", pipeline],
                                                      timeout: 900, extraEnv: baseEnv, onLine: onLine)
        UserDefaults.standard.removeObject(forKey: pathCacheKey)   // force a fresh discovery scan
        guard out.status == 0 else {
            throw SetupError.failed("Claude Code couldn't be installed. Check your connection and try again.")
        }
        guard FileManager.default.isExecutableFile(atPath: managedBinaryPath),
              let version = await installedVersion(binary: managedBinaryPath),
              await isRunnable(binary: managedBinaryPath) else {
            throw SetupError.failed("The installed Claude Code could not be verified. Try again.")
        }
        return version
    }

    enum SetupError: LocalizedError {
        case failed(String)
        var errorDescription: String? { switch self { case .failed(let message): return message } }
    }

    /// The CLI owns release-channel and package-manager policy. `DISABLE_AUTOUPDATER` stops
    /// background updates only; explicit `claude update` still works (verified on 2.1.246/277).
    /// Exit zero alone is insufficient: disabled updates can also exit zero, and a custom
    /// launcher can keep selecting the old version after the updater installs a new one.
    static func update(onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let binary = locateBinary() else { throw SetupError.failed("Claude Code is not installed.") }
        let out = try await CodexCLI.executeStreaming(binary: binary, args: ["update"],
                                                      timeout: 900, extraEnv: baseEnv, onLine: onLine)
        UserDefaults.standard.removeObject(forKey: pathCacheKey)
        guard out.status == 0 else {
            throw SetupError.failed("Claude Code couldn't be updated. Check your connection, or run claude update in Terminal, then try again.")
        }
        let reported = reportedUpdateVersion(in: out.stdout)
        // Package-managed installs have a documented success line without a version number.
        let packageCurrent = out.stdout.components(separatedBy: .newlines)
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Claude is up to date!" }
        guard reported != nil || packageCurrent else {
            throw SetupError.failed("Claude Code did not confirm an update. Run claude update in Terminal, then try again.")
        }
        guard let version = await installedVersion(), await isRunnable() else {
            throw SetupError.failed("Claude Code could not be verified after updating. Try again.")
        }
        if let reported, CodexCLI.isNewer(reported, than: version) {
            throw SetupError.failed("Claude Code updated to \(reported), but Sentient still finds \(version). Check your Claude installation, then try again.")
        }
        return version
    }

    /// Native-updater completion messages, including its explicit minimum-version hold.
    /// Unknown output is retryable, never silently treated as success because a binary survives.
    static func reportedUpdateVersion(in output: String) -> String? {
        let patterns = [
            #"(?m)^Successfully updated from \S+ to version ([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)\s*$"#,
            #"(?m)^Claude Code is up to date \(([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)\)\s*$"#,
            #"(?m)^The (?:stable|latest) channel is at \S+, which is below your minimumVersion setting \(\S+\)\. Staying on ([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)\.\s*$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let range = Range(match.range(at: 1), in: output) else { continue }
            return String(output[range])
        }
        return nil
    }

    /// Confirm the selected (or explicitly supplied) executable answers --help.
    static func isRunnable(binary: String? = nil) async -> Bool {
        guard let bin = binary ?? locateBinary() else { return false }
        guard let out = try? await CodexCLI.executeAsync(binary: bin, args: ["--help"],
                                                         stdinText: nil, cwd: nil, timeout: 10,
                                                         extraEnv: baseEnv) else { return false }
        return out.status == 0 && !out.stdout.isEmpty
    }

    /// The installed version ("2.1.233 (Claude Code)" → "2.1.233"), or nil.
    static func installedVersion(binary: String? = nil) async -> String? {
        guard let bin = binary ?? locateBinary() else { return nil }
        guard let out = try? await CodexCLI.executeAsync(binary: bin, args: ["--version"],
                                                         stdinText: nil, cwd: nil, timeout: 10,
                                                         extraEnv: baseEnv),
              out.status == 0 else { return nil }
        guard let version = out.stdout.split(whereSeparator: \.isWhitespace).first.map(String.init),
              version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$"#,
                            options: .regularExpression) != nil else { return nil }
        return version
    }

    // MARK: Login

    /// Begin the interactive login: `claude auth login` opens the browser to the Anthropic
    /// sign-in and self-exits once the OAuth callback lands (credentials go to the user's
    /// Keychain — shared with their own Claude Code, by decision). Same contract as
    /// CodexCLI.startLogin: returns the running Process, never awaited to completion.
    static func startLogin(onLine: @escaping @Sendable (String) -> Void) throws -> Process {
        guard let bin = locateBinary() else { throw CodexCLI.CLIError.notAvailable(.notInstalled) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["auth", "login"]
        var env = CodexCLI.richEnvironment(binDir: (bin as NSString).deletingLastPathComponent)
        env.merge(baseEnv) { _, new in new }
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        for (pipe, prefix) in [(outPipe, ""), (errPipe, "stderr: ")] {
            DispatchQueue.global(qos: .utility).async {
                var buf = Data()
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buf.append(chunk)
                    while let nl = buf.firstIndex(of: 0x0A) {
                        onLine(prefix + String(decoding: buf[..<nl], as: UTF8.self))
                        buf = Data(buf[buf.index(after: nl)...])
                    }
                }
                if !buf.isEmpty { onLine(prefix + String(decoding: buf, as: UTF8.self)) }
            }
        }
        do { try proc.run() } catch { throw CodexCLI.CLIError.launchFailed("\(error)") }
        return proc
    }

    /// The login ground truth (`claude auth status`, via ClaudeAuth so the plan cache refreshes
    /// with every check).
    static func loginStatus() async -> Bool {
        await ClaudeAuth.refresh().loggedIn
    }

    // MARK: Validation

    private var cachedAvailability: CodexCLI.Availability?
    private var cachedVersion: String?

    /// Is the Claude engine usable — binary on disk AND logged in? `claude auth status` answers
    /// both without burning a model token (unlike the codex ping, which must round-trip a model:
    /// codex's auth.json can exist while broken; Claude's status command IS the ground truth).
    /// Only a GOOD verdict is cached — a failed probe re-checks on every call (the codex law:
    /// a login fixed mid-session is seen by the very next retry).
    func validate(force: Bool = false) async -> CodexCLI.Availability {
        if !force, let cachedAvailability { return cachedAvailability }
        guard let bin = Self.locateBinary() else {
            cachedAvailability = nil
            Log("claude ping: notInstalled")
            return .notInstalled
        }
        if cachedVersion == nil { cachedVersion = await Self.installedVersion() }
        let t0 = Date()
        let status = await ClaudeAuth.refresh()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if status.loggedIn {
            let result = CodexCLI.Availability.available(path: bin)
            cachedAvailability = result
            Log("claude ping: available plan=\(status.plan ?? "unknown") in \(ms)ms")
            return result
        }
        cachedAvailability = nil
        Log("claude ping: notWorking:not_logged_in in \(ms)ms")
        return .notWorking("Not logged in to Claude Code — sign in with your Claude account.")
    }

    // MARK: Run (the structured spine)

    /// Execute one headless call and return the parsed envelope — the CodexCLI.run twin.
    /// Throws the same typed errors, notably `.usageLimit` carrying the session id (the
    /// `--resume` handle) so callers reschedule/resume exactly as they do on codex.
    func run(_ invocation: CodexCLI.Invocation,
             onLine: (@Sendable (String) -> Void)? = nil) async throws -> CodexCLI.Envelope {
        let (modelID, effortArg) = Self.tuned(for: invocation)
        let t0 = Date()
        do {
            return try await runInner(invocation, modelID: modelID, effortArg: effortArg, onLine: onLine)
        } catch {
            if !Task.isCancelled {   // a cancelled Task is the user's STOP, not a defect
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                Log("claude exec: \(CodexFailureReason.classify(error).rawValue) feature=\(invocation.feature) in \(ms)ms")
                emitClaudeFailure(event: "claude.failure", error, feature: invocation.feature,
                                  modelID: modelID, effort: effortArg,
                                  resumed: invocation.resumeSessionID != nil,
                                  durationMS: ms, timeoutS: Int(invocation.timeout), diag: invocation.diag)
            }
            throw error
        }
    }

    private func runInner(_ invocation: CodexCLI.Invocation, modelID: String, effortArg: String,
                          onLine: (@Sendable (String) -> Void)? = nil) async throws -> CodexCLI.Envelope {
        var invocation = invocation
        // Screenshots on run(): no `-i` flag exists on claude — the paths join the prompt and
        // the model Reads them. Read is on every run() tool surface (the readOnly tool list
        // names it; the other paths keep the default surface), so no tool change is needed.
        if !invocation.imagePaths.isEmpty {
            invocation.prompt += Self.screenshotsBlock(invocation.imagePaths)
        }
        // Same pre-spawn guard as codex (piped stdin caps at 10 MB on claude, but every prompt
        // path is byte-budgeted to the shared 950 KB anyway — a throw here is the same canary).
        if invocation.prompt.utf8.count > CodexCLI.promptByteCap {
            throw CodexCLI.CLIError.inputTooLarge(chars: invocation.prompt.utf8.count)
        }
        let availability = await validate()
        guard case .available(let bin) = availability else {
            throw CodexCLI.CLIError.notAvailable(availability)
        }

        let started = Date()
        Log("claude exec: start feature=\(invocation.feature) model=\(modelID) effort=\(effortArg) resume=\(invocation.resumeSessionID != nil) sandbox=\(invocation.sandbox.rawValue) prompt_kb=\(invocation.prompt.utf8.count / 1024) trigger=\(CodexTrigger.current.rawValue)")
        let stdoutLine: (@Sendable (String) -> Void)? = onLine.map { sink in
            { @Sendable raw in for s in Self.humanLines(fromStreamJSON: raw) { sink(s) } }
        }
        var args = try Self.arguments(for: invocation, modelID: modelID, effortArg: effortArg)
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["LAB_CLAUDE_DEBUG_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            args += ["--debug-file", directory.appending(path: "claude-\(UUID().uuidString).log").path]
        }
        #endif
        let out = try await CodexCLI.executeAsync(binary: bin,
                                                  args: args,
                                                  stdinText: invocation.prompt,
                                                  cwd: invocation.cwd,
                                                  timeout: invocation.timeout,
                                                  extraEnv: Self.environment(for: invocation),
                                                  onStdoutLine: stdoutLine)
        let env = try Self.parseEnvelope(out, durationMS: Int(Date().timeIntervalSince(started) * 1000))
        Log("claude exec: ok feature=\(invocation.feature) in \(env.durationMS ?? -1)ms turns=\(env.numTurns ?? -1) out=\(env.outputTokens ?? -1)")
        return env
    }

    /// The Invocation → argv translation — the `arguments(for:)` twin, speaking Claude Code's
    /// dialect. Every run is hermetic against the user's own Claude Code customizations
    /// (`--setting-sources ""` skips their settings and hooks; `--disable-slash-commands` keeps
    /// skills from expanding inside OUR prompts); `includeUserConfig=false` additionally seals
    /// off ALL MCP servers (theirs and claude.ai connectors) with `--strict-mcp-config`.
    ///
    /// The connector run recipes, Claude column (the README table in the Step 1 plan; the
    /// codex column lives in CodexCLI.arguments). Ground truth for all three: headless
    /// connector calls are approved by allow rules and NOTHING else (`auto` denies them too),
    /// and the `allowedMcpServers` wall applies even under `--setting-sources ""` (both
    /// measured 2026-08-23):
    ///  ┌─────────────────┬────────────────────────────────────────────────────────────────┐
    ///  │ UNATTENDED READ │ dontAsk + allow EXACTLY the registry's read tools per slug     │
    ///  │ mcpReadConnectors│ (curated list where one exists, else the classifier's reads); │
    ///  │                 │ wall = those servers' URLs only. A slug with no read list or   │
    ///  │                 │ no known URL throws — fail-closed, never a silent wider run.   │
    ///  ├─────────────────┼────────────────────────────────────────────────────────────────┤
    ///  │ FIRED TASK      │ dontAsk + allow `<prefix>*` for the ONE routed server; wall =  │
    ///  │ mcpActionServer │ that server's URL only; its destructive tools denied by name.  │
    ///  │                 │ Requires a classification (the deny list needs the inventory); │
    ///  │                 │ unclassified throws, and 1.5's narrated fallback to computer   │
    ///  │                 │ use absorbs the refusal. Constructive writes are LIVE: these   │
    ///  │                 │ runs are user-fired, one declared task (README decision #13).  │
    ///  ├─────────────────┼────────────────────────────────────────────────────────────────┤
    ///  │ ATTACH          │ wall only, ZERO allow rules — the classifier's inventory read  │
    ///  │ mcpAttachServer │ (the run calls no tools; listing your own needs no approval).  │
    ///  ├─────────────────┼────────────────────────────────────────────────────────────────┤
    ///  │ COMPUTER USE    │ CodexCLI + ClaudeSubscriptionBridge; separate from this       │
    ///  │                 │ structured Claude runner and its connector policy.           │
    ///  └─────────────────┴────────────────────────────────────────────────────────────────┘
    /// Internal (not private) so the connector lab's argv command can print recipes without
    /// spawning (Self Tests - Temp; may return to private when the lab is deleted at Step 4).
    static func arguments(for inv: CodexCLI.Invocation, modelID: String,
                          effortArg: String) throws -> [String] {
        let inv = inv.canonicalConnectorTargets()
        let direct = DirectMCPRuntime.current
        let requestedDirect = Set((inv.mcpReadConnectors + [inv.mcpActionServer].compactMap { $0 }).filter { $0.hasPrefix("direct-") })
        guard requestedDirect.isSubset(of: Set(direct.map(\.requestedTarget))) else { throw DirectMCPError.policyUnavailable }
        if inv.mcpReadToolNames != nil, inv.mcpReadConnectors.count != 1 {
            throw CodexCLI.CLIError.notAvailable(.notWorking("read-tool narrowing requires one connector"))
        }
        if inv.connectorOnlyRead {
            guard !inv.bypassApprovals, inv.sandbox == .readOnly, !inv.webSearch,
                  inv.mcpActionServer == nil, !inv.mcpReadConnectors.isEmpty || inv.mcpAttachServer != nil else {
                throw CodexCLI.CLIError.notAvailable(.notWorking("invalid connector-only read configuration"))
            }
        }
        assert([inv.mcpActionServer != nil, !inv.mcpReadConnectors.isEmpty,
                inv.mcpAttachServer != nil].filter { $0 }.count <= 1,
               "the connector recipe fields are mutually exclusive")
        assert(!(inv.bypassApprovals && (inv.mcpActionServer != nil || !inv.mcpReadConnectors.isEmpty)),
               "the sandboxed connector recipes never bypass approvals")
        assert((inv.mcpActionServer == nil && inv.mcpReadConnectors.isEmpty && inv.mcpAttachServer == nil)
               || inv.includeUserConfig,
               "the recipes need includeUserConfig: the strict wall blocks the connector fetch")
        assert((inv.mcpActionServer == nil && inv.mcpReadConnectors.isEmpty)
               || inv.sandbox == .readOnly,
               "connector recipe runs are read-only sandboxed (connector tools ride MCP, not files)")

        // Resolve and validate the recipe fields ONCE, fail-closed, before any argv exists.
        var recipeWallURLs: [String] = []
        var recipeAllows: [String] = []
        var recipeDenies: [String] = []
        if let slug = inv.mcpAttachServer {
            guard let url = ConnectorRegistry.server(for: slug)?.claudeServerURL else {
                throw CodexCLI.CLIError.notAvailable(
                    .notWorking("connector \(slug) has no known claude.ai server"))
            }
            recipeWallURLs = [url]
        } else if let slug = inv.mcpActionServer, !slug.hasPrefix("direct-") {
            guard let resolved = ConnectorRegistry.server(for: slug),
                  let url = resolved.claudeServerURL,
                  let prefix = resolved.claudeToolPrefix else {
                throw CodexCLI.CLIError.notAvailable(
                    .notWorking("connector \(slug) has no known claude.ai server"))
            }
            guard ConnectorRegistry.isClassified(slug) else {
                throw CodexCLI.CLIError.notAvailable(
                    .notWorking("connector \(slug) is not classified yet"))
            }
            recipeWallURLs = [url]
            recipeAllows = slug == "slack"
                ? SlackConnector.actionTools(backend: .claude, operation: inv.slackOperation ?? .write).map { prefix + $0 }
                : [prefix + "*"]
            recipeDenies = ConnectorRegistry.destructiveToolNames(slug: slug)
            if slug == OutlookMailConnector.slug {
                guard let operation = inv.outlookOperation else { throw MCPSource.MCPError.noReadSurface(slug: slug) }
                recipeAllows = OutlookMailConnector.actionTools(.claude, operation: operation).map { prefix + $0 }
                recipeDenies = OutlookMailConnector.claudeCategories.keys.map { prefix + $0 }.filter { !recipeAllows.contains($0) }.sorted()
            }
            if slug == OutlookCalendarConnector.slug {
                guard let operation = inv.outlookCalendarOperation else { throw MCPSource.MCPError.noReadSurface(slug: slug) }
                recipeAllows = OutlookCalendarConnector.actionTools(.claude, operation: operation).map { prefix + $0 }
                recipeDenies = Microsoft365Connector.denied(except: recipeAllows)
            }
            if slug == "slack" {
                recipeDenies = SlackConnector.categories(backend: .claude).keys.map { prefix + $0 }
                    .filter { !recipeAllows.contains($0) }.sorted()
            }
        } else {
            for slug in inv.mcpReadConnectors where !slug.hasPrefix("direct-") {
                let available = ConnectorRegistry.readToolNames(slug: slug)
                let prefix = ConnectorRegistry.server(for: slug)?.claudeToolPrefix ?? ""
                let reads = inv.mcpReadToolNames.map { names in names.map { prefix + $0 } } ?? available
                guard Set(reads).isSubset(of: Set(available)) else {
                    throw CodexCLI.CLIError.notAvailable(.notWorking("read-tool narrowing cannot widen the curated policy"))
                }
                guard !reads.isEmpty,
                      let url = ConnectorRegistry.server(for: slug)?.claudeServerURL else {
                    throw CodexCLI.CLIError.notAvailable(
                        .notWorking("connector \(slug) has no read allow-list"))
                }
                recipeWallURLs.append(url)
                recipeAllows += reads
                if slug == "slack" {
                    // DontAsk remains the permission boundary. Removing the reviewed complement
                    // also avoids paying for unrelated canvas/list/upload schemas on every read.
                    recipeDenies += SlackConnector.categories(backend: .claude).keys
                        .map { prefix + $0 }.filter { !reads.contains($0) }.sorted()
                }
            }
        }
        if inv.mcpReadConnectors.contains(where: Microsoft365Connector.contains) {
            recipeDenies += Microsoft365Connector.denied(except: recipeAllows)
        }
        recipeAllows += direct.flatMap(\.allAllowed)
        recipeDenies += direct.flatMap(\.denied)

        var args = ["-p",
                    "--output-format", "stream-json", "--verbose",
                    "--model", modelID,
                    "--effort", effortArg,
                    "--setting-sources", "",
                    "--disable-slash-commands"]
        if let sid = inv.resumeSessionID { args += ["--resume", sid] }
        if !direct.isEmpty {
            if recipeWallURLs.isEmpty { args += ["--strict-mcp-config"] }
            args += ["--mcp-config", try DirectMCPRuntime.claudeConfig(direct),
                     "--settings", try DirectMCPRuntime.claudeSettings(direct, hostedURLs: recipeWallURLs)]
        } else if !inv.includeUserConfig || inv.toolsDisabled {
            args += ["--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
        } else if !recipeWallURLs.isEmpty {
            // The recipe wall: ONLY the recipe's server(s) may load — the user's own MCP
            // servers and every other connector are blocked before their tools reach the model.
            let base = Self.mcpServerAllowSettings(serverURLs: recipeWallURLs)
            let settings = inv.mcpActionServer == "slack"
                ? try SlackToolPolicy.claudeSettings(base, operation: inv.slackOperation ?? .write,
                                                    runID: inv.slackRunID, expectedMessage: inv.slackExpectedMessage) : base
            args += ["--settings", settings]
        }

        if inv.includesOutlookMail || inv.calendarPolicy != nil {
            guard let index = args.lastIndex(of: "--settings"), index + 1 < args.count else { throw MCPSource.MCPError.noReadSurface(slug: OutlookMailConnector.slug) }
            args[index + 1] = try OutlookToolPolicy.claudeSettings(args[index + 1],
                operation: inv.mcpActionServer == nil ? .read : (inv.outlookOperation ?? .read), runID: inv.outlookRunID ?? UUID(),
                mode: inv.outlookReadMode, window: inv.outlookReadWindow, expectedMessage: inv.outlookExpectedMessage,
                expectedRecipients: inv.outlookExpectedRecipients, calendar: inv.calendarPolicy, includesMail: inv.includesOutlookMail)
        }

        var allowed = recipeAllows
        var disallowed = recipeDenies

        // The permission recipe — codex's Seatbelt tiers in Claude Code's dialect:
        //  · readOnly        → dontAsk (auto-deny anything not pre-approved) + read-only tools.
        //  · workspaceWrite  → acceptEdits, cwd = the staging dir (edits auto-approved there).
        //  · approveConnectorWrites → dontAsk + every MCP tool pre-approved for this ONE
        //    app-authored, single-declared-action run — the same scope codex's `apps._default`
        //    approve carried. Since task 1.7 this survives only as the executor's fallback for
        //    an UNCLASSIFIED chip fire (gmail/calendar in the minutes after an update, before
        //    the classifier sweep lands) — byte-identical to the shipped fire posture;
        //    classified fires ride mcpActionServer's server-scoped approval instead.
        //  · the recipe fields → the table above (allows/denies merged in via recipeAllows).
        //    (Proactive research rides mcpReadConnectors since 1.7 — the curated/classified
        //    read allows; no write rule exists in the run, so "never fire" stays structural.)
        var skippedPermissions = false
        if inv.bypassApprovals {
            // The codex bypass twin (the executor's connector self-heal retry rides this in
            // run(); computer use has its own spine). Same law: trusted, app-authored,
            // single-declared-action prompts ONLY.
            args += ["--dangerously-skip-permissions"]
            skippedPermissions = true
        } else {
            let mode: String
            if inv.configOverrides == CodexCLI.Invocation.approveConnectorWrites {
                mode = "dontAsk"
                allowed.append("mcp__*")
            } else {
                switch inv.sandbox {
                case .readOnly: mode = "dontAsk"
                case .workspaceWrite: mode = "acceptEdits"
                }
            }
            args += ["--permission-mode", mode]
        }

        if inv.sandbox == .readOnly, !skippedPermissions {
            // Read-only parity: no Edit/Write in the tool surface at all; dontAsk additionally
            // auto-approves only Claude Code's read-only Bash command set.
            var tools = inv.connectorOnlyRead || inv.toolsDisabled || Microsoft365Connector.contains(inv.mcpActionServer ?? "") ? [] : ["Bash", "Glob", "Grep", "Read"]
            if inv.mcpAttachServer != nil || inv.mcpActionServer != nil || !inv.mcpReadConnectors.isEmpty {
                tools.append("WaitForMcpServers")
                allowed.append("WaitForMcpServers")
            }
            if inv.webSearch { tools += ["WebSearch", "WebFetch"] }
            args += ["--tools", tools.joined(separator: ",")]
        }
        for dir in inv.addDirs { args += ["--add-dir", dir] }

        if inv.webSearch { allowed += ["WebSearch", "WebFetch"] }
        else { disallowed += ["WebSearch", "WebFetch"] }

        if !allowed.isEmpty { args += ["--allowedTools", allowed.joined(separator: ",")] }
        if !disallowed.isEmpty { args += ["--disallowedTools", disallowed.joined(separator: ",")] }
        if let schema = inv.outputSchema { args += ["--json-schema", schema] }
        return args
    }

    /// `{"allowedMcpServers":[{"serverName":"cua_driver"},{"serverUrl":"https://host/*"},…]}` —
    /// named entries first (the cua daemon on computer-use runs), then one origin glob
    /// (scheme + host) per URL, matching the shipped Gmail wall's shape: an exact-URL entry
    /// would not match the endpoint's subpaths. A string that won't parse as a URL rides
    /// through as-is; a JSON serialization failure walls out EVERYTHING (empty allowlist) —
    /// never fail open.
    static func mcpServerAllowSettings(serverURLs: [String], serverNames: [String] = []) -> String {
        var entries: [[String: String]] = serverNames.map { ["serverName": $0] }
        for serverURL in serverURLs {
            var glob = serverURL
            if let url = URL(string: serverURL), let scheme = url.scheme, let host = url.host {
                glob = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")/*"
            }
            entries.append(["serverUrl": glob])
        }
        let settings: [String: Any] = ["allowedMcpServers": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: settings,
                                                     options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"allowedMcpServers":[]}"#
        }
        return json
    }

    // Screenshots for structured Claude runs. Computer tasks enter CodexCLI via FrontierRun.
    static func screenshotsBlock(_ paths: [String]) -> String {
        "\n\nSCREENSHOTS — what the user sees right now (main display first). "
            + "Read each file with the Read tool BEFORE acting:\n"
            + paths.map { "- \($0)" }.joined(separator: "\n")
    }

    // MARK: Stream-json parsing

    /// Claude's usage-limit wording (the subscription windows) plus the generic family — checked
    /// against a failed run's error text, exactly like codex's marker scan, but here the
    /// structured `rate_limit_event` (persisted below) usually already told us the reset time.
    private static let usageLimitMarkers = ["hit your session limit", "hit your weekly limit",
                                            "hit your opus limit", "usage limit", "rate limit",
                                            "limit resets", "too many requests",
                                            "out of credits", "credit balance"]

    /// The latest `rate_limit_event` — persisted so the scheduler and the morning caution can
    /// say WHEN the window resets instead of guessing. Production keys.
    static let rateLimitResetsAtKey = "claude.rateLimit.resetsAt"
    static let rateLimitTypeKey = "claude.rateLimit.type"

    private static func noteRateLimit(_ info: [String: Any]) {
        let d = UserDefaults.standard
        if let resets = info["resetsAt"] as? Double { d.set(resets, forKey: rateLimitResetsAtKey) }
        if let type = info["rateLimitType"] as? String { d.set(type, forKey: rateLimitTypeKey) }
    }

    /// Reduce the stream-json output to the shared Envelope. The stream's last line is a
    /// `result` object; `system/init` (the first line) carries the session id — so even a
    /// mid-run usage limit keeps its resume handle, the same guarantee codex gives.
    static func parseEnvelope(_ out: CodexCLI.ExecResult, durationMS: Int) throws -> CodexCLI.Envelope {
        var sessionID: String?
        var resultObj: [String: Any]?

        for line in out.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "system":
                if sessionID == nil { sessionID = obj["session_id"] as? String }
            case "rate_limit_event":
                if let info = obj["rate_limit_info"] as? [String: Any] { noteRateLimit(info) }
            case "result":
                resultObj = obj
            default:
                break
            }
        }

        let isError = (resultObj?["is_error"] as? Bool) ?? true
        var text = (resultObj?["result"] as? String) ?? ""
        // `--json-schema` runs land the answer in structured_output — serialize it back to a
        // JSON string so Envelope.jsonResult (the seam every schema consumer decodes from)
        // works unchanged.
        if let structured = resultObj?["structured_output"],
           JSONSerialization.isValidJSONObject(structured) || structured is [Any],
           let data = try? JSONSerialization.data(withJSONObject: structured,
                                                  options: [.withoutEscapingSlashes]),
           let json = String(data: data, encoding: .utf8) {
            text = json
        }

        if out.status != 0 || isError || text.isEmpty {
            let detail = !text.isEmpty ? text
                : (out.stderr.isEmpty ? String(out.stdout.suffix(600)) : out.stderr)
            let lowered = detail.lowercased()
            if usageLimitMarkers.contains(where: { lowered.contains($0) }) {
                throw CodexCLI.CLIError.usageLimit(message: String(detail.prefix(600)),
                                                   sessionID: sessionID)
            }
            if out.status != 0 {
                throw CodexCLI.CLIError.exitFailure(code: out.status, message: String(detail.prefix(600)))
            }
            throw CodexCLI.CLIError.badEnvelope(String(detail.prefix(600)))
        }

        let usage = resultObj?["usage"] as? [String: Any]
        // Claude reports uncached input separately from cache creation/read. Normalize to
        // Envelope's total-input convention so both engines' costs are comparable.
        let totalInput = (usage?["input_tokens"] as? Int).map {
            $0 + (usage?["cache_creation_input_tokens"] as? Int ?? 0)
                + (usage?["cache_read_input_tokens"] as? Int ?? 0)
        }
        return CodexCLI.Envelope(
            result: text,
            sessionID: (resultObj?["session_id"] as? String) ?? sessionID,
            numTurns: resultObj?["num_turns"] as? Int,
            durationMS: durationMS,
            inputTokens: totalInput,
            cachedInputTokens: usage?["cache_read_input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            raw: out.stdout
        )
    }

    /// Reduce one stream-json line to short human play-by-play lines — the humanLine twin.
    /// An assistant message can carry several content blocks (text + tool calls), so this
    /// returns all of them. Thinking blocks are skipped (full extended thinking is far too
    /// verbose for a notch line); tool results and partial deltas are noise.
    static func humanLines(fromStreamJSON line: String) -> [String] {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        var lines: [String] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { lines.append(text) }
            case "tool_use":
                let name = (block["name"] as? String) ?? ""
                let input = block["input"] as? [String: Any]
                if name == "Bash" {
                    if let cmd = input?["command"] as? String, !cmd.isEmpty { lines.append("$ \(cmd)") }
                } else if name.hasPrefix("mcp__cua_driver__") {
                    lines.append("→ cua.\(name.dropFirst("mcp__cua_driver__".count))")
                } else if name.hasPrefix("mcp__claude_ai_") {
                    // Hosted-connector calls read as "→ Gmail.send_message" — the harness
                    // prefix is chrome, and the server's underscores are claude's mangling of
                    // its display name ("Google_Drive" was "Google Drive").
                    let rest = name.dropFirst("mcp__claude_ai_".count)
                    if let sep = rest.range(of: "__") {
                        let server = rest[..<sep.lowerBound].replacingOccurrences(of: "_", with: " ")
                        lines.append("→ \(server).\(rest[sep.upperBound...])")
                    } else {
                        lines.append("→ \(rest)")
                    }
                } else if name.hasPrefix("mcp__") {
                    lines.append("→ \(name.dropFirst("mcp__".count).replacingOccurrences(of: "__", with: "."))")
                } else if name == "WebSearch" {
                    lines.append((input?["query"] as? String).map { "🔎 \($0)" } ?? "🔎 searching…")
                } else if name == "Read" {
                    if let path = input?["file_path"] as? String {
                        lines.append("→ read \((path as NSString).lastPathComponent)")
                    }
                }
            default:
                break
            }
        }
        return lines
    }

    // MARK: Diagnostics

    /// The emitCodexFailure twin — same structure-only law: enum/bool/int/version values only,
    /// never claude's output, the prompt, or account material. Reuses the shared closed
    /// vocabulary (CodexFailureReason), trigger, and network snapshot; adds the Claude plan
    /// (from ClaudeAuth's cache — a closed set of plan words, same as codex's plan tag).
    private func emitClaudeFailure(event: String, _ error: Error, feature: String,
                                   modelID: String, effort: String, resumed: Bool, durationMS: Int,
                                   timeoutS: Int? = nil, diag: [String: String] = [:]) {
        let caseName: String
        let level: CrashReporting.DiagLevel
        var extra = diag
        var availability = "n/a"
        var phase = "exec"
        switch error {
        case CodexCLI.CLIError.usageLimit: return   // expected, not a defect — the caution + resume own it
        case CodexCLI.CLIError.notAvailable(let a):
            (caseName, level) = ("notAvailable", .warning)
            phase = "ping"
            switch a {
            case .notInstalled: availability = "notInstalled"
            case .notWorking:   availability = "notWorking"
            case .available:    availability = "available"
            }
        case CodexCLI.CLIError.timedOut:     (caseName, level) = ("timedOut", .warning)
        case CodexCLI.CLIError.launchFailed: (caseName, level) = ("launchFailed", .error)
        case CodexCLI.CLIError.exitFailure(let code, _):
            (caseName, level) = ("exitFailure", .error)
            extra["exit_code"] = String(code)
        case CodexCLI.CLIError.badEnvelope:  (caseName, level) = ("badEnvelope", .error)
        case CodexCLI.CLIError.inputTooLarge(let chars):
            (caseName, level) = ("inputTooLarge", .error)
            extra["prompt_chars"] = String(chars)
        default: (caseName, level) = (String(describing: type(of: error)), .error)
        }
        let reason = CodexFailureReason.classify(error)
        let net = NetworkSnapshot.shared.current
        extra["effort"] = effort
        extra["resumed"] = String(resumed)
        extra["duration_ms"] = String(durationMS)
        extra["timeout_s"] = String(timeoutS ?? -1)
        if feature == "computer" { extra["cua_driver"] = CuaDriver.version }
        CrashReporting.captureEvent(event, level: level, tags: [
            "feature": feature,
            "error": caseName,
            "model": modelID,
            "backend": "claude",
            "phase": phase,
            "availability": availability,
            "reason": reason.rawValue,
            "trigger": CodexTrigger.current.rawValue,
            "network": net.status,
            "interface": net.interface,
            "plan": ClaudeAuth.cachedPlan ?? "unknown",
            "claude_version": cachedVersion ?? "unknown",
        ], extra: extra,
           fingerprint: ["claude", feature, caseName, reason.rawValue, CodexTrigger.current.rawValue])
    }
}
