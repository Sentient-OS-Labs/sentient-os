//
//  CodexCLI.swift
//  Sentient OS macOS
//
//  The `codex exec` wrapper service — the compute spine for ALL cloud-model work:
//  vault generation, daily updates, proactive intelligence. Discovers the user's Codex CLI
//  binary, validates it with a quick ping, and runs headless prompts via `Process`:
//  prompt over STDIN (never argv — macOS ARG_MAX is 1 MB), `--json` JSONL events back,
//  sandbox/effort/cwd scoping, and typed usage-limit errors that carry the session (thread)
//  id so callers can reschedule and resume. All mechanics receipt-verified live (receipts in
//  the doc below).
//
//  Key methods:
//   - CodexCLI.locateBinary()  → cached absolute-path discovery (known paths + zsh -lc which)
//   - install(onLine:)         → run OpenAI's standalone installer (the codex-setup onboarding step)
//   - startLogin / loginStatus → step 2: interactive `codex login` (browser) + the status check
//   - validate(force:)         → Availability via ping (only a good verdict is cached)
//   - run(_:)                  → Envelope (blocking JSONL mode)
//
//  Doc: Documentation/CodexCLI (codex exec Compute Spine).md
//

import Foundation
import os

actor CodexCLI {

    /// One shared instance so the per-launch availability cache is app-wide.
    static let shared = CodexCLI()

    // MARK: Types

    /// Reasoning-effort tier (codex `model_reasoning_effort`). All four are accepted by codex.
    /// Per-call: Gmail connect-check = `.low`, Gmail processing = `.high`, knowledge-base work
    /// (and everything else) = `.high`. Nothing runs `.xhigh` anymore — gpt-5.6-sol thinks far
    /// too long there (the initial vault build was downgraded to `.high`, 2026-07-10).
    enum Effort: String, Sendable {
        case low
        case medium
        case high
        case xhigh
    }

    /// The model id passed to `codex exec -m`. The gpt-5.6 lineup (sol = flagship · terra = mid ·
    /// luna = light) rides ChatGPT-account auth like 5.5/5.4-mini did.
    /// (Old lesson still applies: some SKUs are API-key-only — verify a model answers through
    /// `codex exec` on a ChatGPT plan before adopting it [gpt-5.4-spark et al., MEASURED June 15].)
    enum Model: String, Sendable {
        case gpt56sol = "gpt-5.6-sol"    // knowledge-base work + everything else (paid plans)
        case gpt56terra = "gpt-5.6-terra" // the free/go stand-in for sol (see planTuned)
        case gpt56luna = "gpt-5.6-luna"  // Gmail connect-check + processing
    }

    /// Free/go ChatGPT accounts lost access to gpt-5.6-sol (it stopped answering through
    /// `codex exec` on those plans, 2026-07-19) — so on a POSITIVE free/go plan read, any sol
    /// call downshifts to gpt-5.6-terra at `.medium`. Unknown plans keep sol (CodexAuth's
    /// fail-open policy), and the luna tier is untouched. Living here at the spine means every
    /// caller — and any future one — is covered without per-call-site checks.
    private static func planTuned(model: Model, effort: Effort) -> (Model, Effort) {
        guard model == .gpt56sol, CodexAuth.isLimited() else { return (model, effort) }
        return (.gpt56terra, .medium)
    }

    /// OS-level (Seatbelt) confinement of everything the agent does — stronger than a tool
    /// allowlist: even model-run shell commands can't write outside the workspace.
    enum Sandbox: String, Sendable {
        case readOnly = "read-only"              // no writes anywhere (the proactive judge)
        case workspaceWrite = "workspace-write"  // writes confined to cwd + addDirs
    }

    /// One headless `codex exec` call, fully specified.
    struct Invocation: Sendable {
        var prompt: String
        var model: Model = .gpt56sol              // gpt-5.6-sol for everything except the Gmail tier
        var effort: Effort = .high             // gpt-5.6-sol default (nothing overrides upward); Gmail tier → .medium
        var sandbox: Sandbox = .readOnly
        var cwd: String? = nil                 // the agent's working root (vault/staging dir)
        var addDirs: [String] = []             // extra writable roots beyond cwd
        var webSearch = true                   // native web_search tool — available to EVERY call
        var includeUserConfig = true           // load the user's ~/.codex config + MCP servers (e.g.
                                               // their Gmail MCP) for EVERY call. Set false for a
                                               // hermetic run (then we pass --ignore-user-config).
        var bypassApprovals = false            // --dangerously-bypass-approvals-and-sandbox: NO
                                               // approval prompts AND NO sandbox. COMPUTER USE ONLY:
                                               // the computer-use plugin's per-app "allow app X?"
                                               // elicitations auto-accept only under the full-access
                                               // profile — under any Seatbelt profile a headless run
                                               // auto-denies them (measured 2026-07-18). Hosted
                                               // connector WRITES no longer ride this — they use
                                               // `approveConnectorWrites` (sandbox stays ON).
                                               // TRUSTED, app-authored prompts ONLY (no sandbox!).
        var configOverrides: [String] = []     // extra raw `-c key=value` TOML overrides, scoped to
                                               // THIS run only (never persisted into the user's
                                               // config.toml). Use the curated presets below.
        var outputSchema: String? = nil        // JSON Schema for the final message (the judge)
        var resumeSessionID: String? = nil     // continue a prior session (usage-limit recovery)
        var timeout: TimeInterval = 3_600      // agentic vault runs are long; default generous
        var feature: String = "unknown"        // §7.9: which caller — so a codex.failure is attributable
                                               // (gmail / calendar / vault / proactive / …). Diagnostics
                                               // tag ONLY; never affects the run.
        var diag: [String: String] = [:]       // caller-supplied structured diagnostics merged into a
                                               // codex.failure's extra (e.g. the vault's corpus_chars /
                                               // slices / slice_index). Ints and enums rendered as
                                               // strings ONLY — never paths, UUIDs, or free text (the
                                               // Sentry scrubber [Filtered]s those into uselessness).

        init(prompt: String) { self.prompt = prompt }

        /// Pre-approves hosted-connector WRITE tools (Gmail `send_email`, Calendar create) for one
        /// run while the Seatbelt sandbox stays ON — the sandboxed replacement for `bypassApprovals`
        /// on the executor's connector channels. `apps._default` is the catch-all codex's approval
        /// chain falls to for ANY connector, so this is portable across users and connector-catalog
        /// ids (verified live with a real Gmail send under `-s read-only`, 2026-07-18). Reserve it
        /// for fixed, app-authored prompts that fire exactly one declared action.
        static let approveConnectorWrites = [
            #"apps._default.default_tools_approval_mode="approve""#,
        ]

        /// Removes the connector tools that transmit externally (`open_world_hint` — e.g. Gmail
        /// send) or destroy data (`destructive_hint` — trash/delete) from the run's tool surface
        /// entirely; read tools are untouched. For read-only phases (proactive research): "never
        /// fire" becomes the tools not existing — on top of the prompt rule and the headless
        /// auto-cancel of unapproved writes. Verified live 2026-07-18: Gmail search completes
        /// while a send attempt fails with "is not a function" — the tool is genuinely absent.
        /// The keys MUST be the LONG global catalog connector ids: friendly slugs ("gmail") are
        /// silent no-ops for hosted connectors, and the app-wide `apps._default` variant strips
        /// the READ tools too (both measured, codexperms self-test). The ids are global marketplace
        /// constants (same for every user — see OpenAI's public `openai/plugins` repo, or
        /// `~/.codex/plugins/cache/openai-curated-remote/<app>/<ver>/.app.json`). If one ever
        /// rotated, this strip degrades to a harmless no-op and the other two layers still hold.
        static let stripConnectorActionTools = [
            "apps.connector_2128aebfecb84f64a069897515042a44.open_world_enabled=false",    // gmail
            "apps.connector_2128aebfecb84f64a069897515042a44.destructive_enabled=false",   // gmail
            "apps.connector_947e0d954944416db111db556030eea6.open_world_enabled=false",    // google-calendar
            "apps.connector_947e0d954944416db111db556030eea6.destructive_enabled=false",   // google-calendar
        ]
    }

    /// The `--json` JSONL stream, reduced to an envelope.
    struct Envelope: Sendable {
        let result: String                     // the agent's final message
        let sessionID: String?                 // thread id (first event) — the resume handle
        let numTurns: Int?                     // completed items (messages, commands, file edits)
        let durationMS: Int?                   // wall clock, measured here (codex doesn't report it)
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let outputTokens: Int?
        let raw: String                        // full JSONL, for debugging
    }

    enum Availability: Sendable, Equatable {
        case available(path: String)
        case notInstalled
        case notWorking(String)                // binary found but the ping failed (auth, broken install…)
    }

    enum CLIError: Error, CustomStringConvertible {
        case notAvailable(Availability)
        case launchFailed(String)
        case timedOut(after: TimeInterval)
        case exitFailure(code: Int32, message: String)
        case badEnvelope(String)
        /// Subscription window exhausted. `sessionID` (when present) lets the caller resume the
        /// same agentic session later instead of starting over.
        case usageLimit(message: String, sessionID: String?)
        /// The prompt exceeds codex's server-side 1,048,576-char turn-input cap (rejected at
        /// turn/start before the model runs). Thrown by the pre-spawn guard in both spines;
        /// with corpus slicing in place this is a canary that should never fire.
        case inputTooLarge(chars: Int)

        var description: String {
            switch self {
            case .notAvailable(let a):            return "Codex unavailable: \(a)"
            case .launchFailed(let m):            return "Failed to launch codex: \(m)"
            case .timedOut(let t):                return "codex exec timed out after \(Int(t))s"
            case .exitFailure(let code, let m):   return "codex exited \(code): \(m.prefix(300))"
            case .badEnvelope(let m):             return "Unparseable codex output: \(m.prefix(300))"
            case .usageLimit(let m, _):           return "Codex usage limit: \(m.prefix(200))"
            case .inputTooLarge(let c):           return "Prompt too large for codex: \(c) chars (server cap 1,048,576)"
            }
        }
    }

    // MARK: Discovery

    private static let pathCacheKey = "codexcli.binaryPath"

    /// Known install locations, then a login-shell `which` (GUI apps don't inherit the user's
    /// PATH). The result is cached in UserDefaults and re-verified on every read.
    static func locateBinary() -> String? {
        let fm = FileManager.default
        if let cached = UserDefaults.standard.string(forKey: pathCacheKey),
           fm.isExecutableFile(atPath: cached) {
            return cached
        }
        let home = fm.homeDirectoryForCurrentUser.path
        var known = [
            "\(home)/.local/bin/codex",        // the standalone installer's symlink
            "/opt/homebrew/bin/codex",         // brew / npm -g (Apple Silicon)
            "/usr/local/bin/codex",
        ]
        // npm-under-nvm (`npm i -g @openai/codex` with nvm-managed node): the binary lives in
        // a VERSIONED dir invisible to fixed paths AND to non-interactive shells (nvm inits in
        // .zshrc). Newest node version first. [MEASURED on Aditya's Mac — the app saw
        // "notInstalled" for a fully working, logged-in codex.]
        let nvmBin = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmBin) {
            known += versions.sorted(by: >).map { "\(nvmBin)/\($0)/bin/codex" }
        }
        let found = known.first(where: { fm.isExecutableFile(atPath: $0) }) ?? whichViaLoginShell()
        if let found { UserDefaults.standard.set(found, forKey: pathCacheKey) }
        return found
    }

    /// `zsh -lic` (INTERACTIVE login shell — `-lc` never sources .zshrc, where nvm/asdf/volta
    /// init). Interactive shells print theme noise, so the output is scanned line-by-line for
    /// something that is actually an executable path. Watchdog-bounded; can't hang.
    private static func whichViaLoginShell() -> String? {
        guard let out = try? execute(binary: "/bin/zsh", args: ["-lic", "which codex"],
                                     stdinText: nil, cwd: nil, timeout: 5) else { return nil }
        let fm = FileManager.default
        return (out.stdout + "\n" + out.stderr)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }
    }

    // MARK: Install

    /// Install the Codex CLI via OpenAI's official standalone installer (the codex-setup
    /// onboarding step). Runs `curl … install.sh | CODEX_NON_INTERACTIVE=1 sh` as ONE shell pipeline
    /// (the `|` only exists inside a shell) and streams every output line to `onLine` (the console +
    /// the setup UI). The script drops the binary at `~/.local/bin/codex` — the first path
    /// `locateBinary()` checks. Success = the binary is actually present afterward, NOT the shell's
    /// exit code: a `curl | sh` pipeline reports the trailing `sh`'s status, so a failed download
    /// (no network) can still "exit 0" with nothing installed. Throws if codex isn't found after the
    /// run. (Installed ≠ logged in — auth is the next step; detection-first is the caller's job.)
    ///
    /// ⚠️ The sed stage is a working workaround for an UPSTREAM bug [MEASURED 2026-07-08]: GitHub's
    /// API began serving MINIFIED JSON to requests without an explicit Accept header, and OpenAI's
    /// installer parses the release JSON line-by-line — so every vanilla `curl … | sh` run now dies
    /// with "Could not find Codex package or platform npm release assets". Injecting
    /// `Accept: application/json` into the script's curl calls makes GitHub pretty-print again
    /// (verified end-to-end); it's harmless on the script's binary downloads. Drop the sed once
    /// OpenAI fixes install.sh.
    static func install(onLine: @escaping @Sendable (String) -> Void) async throws {
        let pipeline = #"curl -fsSL https://chatgpt.com/codex/install.sh | sed 's|curl -fsSL|curl -fsSL -H "Accept: application/json"|g' | CODEX_NON_INTERACTIVE=1 sh"#
        let out = try await executeStreaming(binary: "/bin/sh", args: ["-c", pipeline],
                                             timeout: 300, onLine: onLine)
        UserDefaults.standard.removeObject(forKey: pathCacheKey)   // force a fresh discovery scan
        guard locateBinary() != nil else {
            let detail = out.stderr.isEmpty ? out.stdout : out.stderr
            let msg = detail.isEmpty
                ? "Codex not found after install; check your network connection."
                : String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
            throw CLIError.exitFailure(code: out.status, message: msg)
        }
    }

    // MARK: Login (setup step 2)

    /// Begin the interactive login. Launches `codex login` as a BACKGROUND process: it starts a
    /// localhost OAuth callback server and opens the user's browser to the OpenAI sign-in, then
    /// self-exits once the redirect lands and `~/.codex/auth.json` is written. Streams its output to
    /// `onLine` (the auth URL prints here as a fallback if the browser auto-open ever fails). Returns
    /// the running Process so the caller can terminate it on cancel/restart. MUST NOT be awaited to
    /// completion — the flow waits on the user finishing in the browser, then `loginStatus()`.
    /// Inherits the app's full env + rich PATH (`richEnvironment`) so the browser launch + GUI
    /// session vars are intact, exactly like a Terminal `codex login`.
    static func startLogin(onLine: @escaping @Sendable (String) -> Void) throws -> Process {
        guard let bin = locateBinary() else { throw CLIError.notAvailable(.notInstalled) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["login"]
        proc.environment = richEnvironment(binDir: (bin as NSString).deletingLastPathComponent)
        proc.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // Drain both pipes line-by-line until the process exits (EOF). No await: the queues simply
        // finish on their own when `codex login` ends. Byte-level split keeps multibyte UTF-8 intact.
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
        do { try proc.run() } catch { throw CLIError.launchFailed("\(error)") }
        return proc
    }

    /// Step 2 ground-truth check — `codex login status`. [MEASURED v0.142.3] exit 0 = logged in;
    /// exit 1 + "Not logged in" = not. Exit status is the primary signal, with an output scan as a
    /// backstop. Uses the bare-env `executeAsync` (status only reads `~/.codex/auth.json` via HOME).
    /// Ground truth for "codex is installed": actually RUN `codex --help` and see it answer.
    /// A pure path check can be fooled (e.g. a broken symlink left by a half-deleted install);
    /// no binary found anywhere = the shell's "command not found" case. Onboarding's login
    /// screen polls this to un-grey its button the moment the background install lands.
    static func isRunnable() async -> Bool {
        guard let bin = locateBinary() else { return false }
        guard let out = try? await executeAsync(binary: bin, args: ["--help"],
                                                stdinText: nil, cwd: nil, timeout: 10) else { return false }
        return out.status == 0 && !out.stdout.isEmpty
    }

    static func loginStatus() async -> Bool {
        guard let bin = locateBinary() else { return false }
        guard let out = try? await executeAsync(binary: bin, args: ["login", "status"],
                                                stdinText: nil, cwd: nil, timeout: 30) else { return false }
        if out.status == 0 { return true }
        let lowered = (out.stdout + out.stderr).lowercased()
        return lowered.contains("logged in") && !lowered.contains("not logged in")
    }

    // MARK: Validation

    private var cachedAvailability: Availability?

    /// Is `codex exec` actually usable (installed AND logged in)? Only a GOOD verdict is cached —
    /// a failed probe re-checks on every call, so codex fixed mid-session (re-login, reinstall) is
    /// seen by the very next retry (a cached failure once made the processing screen's Retry
    /// unwinnable until relaunch — field-found 2026-07-12). `force: true` re-probes past a good
    /// cache too (e.g. right after the installer flow).
    func validate(force: Bool = false) async -> Availability {
        if !force, let cachedAvailability { return cachedAvailability }
        let result = await Self.ping()
        if case .available = result { cachedAvailability = result } else { cachedAvailability = nil }
        return result
    }

    private static func ping() async -> Availability {
        guard let bin = locateBinary() else { return .notInstalled }
        do {
            let out = try await executeAsync(
                binary: bin,
                args: ["exec", "--json", "--skip-git-repo-check", "--ignore-user-config",
                       "-s", Sandbox.readOnly.rawValue, "Reply with exactly: PIGGYBACK_OK"],
                stdinText: nil, cwd: nil, timeout: 30)
            if out.status == 0 && out.stdout.contains("PIGGYBACK_OK") { return .available(path: bin) }
            let detail = out.stderr.isEmpty ? out.stdout : out.stderr
            return .notWorking(String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
        } catch {
            return .notWorking("\(error)")
        }
    }

    // MARK: Run

    /// Execute one headless call and return the parsed envelope. Throws typed errors —
    /// notably `.usageLimit` (carrying the session id) so callers can reschedule/resume.
    func run(_ invocation: Invocation,
             onLine: (@Sendable (String) -> Void)? = nil) async throws -> Envelope {
        var invocation = invocation
        (invocation.model, invocation.effort) = Self.planTuned(model: invocation.model,
                                                               effort: invocation.effort)
        let t0 = Date()   // §7.9: for the codex.failure duration on the throw path
        do {
            return try await runInner(invocation, onLine: onLine)
        } catch {
            // A cancelled Task is the user's STOP: the SIGTERM'd process exits non-zero, which
            // masqueraded as a real exitFailure in Sentry (field-found 2026-07-12). Not a defect.
            if !Task.isCancelled {
                Self.emitCodexFailure(event: "codex.failure", error, feature: invocation.feature,
                                      model: invocation.model, effort: invocation.effort,
                                      resumed: invocation.resumeSessionID != nil,
                                      durationMS: Int(Date().timeIntervalSince(t0) * 1000),
                                      diag: invocation.diag)
            }
            throw error
        }
    }

    /// Pre-spawn guard: codex rejects any turn input over 1,048,576 characters server-side
    /// (`input_too_large`, no flag raises it — measured 2026-07-19). 950 KB leaves margin for
    /// the char-vs-byte counting gap. Every prompt path is byte-budgeted below this (the vault's
    /// CorpusSlicer, Proactive's window trim), so a throw here means a NEW unbudgeted prompt
    /// path slipped in — a named canary instead of a mystery exitFailure.
    static let promptByteCap = 950_000

    private func runInner(_ invocation: Invocation,
                          onLine: (@Sendable (String) -> Void)? = nil) async throws -> Envelope {
        if invocation.prompt.utf8.count > Self.promptByteCap {
            throw CLIError.inputTooLarge(chars: invocation.prompt.utf8.count)
        }
        let availability = await validate()
        guard case .available(let bin) = availability else {
            throw CLIError.notAvailable(availability)
        }

        // --output-schema wants a file path; the schema string gets a temp file for the call.
        var schemaFile: String?
        if let schema = invocation.outputSchema {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-schema-\(UUID().uuidString).json")
            try Data(schema.utf8).write(to: url)
            schemaFile = url.path
        }
        defer { if let schemaFile { try? FileManager.default.removeItem(atPath: schemaFile) } }

        let started = Date()
        // When a caller wants live play-by-play, adapt each raw --json line into a readable one.
        let stdoutLine: (@Sendable (String) -> Void)? = onLine.map { sink in
            { @Sendable raw in if let s = Self.humanLine(fromJSONL: raw) { sink(s) } }
        }
        let out = try await Self.executeAsync(binary: bin,
                                              args: Self.arguments(for: invocation, schemaFile: schemaFile),
                                              stdinText: invocation.prompt,
                                              cwd: invocation.cwd,
                                              timeout: invocation.timeout,
                                              onStdoutLine: stdoutLine)
        return try Self.parseEnvelope(out, durationMS: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// The command bar's "Let me DO stuff for you" spine — computer use (the "computer use" phrase is
    /// built into the prompt by the caller, NOT a flag here). Runs a raw `codex exec` with the prompt
    /// passed as ARGV and the exact flag set verified to make Codex's computer use work via the CLI:
    /// `--dangerously-bypass-approvals-and-sandbox -m gpt-5.6-sol -c model_reasoning_effort=<the
    /// user's ComputerUseSpeed slider; default low> --skip-git-repo-check`, NO `--json`
    /// (human-readable output, not JSONL). The bypass flag is REQUIRED here — the computer-use
    /// plugin's per-app "allow app X?" elicitations auto-accept only under the full-access profile;
    /// under any Seatbelt profile a headless run auto-denies them and every action fails (measured
    /// 2026-07-18). Safety rides the layers that fit a GUI agent: the fixed app-authored wrapper
    /// (content = DATA), one-declared-task, user-fired only, live streaming + universal STOP. Each output LINE is
    /// pumped to `onLine` AS it arrives, so the Xcode console shows codex's play-by-play live. Reuses
    /// the sanitized-env / PATH / watchdog plumbing; the binary comes from the same discovery
    /// (`~/.local/bin/codex` first). The user's ~/.codex config + MCP servers load by default (no
    /// --ignore-user-config). Returns the full output.
    ///
    /// `imagePaths` (optional): screenshots of the user's displays (main first), attached with
    /// `codex exec -i <file>...` so the agent SEES what they're looking at (the notch/command-bar
    /// path passes one per display; the proactive executor passes none). They're placed right before
    /// `--skip-git-repo-check` so the flag terminates `-i`'s variadic `<FILE>...` and the prompt is
    /// never mistaken for another image.
    func runAgentCommand(_ prompt: String, imagePaths: [String] = [], timeout: TimeInterval = 1_800,
                         onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        let t0 = Date()
        // The user's speed-vs-intelligence slider (Settings → Proactive & Sidekick) — read fresh
        // per run, so a change applies to the very next fire with no restart. planTuned: computer
        // use is Plus-gated, but dev tools can still reach this on a free account — same downshift.
        let (model, effort) = Self.planTuned(model: .gpt56sol,
                                             effort: ComputerUseSpeed.current.effort)
        do {
            // Same pre-spawn guard as `run` — this spine passes the prompt as ARGV, where an
            // oversized prompt dies even earlier (ARG_MAX) with an unhelpful spawn error.
            if prompt.utf8.count > Self.promptByteCap {
                throw CLIError.inputTooLarge(chars: prompt.utf8.count)
            }
            guard let bin = Self.locateBinary() else { throw CLIError.notAvailable(.notInstalled) }
            // Self-heal the relaxed confirmation policy: a plugin update (desktop app or a
            // re-bootstrap) lays a fresh STOCK SKILL.md, whose policy stalls headless runs on
            // "shall I proceed?" questions nothing can answer. Cheap file check, idempotent.
            ComputerUseSkillPatch.ensureApplied()
            var args = ["exec", "--dangerously-bypass-approvals-and-sandbox",
                        "-m", model.rawValue,
                        "-c", "model_reasoning_effort=\"\(effort.rawValue)\""]
            if !imagePaths.isEmpty { args += ["-i"] + imagePaths }   // followed by a flag → the variadic stops here
            args += ["--skip-git-repo-check", prompt]
            let out = try await Self.executeStreaming(binary: bin, args: args, timeout: timeout, onLine: onLine)
            guard out.status == 0 else {
                let detail = out.stderr.isEmpty ? out.stdout : out.stderr
                throw CLIError.exitFailure(code: out.status, message: String(detail.prefix(600)))
            }
            return out.stdout.isEmpty ? out.stderr : out.stdout
        } catch {
            // §7.9: computer-use is the full-capability path (bypass-sandbox, user-fired), so a
            // genuine failure is worth a structured event. Case name only — and never on a cancelled
            // Task (the user's STOP kills codex → non-zero exit, which is not a failure; field-found
            // polluting Sentry 2026-07-12).
            if !Task.isCancelled {
                Self.emitCodexFailure(event: "codex.agent_command", error, feature: "computer",
                                      model: model, effort: effort, resumed: false,
                                      durationMS: Int(Date().timeIntervalSince(t0) * 1000))
            }
            throw error
        }
    }

    /// Emit a structured codex failure — the CLIError CASE NAME only (never `.message`/stderr/prompt,
    /// which embed user content). One seam for the whole cloud spine; `feature` makes it attributable;
    /// `diag` is the caller's structured extras (Invocation.diag — ints/enums only, pre-vetted).
    private static func emitCodexFailure(event: String, _ error: Error, feature: String,
                                         model: Model, effort: Effort, resumed: Bool, durationMS: Int,
                                         diag: [String: String] = [:]) {
        let caseName: String
        let level: CrashReporting.DiagLevel
        var extra = diag
        switch error {
        case CLIError.usageLimit:   return   // expected, not a defect — the amber caution + resume own it
        case CLIError.notAvailable: (caseName, level) = ("notAvailable", .warning)
        case CLIError.timedOut:     (caseName, level) = ("timedOut", .warning)
        case CLIError.launchFailed: (caseName, level) = ("launchFailed", .error)
        case CLIError.exitFailure(let code, _):
            (caseName, level) = ("exitFailure", .error)
            extra["exit_code"] = String(code)
        case CLIError.badEnvelope:  (caseName, level) = ("badEnvelope", .error)
        case CLIError.inputTooLarge(let chars):
            // The canary: every prompt path is byte-budgeted, so this should stay at zero.
            (caseName, level) = ("inputTooLarge", .error)
            extra["prompt_chars"] = String(chars)
        default:                    (caseName, level) = (String(describing: type(of: error)), .error)
        }
        extra["effort"] = effort.rawValue
        extra["resumed"] = String(resumed)
        extra["duration_ms"] = String(durationMS)
        CrashReporting.captureEvent(event, level: level,
            tags: ["feature": feature, "error": caseName, "model": model.rawValue],
            extra: extra,
            fingerprint: ["codex", feature, caseName])
    }

    /// `exec resume` accepts only a subset of `exec`'s flags — no `-s`/`--cd`/`--add-dir`.
    /// [MEASURED] A resumed session's workspace root is the PROCESS cwd (not the remembered
    /// one), so `execute`'s cwd is load-bearing there, and the sandbox rides the
    /// `sandbox_mode` config key instead of `-s`.
    private static func arguments(for inv: Invocation, schemaFile: String?) -> [String] {
        var args = ["exec"]
        if let sid = inv.resumeSessionID { args += ["resume", sid] }
        args += ["--json",
                 "--skip-git-repo-check",      // staging dirs and the vault aren't git repos
                 "-m", inv.model.rawValue,
                 "-c", "model_reasoning_effort=\"\(inv.effort.rawValue)\""]
        if !inv.includeUserConfig {
            args += ["--ignore-user-config"]   // explicit hermetic opt-out only — includeUserConfig
        }                                      // defaults TRUE, so by default we DON'T pass this and
                                               // the user's ~/.codex config + MCP servers ARE loaded.

        // Approvals + sandbox. `codex exec` is headless and can't answer an approval prompt:
        //  · default → `approval_policy=never` (don't stall) + the Seatbelt sandbox (`-s`) as the
        //    real guardrail for shell/file ops. Hosted-connector WRITE tools are approval-gated
        //    ("user cancelled MCP tool call" headless) — a caller that must fire one keeps this
        //    sandboxed path and adds `approveConnectorWrites` to `configOverrides` instead.
        //  · bypassApprovals → `--dangerously-bypass-approvals-and-sandbox` (NO approvals, NO
        //    sandbox) — computer use only (its per-app elicitations auto-deny headless under any
        //    Seatbelt profile). Mutually exclusive — codex rejects `-s`/approval_policy with it.
        if inv.bypassApprovals {
            args += ["--dangerously-bypass-approvals-and-sandbox"]
            if inv.resumeSessionID == nil, let cwd = inv.cwd { args += ["--cd", cwd] }
        } else {
            args += ["-c", "approval_policy=\"never\""]
            if inv.resumeSessionID == nil {
                args += ["-s", inv.sandbox.rawValue]
                if let cwd = inv.cwd { args += ["--cd", cwd] }
                for dir in inv.addDirs { args += ["--add-dir", dir] }
            } else {
                args += ["-c", "sandbox_mode=\"\(inv.sandbox.rawValue)\""]
            }
        }
        for override in inv.configOverrides { args += ["-c", override] }
        if inv.webSearch { args += ["-c", "tools.web_search=true"] }
        if let schemaFile { args += ["--output-schema", schemaFile] }
        args.append("-")                       // the prompt arrives on stdin
        return args
    }

    // MARK: JSONL parsing

    private static let usageLimitMarkers = ["usage limit", "rate limit", "limit reached",
                                            "limit resets", "quota", "too many requests",
                                            "out of extra usage", "plan limit"]

    private static func parseEnvelope(_ out: ExecResult, durationMS: Int) throws -> Envelope {
        var sessionID: String?
        var lastMessage: String?
        var completedItems = 0
        var usage: [String: Any]?
        var errors: [String] = []

        for line in out.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "thread.started":
                sessionID = obj["thread_id"] as? String
            case "item.completed":
                completedItems += 1
                if let item = obj["item"] as? [String: Any],
                   item["type"] as? String == "agent_message",
                   let text = item["text"] as? String {
                    lastMessage = text
                }
            case "turn.completed":
                usage = obj["usage"] as? [String: Any]
            case "turn.failed", "error":
                if let err = obj["error"] as? [String: Any], let m = err["message"] as? String {
                    errors.append(m)
                } else if let m = obj["message"] as? String {
                    errors.append(m)
                }
            default:
                break
            }
        }

        // Failure = non-zero exit OR no final message (a recovered mid-run error that still
        // produced an answer with exit 0 counts as success). The thread id arrives in the very
        // first event, so even a mid-run usage limit keeps its resume handle.
        if out.status != 0 || lastMessage == nil {
            let detail = errors.isEmpty ? (out.stderr.isEmpty ? out.stdout : out.stderr)
                                        : errors.joined(separator: " · ")
            let lowered = detail.lowercased()
            // Belt-and-suspenders behind the pre-spawn guard: if a prompt still reached the
            // server and bounced off the turn-input cap (config drift, a changed cap), name it
            // instead of letting it fall through as a mystery exitFailure. Checked FIRST — the
            // wording could drift toward the usage-limit markers.
            if lowered.contains("input_too_large") || lowered.contains("exceeds the maximum length") {
                let chars = detail.range(of: #""actual_chars":(\d+)"#, options: .regularExpression)
                    .flatMap { Int(detail[$0].drop(while: { !$0.isNumber })) } ?? 0
                throw CLIError.inputTooLarge(chars: chars)
            }
            if usageLimitMarkers.contains(where: { lowered.contains($0) }) {
                throw CLIError.usageLimit(message: String(detail.prefix(600)), sessionID: sessionID)
            }
            if out.status != 0 {
                throw CLIError.exitFailure(code: out.status, message: String(detail.prefix(600)))
            }
            throw CLIError.badEnvelope(String(detail.prefix(600)))
        }

        return Envelope(
            result: lastMessage ?? "",
            sessionID: sessionID,
            numTurns: completedItems,
            durationMS: durationMS,
            inputTokens: usage?["input_tokens"] as? Int,
            cachedInputTokens: usage?["cached_input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            raw: out.stdout
        )
    }

    /// Reduce one raw `--json` event line to a short, human-readable play-by-play line for a live UI
    /// (the For You card / command bar), or nil to skip noise. Tolerant: codex's event shapes vary, so
    /// it pulls the readable field from the common item types and ignores the rest. The consumer
    /// dedups (an item can arrive as both `.started` and `.completed`).
    private static func humanLine(fromJSONL line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String,
              type.hasPrefix("item"),                       // payloads ride item.started/.completed/.updated
              let item = obj["item"] as? [String: Any] else { return nil }
        func nonEmpty(_ s: String?) -> String? { (s?.isEmpty == false) ? s : nil }
        switch item["type"] as? String {
        case "agent_message":
            return nonEmpty(item["text"] as? String)
        case "reasoning":
            return nonEmpty((item["text"] as? String) ?? (item["summary"] as? String))
        case "command_execution", "local_shell_call":
            return nonEmpty(item["command"] as? String).map { "$ \($0)" }
        case "mcp_tool_call", "tool_call", "function_call":
            let label = [(item["server"] as? String) ?? "",
                         (item["tool"] as? String) ?? (item["name"] as? String) ?? ""]
                .filter { !$0.isEmpty }.joined(separator: ".")
            return label.isEmpty ? nil : "→ \(label)"
        case "web_search", "web_search_call":
            return (item["query"] as? String).map { "🔎 \($0)" } ?? "🔎 searching…"
        default:
            return nil
        }
    }

    // MARK: Process plumbing

    struct ExecResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Full inherited environment + a rich PATH, for the codex calls that need the real GUI session
    /// context (NOT the bare HOME/USER env `execute` uses). Computer use needs the inherited $TMPDIR
    /// + session/bootstrap vars (its `SkyComputerUseService` IPC socket lives under $TMPDIR, so the
    /// bare env hangs at `list_apps`); `codex login` needs the same so the browser launch works. The
    /// binary's own dir leads PATH (npm shims `#!/usr/bin/env node` right next to themselves).
    private static func richEnvironment(binDir: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let richPath = [binDir,
                        "\(home)/.local/bin",
                        "/opt/homebrew/bin", "/opt/homebrew/sbin",
                        "/usr/local/bin",
                        "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin",
                        "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["PATH"] = env["PATH"].map { "\(richPath):\($0)" } ?? richPath
        return env
    }

    /// Thread-safe byte sink so each pipe drains concurrently with the running child —
    /// a full 64 KB pipe buffer would otherwise deadlock both processes.
    private final class PipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var buf = Data()
        func set(_ d: Data) { lock.lock(); buf = d; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(data: buf, encoding: .utf8) ?? "" }
    }

    private static func executeAsync(binary: String, args: [String], stdinText: String?,
                                     cwd: String?, timeout: TimeInterval,
                                     onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ExecResult {
        // Honor Task cancellation (a card's STOP): terminate the child so an in-flight send/action stops.
        let holder = ProcHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: try execute(binary: binary, args: args, stdinText: stdinText,
                                                            cwd: cwd, timeout: timeout,
                                                            onStdoutLine: onStdoutLine, procHolder: holder)) }
                    catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: { holder.terminate() }
    }

    /// Blocking runner (call off-main). GUI-spawned `Process` works with a SANITIZED env —
    /// just HOME/USER + the system PATH and the absolute binary path; codex's auth lives in
    /// ~/.codex (resolved via HOME), no TTY needed (measured — receipts in the CodexCLI doc).
    private static func execute(binary: String, args: [String], stdinText: String?,
                                cwd: String?, timeout: TimeInterval,
                                onStdoutLine: (@Sendable (String) -> Void)? = nil,
                                procHolder: ProcHolder? = nil) throws -> ExecResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        // The binary's OWN directory leads the sanitized PATH: npm installs are
        // `#!/usr/bin/env node` shims, and (in the nvm layout) `node` sits right next to
        // them — without this, the shim exec-fails even when found.
        let binDir = (binary as NSString).deletingLastPathComponent
        var env: [String: String] = [:]
        let current = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER"] where current[key] != nil { env[key] = current[key] }
        env["PATH"] = [binDir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        proc.environment = env
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Drain both output pipes on their own queues for the process's whole lifetime. stderr drains
        // whole; stdout LINE-streams to `onStdoutLine` (when present) so callers see codex's --json
        // play-by-play live, while still accumulating the full buffer for parseEnvelope.
        let outDrain = PipeDrain(), errDrain = PipeDrain()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            errDrain.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = outPipe.fileHandleForReading
            guard let onStdoutLine else {
                outDrain.set(handle.readDataToEndOfFile())     // no streaming → drain whole
                drained.leave(); return
            }
            var buf = Data(), all = Data()                     // byte-level split (multibyte-safe)
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buf.append(chunk); all.append(chunk)
                while let nl = buf.firstIndex(of: 0x0A) {
                    onStdoutLine(String(decoding: buf[..<nl], as: UTF8.self))
                    buf = Data(buf[buf.index(after: nl)...])
                }
            }
            if !buf.isEmpty { onStdoutLine(String(decoding: buf, as: UTF8.self)) }
            outDrain.set(all)
            drained.leave()
        }

        do { try proc.run() } catch { throw CLIError.launchFailed("\(error)") }
        procHolder?.set(proc)   // expose to the cancellation handler (a card's STOP)

        // Feed the prompt over stdin on its own queue: prompts can be hundreds of KB (whole
        // summary corpora), far beyond the pipe buffer, so the write must overlap the child's
        // reading. Closing the handle is the EOF the CLI waits for.
        DispatchQueue.global(qos: .utility).async {
            if let stdinText { try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdinText.utf8)) }
            try? inPipe.fileHandleForWriting.close()
        }

        // Watchdog: terminate on timeout. waitUntilExit below unblocks either way; we tell a
        // timeout apart from a normal exit via the flag (terminate() looks like SIGTERM).
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = DispatchWorkItem { [weak proc] in
            timedOut.withLock { $0 = true }
            proc?.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        proc.waitUntilExit()
        watchdog.cancel()
        drained.wait()

        if timedOut.withLock({ $0 }) { throw CLIError.timedOut(after: timeout) }
        return ExecResult(status: proc.terminationStatus, stdout: outDrain.text, stderr: errDrain.text)
    }

    /// Thread-safe append-only text accumulator for the streaming runner.
    private final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var s = ""
        func append(_ piece: String) { lock.lock(); s += piece; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return s }
    }

    /// Thread-safe handle to the running child so the Task-cancellation handler (the STOP button)
    /// can terminate it. Set once the process has launched.
    private final class ProcHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var proc: Process?
        func set(_ p: Process) { lock.lock(); proc = p; lock.unlock() }
        func terminate() { lock.lock(); let p = proc; lock.unlock(); if let p, p.isRunning { p.terminate() } }
    }

    /// Streaming sibling of `execute`: same env / PATH / watchdog, but it pumps each output LINE
    /// (stdout and stderr) to `onLine` as it arrives — so the console AND the command bar show
    /// codex's play-by-play live — while accumulating the full text. No stdin (the prompt rides in
    /// argv). Byte-level line splitting so multibyte UTF-8 across a read boundary never garbles.
    /// Honors Task cancellation: cancelling the awaiting Task terminates codex (the STOP button).
    private static func executeStreaming(binary: String, args: [String], timeout: TimeInterval,
                                         onLine: @escaping @Sendable (String) -> Void) async throws -> ExecResult {
        let holder = ProcHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ExecResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binary)
                proc.arguments = args
                // Full inherited env + rich PATH (see richEnvironment): computer use needs the real
                // $TMPDIR + GUI session vars (its helper IPC socket lives under $TMPDIR), and so does
                // `codex login`'s browser launch — the bare HOME/USER env `execute` uses won't do.
                proc.environment = richEnvironment(binDir: (binary as NSString).deletingLastPathComponent)

                let outPipe = Pipe(), errPipe = Pipe()
                proc.standardInput = FileHandle.nullDevice
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                let outSink = LineSink(), errSink = LineSink()
                let group = DispatchGroup()
                for (pipe, sink, prefix) in [(outPipe, outSink, ""), (errPipe, errSink, "stderr: ")] {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        var buf = Data()
                        let handle = pipe.fileHandleForReading
                        while true {
                            let chunk = handle.availableData     // blocks until data, empty = EOF
                            if chunk.isEmpty { break }
                            buf.append(chunk)
                            while let nl = buf.firstIndex(of: 0x0A) {
                                let line = String(decoding: buf[..<nl], as: UTF8.self)
                                buf = Data(buf[buf.index(after: nl)...])   // fresh 0-based remainder
                                sink.append(line + "\n")
                                onLine(prefix + line)
                            }
                        }
                        if !buf.isEmpty {                          // trailing partial line (no newline)
                            let line = String(decoding: buf, as: UTF8.self)
                            sink.append(line)
                            onLine(prefix + line)
                        }
                        group.leave()
                    }
                }

                do { try proc.run() } catch { cont.resume(throwing: CLIError.launchFailed("\(error)")); return }
                holder.set(proc)        // expose to the cancellation handler (STOP)

                let timedOut = OSAllocatedUnfairLock(initialState: false)
                let watchdog = DispatchWorkItem { [weak proc] in
                    timedOut.withLock { $0 = true }; proc?.terminate()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

                proc.waitUntilExit()
                watchdog.cancel()
                group.wait()

                if timedOut.withLock({ $0 }) { cont.resume(throwing: CLIError.timedOut(after: timeout)); return }
                cont.resume(returning: ExecResult(status: proc.terminationStatus,
                                                  stdout: outSink.text, stderr: errSink.text))
            }
        }
        } onCancel: {
            holder.terminate()    // STOP: kill codex → the run resumes with a non-zero exit
        }
    }
}
