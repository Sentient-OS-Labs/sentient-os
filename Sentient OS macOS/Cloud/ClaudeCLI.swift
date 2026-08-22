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
//   - locateBinary() / install(onLine:) / installedVersion / latestReleasedVersion
//   - startLogin / loginStatus   → `claude auth login` (browser OAuth) + ClaudeAuth's status read
//   - validate(force:)           → Availability (binary + login; no model tokens burned)
//   - run(_:)                    → Envelope (blocking stream-json mode)
//   - runAgentCommand(_:)        → computer use on the cua driver (MCP eyes via --mcp-config,
//                                  CLI hands via the same shim + skill text as codex)
//
//  Doc: Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md (the reference engine;
//  the Claude engine's own doc lands once the feature is tested and confirmed).
//

import Foundation

actor ClaudeCLI {

    /// One shared instance so the per-launch availability cache is app-wide.
    static let shared = ClaudeCLI()

    // MARK: Models

    /// Claude Code model aliases — aliases on purpose (they track the recommended release, the
    /// same way our pinned codex model ids track OpenAI's lineup by hand).
    enum Model: String, Sendable {
        case opus      // the heavy legs: vault build/update, proactive research
        case sonnet    // everything else (the gpt-5.6-sol seat)
        case haiku     // the light tier (the gpt-5.6-luna seat)
    }

    /// The ONE model-resolution choke point for the Claude engine — the backendTuned twin.
    /// Tier map: sol/terra → sonnet, luna → haiku; a caller that earns Opus says so explicitly
    /// (Invocation.claudeModel — the vault and research legs). Pro plans downshift opus → sonnet
    /// (Pro's Opus window is tiny; the terra-downshift twin). Effort rides through 1:1 — codex's
    /// low/medium/high/xhigh are exactly Claude Code's `--effort` values.
    static func tuned(for inv: CodexCLI.Invocation) -> (modelID: String, effortArg: String) {
        var model: Model = inv.claudeModel ?? {
            switch inv.model {
            case .gpt56sol, .gpt56terra: return .sonnet
            case .gpt56luna: return .haiku
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

    // MARK: Environment

    /// Kill switches for EVERY claude spawn: their auto-updater (ours runs the updates), their
    /// telemetry and error reporting (never on a Sentient user's machine on our behalf), and
    /// non-essential traffic. Merged over the sanitized/rich env by the shared plumbing.
    static let baseEnv: [String: String] = [
        "DISABLE_AUTOUPDATER": "1",
        "DISABLE_TELEMETRY": "1",
        "DISABLE_ERROR_REPORTING": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    ]

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
    /// budget is generous for a slow one, and success = the binary actually present afterward,
    /// never the pipeline's exit status.
    static func install(onLine: @escaping @Sendable (String) -> Void) async throws {
        let pipeline = #"curl -fsSL --connect-timeout 30 --max-time 60 https://claude.ai/install.sh | bash"#
        let out = try await CodexCLI.executeStreaming(binary: "/bin/sh", args: ["-c", pipeline],
                                                      timeout: 900, extraEnv: baseEnv, onLine: onLine)
        UserDefaults.standard.removeObject(forKey: pathCacheKey)   // force a fresh discovery scan
        guard locateBinary() != nil else {
            let detail = out.stderr.isEmpty ? out.stdout : out.stderr
            let msg = detail.isEmpty
                ? "Claude Code not found after install; check your network connection."
                : String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
            throw CodexCLI.CLIError.exitFailure(code: out.status, message: msg)
        }
    }

    /// Ground truth for "claude is installed": run `claude --version` and see it answer.
    static func isRunnable() async -> Bool {
        guard let bin = locateBinary() else { return false }
        guard let out = try? await CodexCLI.executeAsync(binary: bin, args: ["--version"],
                                                         stdinText: nil, cwd: nil, timeout: 10,
                                                         extraEnv: baseEnv) else { return false }
        return out.status == 0 && !out.stdout.isEmpty
    }

    /// The installed version ("2.1.233 (Claude Code)" → "2.1.233"), or nil.
    static func installedVersion() async -> String? {
        guard let bin = locateBinary() else { return nil }
        guard let out = try? await CodexCLI.executeAsync(binary: bin, args: ["--version"],
                                                         stdinText: nil, cwd: nil, timeout: 10,
                                                         extraEnv: baseEnv),
              out.status == 0 else { return nil }
        return out.stdout.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    /// The newest released version, from the same endpoint the installer resolves against
    /// (`downloads.claude.ai/claude-code-releases/latest` answers the bare version string).
    static func latestReleasedVersion() async -> String? {
        guard let url = URL(string: "https://downloads.claude.ai/claude-code-releases/latest") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare semver, nothing else — a drifted endpoint shape must not become a "version".
        guard !version.isEmpty, version.count < 32,
              version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) != nil
        else { return nil }
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
        let out = try await CodexCLI.executeAsync(binary: bin,
                                                  args: Self.arguments(for: invocation,
                                                                       modelID: modelID,
                                                                       effortArg: effortArg),
                                                  stdinText: invocation.prompt,
                                                  cwd: invocation.cwd,
                                                  timeout: invocation.timeout,
                                                  extraEnv: Self.baseEnv,
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
    private static func arguments(for inv: CodexCLI.Invocation, modelID: String,
                                  effortArg: String) -> [String] {
        var args = ["-p",
                    "--output-format", "stream-json", "--verbose",
                    "--model", modelID,
                    "--effort", effortArg,
                    "--setting-sources", "",
                    "--disable-slash-commands"]
        if let sid = inv.resumeSessionID { args += ["--resume", sid] }
        if !inv.includeUserConfig {
            args += ["--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
        }

        var allowed: [String] = []
        var disallowed: [String] = []

        // The permission recipe — codex's Seatbelt tiers in Claude Code's dialect:
        //  · readOnly        → dontAsk (auto-deny anything not pre-approved) + read-only tools.
        //  · workspaceWrite  → acceptEdits, cwd = the staging dir (edits auto-approved there).
        //  · approveConnectorWrites (the executor's gmail/calendar fire) → dontAsk + every MCP
        //    tool pre-approved for this ONE app-authored, single-declared-action run — the same
        //    scope codex's `apps._default` approve carried.
        //  · claudePermissionMode (e.g. "auto" on the Gmail/Calendar READ runs) wins outright:
        //    the classifier plays the role of codex's approval chain — reads flow, a stray write
        //    gets flagged, and headless has nobody to ask so flagged means denied.
        var skippedPermissions = false
        if inv.bypassApprovals {
            // The codex bypass twin (the executor's connector self-heal retry rides this in
            // run(); computer use has its own spine). Same law: trusted, app-authored,
            // single-declared-action prompts ONLY.
            args += ["--dangerously-skip-permissions"]
            skippedPermissions = true
        } else {
            let mode: String
            if let override = inv.claudePermissionMode {
                mode = override
            } else if inv.configOverrides == CodexCLI.Invocation.approveConnectorWrites {
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
            var tools = ["Bash", "Glob", "Grep", "Read"]
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

    // MARK: Computer use (the agent spine)

    /// The runAgentCommand twin: computer use on the cua driver, through `claude -p`. The hybrid
    /// transport is IDENTICAL to codex's — the daemon, the socket, the CLI shim, and the
    /// CuaDriverSkill manual are all engine-neutral; only the wiring dialect changes:
    /// `--mcp-config` registers the eyes (with `--strict-mcp-config` so nothing else loads),
    /// `--dangerously-skip-permissions` is the bypass twin (headless has no one to answer a
    /// prompt, and every action is a one-shot shell call), and the driver's 52 non-vision MCP
    /// tools are denied by name (Claude Code has no per-server enabled_tools filter).
    /// Screenshots: no `-i` flag exists — paths are appended to the prompt and the model Reads
    /// them (Claude Code's Read tool ingests images natively).
    func runAgentCommand(_ prompt: String, imagePaths: [String] = [], timeout: TimeInterval = 1_800,
                         onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        let t0 = Date()
        let (modelID, effortArg) = Self.agentTuned()
        do {
            if prompt.utf8.count > CodexCLI.promptByteCap {
                throw CodexCLI.CLIError.inputTooLarge(chars: prompt.utf8.count)
            }
            guard let bin = Self.locateBinary() else { throw CodexCLI.CLIError.notAvailable(.notInstalled) }
            // Same fire-time self-heals as codex: driver on disk, then the daemon + live socket.
            if !CuaDriver.isInstalled { await CodexSetup.shared.ensureCuaDriver() }
            guard CuaDriver.isInstalled else {
                throw CodexCLI.CLIError.notAvailable(.notWorking("the cua driver is not installed"))
            }
            guard let socket = await CuaDriverHost.shared.ensureRunning() else {
                throw CodexCLI.CLIError.notAvailable(.notWorking("cua-driver daemon did not start"))
            }

            var fullPrompt = prompt
            if !imagePaths.isEmpty {
                fullPrompt += "\n\nSCREENSHOTS — what the user sees right now (main display first). "
                    + "Read each file with the Read tool BEFORE acting:\n"
                    + imagePaths.map { "- \($0)" }.joined(separator: "\n")
            }

            // ⚠️ The prompt sits DIRECTLY after -p (the documented `claude -p "query"` form),
            // never trailing the flag list: claude's tool flags are VARIADIC (--allowedTools /
            // --disallowedTools / --mcp-config each keep consuming space-separated values), so a
            // bare positional after one gets eaten as another value and the run dies with
            // "Input must be provided either through stdin or as a prompt argument"
            // [FIELD-FOUND 2026-08-21, the first live Sidekick fire]. Same trap as codex's `-i`
            // variadic, dodged the same way: no positional ever follows a variadic flag.
            let args = ["-p", fullPrompt,
                        "--output-format", "stream-json", "--verbose",
                        "--model", modelID,
                        "--effort", effortArg,
                        "--dangerously-skip-permissions",
                        "--setting-sources", "",
                        "--disable-slash-commands",
                        "--strict-mcp-config",
                        "--mcp-config", CuaDriver.claudeMcpConfig(socketPath: socket),
                        // Bash = the shim's one-shot action calls; Read = the screenshots. Nothing
                        // else from the built-in surface (a file the task needs written goes
                        // through the shell, same as on codex).
                        "--tools", "Bash,Read",
                        "--disallowedTools", CuaDriver.claudeDisallowedMcpTools.joined(separator: ",")]

            var env = Self.baseEnv
            // Screenshot-bearing MCP results are big (the default 25k-token cap would truncate a
            // full-display look), and the eyes' first window walk can be slow.
            env["MAX_MCP_OUTPUT_TOKENS"] = "50000"
            env["MCP_TIMEOUT"] = "30000"          // server connect budget (codex: startup_timeout_sec=30)
            env["MCP_TOOL_TIMEOUT"] = "120000"    // per-call budget (codex: tool_timeout_sec=120)

            Log("claude exec: start feature=computer cua=\(CuaDriver.version) model=\(modelID) effort=\(effortArg) resume=false mode=bypass prompt_kb=\(fullPrompt.utf8.count / 1024) images=\(imagePaths.count) trigger=\(CodexTrigger.current.rawValue)")
            let out = try await CodexCLI.executeStreaming(binary: bin, args: args, timeout: timeout,
                                                          extraEnv: env) { raw in
                // stderr rides through as-is (already prefixed by the plumbing); stdout is
                // stream-json and gets reduced to the human play-by-play.
                if raw.hasPrefix("stderr: ") { onLine(raw) }
                else { for s in Self.humanLines(fromStreamJSON: raw) { onLine(s) } }
            }
            let env2 = try Self.parseEnvelope(out, durationMS: Int(Date().timeIntervalSince(t0) * 1000))
            Log("claude exec: ok feature=computer in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            return env2.result
        } catch {
            if !Task.isCancelled {
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                Log("claude exec: \(CodexFailureReason.classify(error).rawValue) feature=computer in \(ms)ms")
                emitClaudeFailure(event: "claude.agent_command", error, feature: "computer",
                                  modelID: modelID, effort: effortArg, resumed: false,
                                  durationMS: ms, timeoutS: Int(timeout))
            }
            throw error
        }
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
    private static func parseEnvelope(_ out: CodexCLI.ExecResult, durationMS: Int) throws -> CodexCLI.Envelope {
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
        return CodexCLI.Envelope(
            result: text,
            sessionID: (resultObj?["session_id"] as? String) ?? sessionID,
            numTurns: resultObj?["num_turns"] as? Int,
            durationMS: durationMS,
            inputTokens: usage?["input_tokens"] as? Int,
            cachedInputTokens: usage?["cache_read_input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            raw: out.stdout
        )
    }

    /// Reduce one stream-json line to short human play-by-play lines — the humanLine twin.
    /// An assistant message can carry several content blocks (text + tool calls), so this
    /// returns all of them. Thinking blocks are skipped (full extended thinking is far too
    /// verbose for a notch line); tool results and partial deltas are noise.
    private static func humanLines(fromStreamJSON line: String) -> [String] {
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
