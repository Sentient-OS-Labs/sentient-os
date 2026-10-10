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
//   - CodexCLI.locateBinary()  → select Sentient’s private, pinned CLI
//   - install(onLine:)         → download and verify the approved package (the onboarding step;
//                                also repairs a damaged private installation)
//   - installedVersion / approvedVersion → the private runtime health check
//   - startLogin / loginStatus → step 2: interactive `codex login` (browser) + the status check
//   - validate(force:)         → Availability via ping (only a good verdict is cached)
//   - run(_:)                  → Envelope (blocking JSONL mode)
//
//  Doc: Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md
//

import Foundation
import os
import Darwin

actor CodexCLI {

    /// One shared instance so the per-launch availability cache is app-wide.
    static let shared = CodexCLI()

    // MARK: Types

    /// Reasoning-effort tier for CHATGPT-backend calls (codex `model_reasoning_effort`). All
    /// four are accepted by codex. Per-call: Gmail connect-check = `.low`, Gmail processing =
    /// `.high`, knowledge-base work (and everything else) = `.high`. Nothing runs `.xhigh`
    /// anymore — gpt-5.6-sol thinks far too long there (the initial vault build was downgraded
    /// to `.high`, 2026-07-10). A CUSTOM backend never uses this enum: the user's free-form
    /// reasoning level (Frontier Model Choice — `none`, `xhigh`, `adaptive`, whatever their
    /// model speaks) rides the wire as a raw string via backendTuned.
    enum Effort: String, Sendable {
        case low
        case medium
        case high
        case xhigh
    }

    /// The model id passed to `codex exec -m`. Astra powers the upper computer-use tiers;
    /// Sol handles the fastest tier and background work, Terra the free/go fallback, Luna reads.
    /// (Old lesson still applies: some SKUs are API-key-only — verify a model answers through
    /// `codex exec` on a ChatGPT plan before adopting it [gpt-5.4-spark et al., MEASURED June 15].)
    enum Model: String, Sendable {
        case gpt6astra = "gpt-6-astra"  // computer use: Medium / Smarter
        case gpt6sol = "gpt-6-sol"    // knowledge-base work + everything else (paid plans)
        case gpt56terra = "gpt-5.6-terra" // the free/go stand-in for sol (see planTuned)
        case gpt6luna = "gpt-6-luna"  // Gmail connect-check + processing
    }

    /// The ONE model-resolution choke point: every run's `-m` value comes from here.
    ///  - Custom backend (Settings → Frontier Model Choice): the user's endpoint model rides
    ///    EVERY call — the tier enums collapse to one model, and the caller's effort is
    ///    replaced by the pane's ONE per-endpoint reasoning level (per-call effort tuning is
    ///    ChatGPT's alone; providers have hard reasoning quirks — Claude-class needs off,
    ///    Gemini rejects off — so the user's setting must win everywhere, Speed slider
    ///    included). The luna callers (Gmail/Calendar) never reach here in custom mode —
    ///    connectors are ChatGPT-only.
    ///  - ChatGPT backend: free/go accounts lost access to gpt-5.6-sol (it stopped answering
    ///    through `codex exec` on those plans, 2026-07-19) — so on a POSITIVE free/go plan
    ///    read, any sol/astra call downshifts to gpt-5.6-terra at `.medium`. Unknown plans keep
    ///    the requested model (CodexAuth's fail-open policy), and the luna tier is untouched.
    /// Living here at the spine means every caller — and any future one — is covered without
    /// per-call-site checks.
    private static func backendTuned(model: Model, effort: Effort) -> (modelID: String, effortArg: String) {
        if ModelBackend.current == .custom {
            return (CustomProvider.current.modelName, CustomProvider.reasoning)
        }
        guard model == .gpt6sol || model == .gpt6astra, CodexAuth.isLimited() else {
            return (model.rawValue, effort.rawValue)
        }
        return (Model.gpt56terra.rawValue, Effort.medium.rawValue)
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
        var model: Model = .gpt6sol              // gpt-6-sol for everything except the Gmail tier
        var effort: Effort = .high             // gpt-6-sol default (nothing overrides upward); Gmail tier → .medium
        var sandbox: Sandbox = .readOnly
        var cwd: String? = nil                 // the agent's working root (vault/staging dir)
        var addDirs: [String] = []             // extra writable roots beyond cwd
        var webSearch = true                   // native web_search tool — available to EVERY call
        var includeUserConfig = true           // load Sentient's private config + MCP servers (e.g.
                                               // their Gmail MCP) for EVERY call. Set false for a
                                               // hermetic run (then we pass --ignore-user-config).
        var bypassApprovals = false            // --dangerously-bypass-approvals-and-sandbox: NO
                                               // approval prompts AND NO sandbox. COMPUTER USE ONLY:
                                               // a headless run has no one to answer an approval,
                                               // and the agent shells out alongside the cua tools
                                               // where any Seatbelt profile stalls it. Hosted
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

        // The connector run recipes (see the recipe tables in each engine's argument builder).
        // Slugs are ConnectorRegistry's canonical identities, resolved to per-engine server
        // definitions through the ONE seam `ConnectorRegistry.server(for:)`. All three are
        // inert when unset, on the custom backend, and never combine with each other or with
        // `bypassApprovals` (the sandboxed recipes never bypass):
        var mcpActionServer: String? = nil     // FIRED CONNECTOR TASK: user-fired, one connector.
                                               // Claude: dontAsk + allow that server's tools, a
                                               // one-server allowedMcpServers wall, destructive
                                               // tools denied by name (requires a classification —
                                               // fail-closed). Codex: per-id approve mode (else
                                               // the shipped id-free `apps._default` preset) +
                                               // the destructive strip; sandbox stays ON.
        var slackOperation: SlackConnector.Operation? = nil
        var slackRunID: UUID? = nil
        var outlookOperation: OutlookMailConnector.Operation? = nil
        var outlookRunID: UUID? = nil
        var outlookKeepsReadBudget = false
        var outlookCalendarOperation: OutlookCalendarConnector.Operation? = nil
        var outlookCalendarReadPurpose: OutlookCalendarConnector.ReadPurpose? = nil
        var outlookCalendarReadWindow: MCPSource.Window? = nil
        var outlookCalendarExpectedCreationHash: String? = nil
        var outlookCalendarAccountFingerprint: String? = nil
        var outlookCalendarIntentHash: String? = nil
        var includesOutlookMail: Bool {
            mcpActionServer == OutlookMailConnector.slug || mcpReadConnectors.contains(OutlookMailConnector.slug)
        }
        var calendarPolicy: OutlookCalendarToolPolicy.Context? {
            guard mcpActionServer == OutlookCalendarConnector.slug || mcpReadConnectors.contains(OutlookCalendarConnector.slug) else { return nil }
            return .init(operation: mcpActionServer == OutlookCalendarConnector.slug ? (outlookCalendarOperation ?? .read) : .read,
                         purpose: outlookCalendarReadPurpose, window: outlookCalendarReadWindow,
                         expectedCreationHash: outlookCalendarExpectedCreationHash,
                         accountFingerprint: outlookCalendarAccountFingerprint, intentHash: outlookCalendarIntentHash)
        }
        var outlookReadMode: MCPSource.ReadMode? = nil
        var outlookReadWindow: MCPSource.Window? = nil
        var outlookExpectedMessage: String? = nil
        var outlookExpectedRecipients: [String]? = nil
        func canonicalConnectorTargets() -> Self {
            var copy = self
            copy.mcpActionServer = mcpActionServer.map(ConnectorRegistry.canonicalSlug)
            copy.mcpAttachServer = mcpAttachServer.map(ConnectorRegistry.canonicalSlug)
            copy.mcpReadConnectors = mcpReadConnectors.map(ConnectorRegistry.canonicalSlug)
            return copy
        }
        var mcpExpectedIdentity: String? = nil
        var slackExpectedMessage: String? = nil
        /// Source ingestion/inventory needs connector tools only; research keeps its vault/web access.
        var connectorOnlyRead = false
        /// Native tool-inventory classification does not need any model-accessible tools.
        var toolsDisabled = false
        var appleMailResearch: AppleMailResearch? = nil // app-owned, scoped reads for proactive research
        /// Optional narrowing for a single connector, using the current engine's bare names.
        /// Every name must already be curated; a cross-engine mismatch refuses the run.
        var mcpReadToolNames: [String]? = nil
        var mcpReadConnectors: [String] = []   // UNATTENDED READ (KB reads, probes, research):
                                               // Claude: dontAsk + allow exactly the registry's
                                               // read tools per slug, wall = those servers only
                                               // (a slug with no read list throws — fail-closed;
                                               // measured 2026-08-23: nothing short of an allow
                                               // rule approves a connector tool headless).
                                               // Codex: hermetic, only the named apps enabled,
                                               // only their separately curated reads enabled.
                                               // Missing identity or read policy refuses the run.
        var mcpAttachServer: String? = nil     // wall ONE server in with ZERO allow rules — the
                                               // classifier's inventory read (the run calls no
                                               // tools; listing your own tools needs no approval).
                                               // Claude-only in effect; needs includeUserConfig
                                               // (the strict wall blocks the connector fetch).

        var imagePaths: [String] = []          // screenshots for run(): codex attaches `-i <paths>`
                                               // (the variadic is terminated by the flag that
                                               // always follows); claude appends the screenshots
                                               // block to the prompt and Reads them (no -i flag
                                               // exists there). runAgentCommand keeps its own
                                               // parameter — this field is run()'s.

        // Claude-engine field (ignored by CodexCLI; read only when ModelBackend is .claude —
        // the Invocation is the ONE shape both engines speak, so the engine-specific knob
        // lives here rather than forking the type):
        var claudeModel: ClaudeCLI.Model? = nil       // override the tier map (heavy legs pin .opus)

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

        /// The global marketplace catalog ids for the two dedicated-chip connectors — the SAME
        /// for every user (see OpenAI's public `openai/plugins` repo, or
        /// `CODEX_HOME/plugins/cache/openai-curated-remote/<app>/<ver>/.app.json`). One source of
        /// truth: ConnectorRegistry's packs read these, and every recipe strip resolves through
        /// the registry back to them.
        static let gmailCatalogID = "connector_2128aebfecb84f64a069897515042a44"
        static let calendarCatalogID = "connector_947e0d954944416db111db556030eea6"
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

        /// The final message reduced to its JSON payload: everything outside the outermost
        /// `{…}`/`[…]` (markdown fences, stray prose) is stripped. On the ChatGPT backend
        /// (`--output-schema` server-enforced) this is the message itself; on a custom endpoint
        /// the model was only ASKED for bare JSON, so schema consumers decode from HERE —
        /// fail-closed decoding stays their job.
        var jsonResult: String {
            let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return text }
            let close: Character = text[first] == "{" ? "}" : "]"
            guard let last = text.lastIndex(of: close), last > first else { return text }
            return String(text[first...last])
        }
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
        /// The pinned client could not read a runtime cache. Repair checks the approved release;
        /// adopting a newer upstream CLI requires a Sentient update.
        case staleClient

        var description: String {
            // BOTH engines throw this type (ClaudeCLI reuses it), and these lines reach
            // user-visible surfaces (the notch's failure line, the takeover) — so the engine is
            // named at render time from the live backend. staleClient stays codex-worded: only
            // the codex spine ever throws it.
            let claude = ModelBackend.current == .claude
            let engine = claude ? "Claude Code" : "Codex"
            let binary = claude ? "claude" : "codex"
            switch self {
            case .notAvailable(let a):            return "\(engine) unavailable: \(a)"
            case .launchFailed(let m):            return "Failed to launch \(binary): \(m)"
            case .timedOut(let t):                return "\(claude ? "claude -p" : "codex exec") timed out after \(Int(t))s"
            case .exitFailure(let code, let m):   return "\(binary) exited \(code): \(m.prefix(300))"
            case .badEnvelope(let m):             return "Unparseable \(binary) output: \(m.prefix(300))"
            case .usageLimit(let m, _):
                if ModelBackend.current == .custom { return "Model usage limit: \(m.prefix(200))" }
                return "You're out of your \(claude ? "Claude" : "Codex") subscription 5 hour usage, try again later."
            case .inputTooLarge(let c):           return claude
                ? "Prompt too large for Claude Code: \(c) chars"
                : "Prompt too large for codex: \(c) chars (server cap 1,048,576)"
            case .staleClient:
                return "Codex couldn't read its runtime files. Repair it in Settings; if that persists, update Sentient."
            }
        }
    }

    // MARK: Discovery

    /// The only CLI Sentient adopts. Global, Homebrew and desktop installations stay independent.
    static var managedBinaryPath: String { CodexRuntime.executable.path }
    static func locateBinary() -> String? {
        return CodexRuntime.cliPresent ? managedBinaryPath : nil
    }

    /// `zsh -lic` (INTERACTIVE login shell — `-lc` never sources .zshrc, where nvm/asdf/volta
    /// init). Interactive shells print theme noise, so the output is scanned line-by-line for
    /// something that is actually an executable path. Watchdog-bounded; can't hang.
    /// Internal (not private): ClaudeCLI's discovery runs the same probe for its own binary.
    static func whichViaLoginShell(_ command: String) -> String? {
        guard let out = try? execute(binary: "/bin/zsh", args: ["-lic", command],
                                     stdinText: nil, cwd: nil, timeout: 5) else { return nil }
        let fm = FileManager.default
        return (out.stdout + "\n" + out.stderr)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }
    }

    // MARK: Install

    static func install(expectedVersion: String? = nil,
                        onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        if let expectedVersion, expectedVersion != CodexRuntime.release.cli.version {
            throw CodexRuntime.Failure.invalidPackage
        }
        try await CodexRuntimeInstall.install(.cli, force: true, onLine: onLine)
        return CodexRuntime.release.cli.version
    }

    // MARK: Login (setup step 2)

    /// Open the browser login against Sentient's private home. Login holds an exclusive lease
    /// so an account cannot change underneath a running task or connector refresh.
    /// OAuth URLs go only to the current setup UI, never to diagnostics.
    static func startLogin(onURL: @escaping @Sendable (URL) -> Void = { _ in },
                           onExit: @escaping @Sendable () -> Void = {}) throws -> Process {
        guard let bin = locateBinary() else { throw CLIError.notAvailable(.notInstalled) }
        let lease = try CodexRuntime.executionLease(for: bin, exclusive: true)
        if bin == CodexRuntime.executable.path { try CodexRuntime.verifyCLIForLaunch() }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.terminationHandler = { _ in lease?.unlock(); onExit() }
        proc.currentDirectoryURL = CodexRuntime.home
        proc.arguments = CodexRuntime.arguments(["login"], binary: bin)
        proc.environment = CodexRuntime.environment(richEnvironment(binDir: (bin as NSString).deletingLastPathComponent), binary: bin)
        proc.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        proc.standardOutput = output
        proc.standardError = errors
        do { try proc.run() } catch { lease?.unlock(); throw CLIError.launchFailed("\(error)") }
        LoginLink.read(output, onURL: onURL)
        LoginLink.read(errors, onURL: onURL)
        return proc
    }

    /// Confirm that the selected (or explicitly supplied) binary answers `codex --help`.
    /// Preparation uses this before accepting an existing version and after installation;
    /// an executable path alone does not establish that the CLI works.
    static func isRunnable(binary: String? = nil) async -> Bool {
        guard let bin = binary ?? locateBinary() else { return false }
        guard let out = try? await executeAsync(binary: bin, args: ["--help"],
                                                stdinText: nil, cwd: nil, timeout: 10) else { return false }
        return out.status == 0 && !out.stdout.isEmpty
    }

    /// Step 2 ground-truth check: `codex login status`, with exit status as the primary signal
    /// and an output scan as a backstop. Reads auth.json through the private CODEX_HOME and explicit file credential store.
    static func loginStatus() async -> Bool {
        guard let bin = locateBinary() else { return false }
        guard let out = try? await executeAsync(binary: bin, args: ["login", "status"],
                                                stdinText: nil, cwd: nil, timeout: 30) else { return false }
        if out.status == 0 { return true }
        let lowered = (out.stdout + out.stderr).lowercased()
        return lowered.contains("logged in") && !lowered.contains("not logged in")
    }

    // MARK: Versions (the daily update's cheap pre-check — see CodexSetup.updateIfDue)

    /// The installed CLI's version string (`codex --version` → "codex-cli 0.147.0" → "0.147.0"),
    /// or nil when there's no binary or it doesn't answer.
    static func installedVersion(binary: String? = nil) async -> String? {
        guard let bin = binary ?? locateBinary() else { return nil }
        guard let out = try? await executeAsync(binary: bin, args: ["--version"],
                                                stdinText: nil, cwd: nil, timeout: 10),
              out.status == 0 else { return nil }
        guard let version = out.stdout.split(whereSeparator: \.isWhitespace).last.map(String.init),
              version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$"#,
                            options: .regularExpression) != nil else { return nil }
        return version
    }

    /// Approved by this signed Sentient release; never resolves an upstream "latest" channel.
    static func approvedVersion() async -> String? { CodexRuntime.release.cli.version }

    /// Is `candidate` a newer release than `installed`? Semver-shaped: numeric core compared
    /// component-wise; when cores tie, a final release beats a prerelease ("0.147.0" is newer than
    /// "0.147.0-alpha.6.5", so a hand-dropped alpha still moves up to its release), and two
    /// prereleases of the same core are treated as equal (never churn between alphas).
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func split(_ v: String) -> (core: [Int], prerelease: Bool) {
            let parts = v.split(separator: "-", maxSplits: 1)
            let core = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (core, parts.count > 1)
        }
        let a = split(candidate), b = split(installed)
        let n = max(a.core.count, b.core.count)
        for i in 0..<n {
            let x = i < a.core.count ? a.core[i] : 0
            let y = i < b.core.count ? b.core[i] : 0
            if x != y { return x > y }
        }
        return !a.prerelease && b.prerelease
    }

    // MARK: Validation

    private var cachedAvailability: Availability?
    private var cachedAvailabilityFingerprint: String?

    // MARK: Diagnostics state (structure-only; see CodexDiagnostics.swift)

    /// Has ANY codex call succeeded since launch? Reported as `first_cloud_call_this_launch` on
    /// a failure (`first_cloud_call_this_launch`) — the 3 AM run's first ping of the day is a distinct population.
    private var sessionHadSuccess = false
    /// Pings since `beginDiagnosticsRun()` (the overnight run's per-night count) and the first
    /// ping's wall time — the night summary reports both.
    private var pingsThisRun = 0
    private var firstPingMS: Int?
    /// When the current diagnostics run began (nil outside an overnight run).
    private var diagnosticsRunStart: Date?
    /// `codex --version`, probed once per launch on the first ping (nil = no binary / no answer).
    private var cachedVersion: String?
    private static let launchedAt = Date()

    /// The overnight run calls this once at wake so the night's summary counts from zero.
    func beginDiagnosticsRun() {
        pingsThisRun = 0
        firstPingMS = nil
        diagnosticsRunStart = Date()
    }

    /// The counters the night summary reports (`overnight.cloud_stage`).
    func diagnosticsRunSummary() -> (pings: Int, firstPingMS: Int?, version: String?) {
        (pingsThisRun, firstPingMS, cachedVersion)
    }

    /// Is `codex exec` actually usable (installed AND — on the ChatGPT backend — logged in;
    /// on a custom backend, the endpoint answering)? Only a GOOD verdict is cached — a failed
    /// probe re-checks on every call, so codex fixed mid-session (re-login, reinstall, an
    /// endpoint coming online) is seen by the very next retry (a cached failure once made the
    /// processing screen's Retry unwinnable until relaunch — field-found 2026-07-12). The cache
    /// is keyed on the backend fingerprint, so switching backends (or editing the endpoint) in
    /// Settings invalidates a stale good verdict. `force: true` re-probes past a good cache too
    /// (e.g. right after the installer flow).
    func validate(force: Bool = false) async -> Availability {
        let fingerprint = Self.backendFingerprint()
        if !force, let cachedAvailability, cachedAvailabilityFingerprint == fingerprint {
            return cachedAvailability
        }
        // Breadcrumbs for the one call that decides "cloud is on/off" — start + verdict, timed.
        // Structure only: the model is `default` (codex's own) or `custom` (never the slug), the
        // verdict is a closed reason (never the ping's stderr).
        let backend = ModelBackend.current == .custom ? "custom" : "chatgpt"
        let budget = ModelBackend.current == .custom ? 180 : 30
        if cachedVersion == nil { cachedVersion = await Self.installedVersion() }
        Log("codex ping: start backend=\(backend) model=\(backend == "custom" ? "custom" : "default") timeout=\(budget)s trigger=\(CodexTrigger.current.rawValue) attempt=1")
        let t0 = Date()
        let result = await Self.ping()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        pingsThisRun += 1
        if firstPingMS == nil { firstPingMS = ms }
        switch result {
        case .available:
            cachedAvailability = result
            cachedAvailabilityFingerprint = fingerprint
            sessionHadSuccess = true
            Log("codex ping: available in \(ms)ms")
        case .notInstalled:
            cachedAvailability = nil
            Log("codex ping: notInstalled in \(ms)ms")
        case .notWorking(let detail):
            cachedAvailability = nil
            Log("codex ping: notWorking:\(CodexFailureReason.classify(text: detail).rawValue) in \(ms)ms")
        }
        return result
    }

    private static func backendFingerprint() -> String {
        let runtime = "\(locateBinary() ?? "")|\(CodexRuntime.home.path)|\(CodexRuntime.accountIdentity ?? "")"
        guard ModelBackend.current == .custom else { return "chatgpt|\(runtime)" }
        let p = CustomProvider.current
        return "custom|\(p.baseURL)|\(p.modelName)|\(runtime)"
    }

    /// The Frontier Model Choice pane's "Test Connection" — one call that settles BOTH questions
    /// for the saved custom endpoint (regardless of the active backend, since the pane tests
    /// before activating): does it answer, and can it SEE? A random 4-digit code is rendered to a
    /// PNG, attached with `-i`, and the model is asked to read it back. Vision is a hard
    /// requirement for a custom engine — computer use is the product and it runs on screenshots,
    /// so a blind model would fail every run with an opaque 404. `.available` here is what sets
    /// `CustomProvider.visionVerified`.
    static func probeCustomEndpoint() async -> Availability {
        await ping(forceCustom: true)
    }

    /// The error messages codex reports inside its JSON stream.
    private static func streamErrors(in stdout: String) -> [String] {
        stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  ["turn.failed", "error"].contains(obj["type"] as? String ?? "") else { return nil }
            return (obj["error"] as? [String: Any])?["message"] as? String ?? obj["message"] as? String
        }
    }

    /// What a failed codex process actually said. The stream's own error events come first:
    /// codex prints a "Reading additional input from stdin..." notice on stderr whenever it is
    /// spawned without a terminal, so stderr is never empty on a failure and would otherwise
    /// stand in for a usage limit or a login problem that the stream named precisely.
    private static func failureDetail(_ out: ExecResult) -> String {
        let errors = streamErrors(in: out.stdout)
        if !errors.isEmpty { return errors.joined(separator: " · ") }
        let stderr = out.stderr.replacingOccurrences(of: "Reading additional input from stdin...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? out.stdout : stderr
    }

    private static func ping(forceCustom: Bool = false) async -> Availability {
        guard let bin = locateBinary() else { return .notInstalled }
        let custom = forceCustom || ModelBackend.current == .custom
        var args = execArguments() + ["--json", "--ignore-user-config", "-s", Sandbox.readOnly.rawValue]
        var timeout: TimeInterval = 30
        var prompt = "Reply with exactly: PIGGYBACK_OK"
        var probeImage: (url: URL, code: String)?
        defer { if let probeImage { try? FileManager.default.removeItem(at: probeImage.url) } }

        if custom {
            let provider = CustomProvider.current
            guard provider.isConfigured else {
                return .notWorking("Custom model not configured — set a base URL and model name.")
            }
            for override in provider.providerOverrides() { args += ["-c", override] }
            // The probe rides the SAME reasoning level real runs will use (providers have hard
            // quirks either direction — a wrong level must fail HERE, not at 3am), and a local
            // server may need to load the model into memory before its first token.
            args += ["-m", provider.modelName,
                     "-c", "model_reasoning_effort=\"\(CustomProvider.reasoning)\""]
            timeout = 180
            if let made = CustomProvider.makeVisionProbeImage() {
                probeImage = made
                args += ["-i", made.url.path]      // a flag must follow, so the variadic ends here
                prompt = "Read the 4 digits in the attached image. Reply with EXACTLY those 4 digits and nothing else."
            }
        }
        args += ["--skip-git-repo-check", prompt]
        do {
            let out = try await executeAsync(binary: bin, args: args,
                                             stdinText: nil, cwd: nil, timeout: timeout)
            if let probeImage {
                guard out.status == 0 else {
                    let detail = failureDetail(out)
                    return .notWorking(String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
                }
                // The model must have READ the code — proof it sees screenshots, not just that
                // the endpoint tolerated an image part.
                guard out.stdout.contains(probeImage.code) else {
                    return .notWorking("blind: the model answered but could not read the test image")
                }
                return .available(path: bin)
            }
            if out.status == 0 && out.stdout.contains("PIGGYBACK_OK") { return .available(path: bin) }
            let detail = failureDetail(out)
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
        let (modelID, effortArg) = Self.backendTuned(model: invocation.model,
                                                     effort: invocation.effort)
        if ModelBackend.current == .custom {
            // The custom endpoint rides the existing plumbing: the provider table + guards as
            // per-run `-c` overrides, and NO web_search (an OpenAI-server-side tool — a foreign
            // endpoint either rejects or silently drops it).
            invocation.configOverrides += CustomProvider.current.providerOverrides()
            invocation.webSearch = false
            // Hermetic: a ChatGPT-logged-in Mac otherwise loads every hosted-connector plugin
            // into the run (hundreds of KB of tool specs — a context bomb for a 63k local
            // model, and dead weight everywhere: connectors are ChatGPT-only). Computer use is
            // unaffected — it rides runAgentCommand, which keeps the user config.
            invocation.includeUserConfig = false
            // `--output-schema` is unreliable off-OpenAI (several Responses shims accept the
            // schema and ignore it; codex's schema path hung against LM Studio — measured
            // 2026-07-24). The schema becomes a prompt instruction; Envelope.jsonResult is the
            // tolerant parse seam consumers decode from (fail-closed decoding stays theirs).
            if let schema = invocation.outputSchema {
                invocation.outputSchema = nil
                invocation.prompt += "\n\nReply with ONLY a single JSON value that validates "
                    + "against this JSON Schema; no prose, no markdown fences:\n\(schema)"
            }
        }
        let t0 = Date()   // §7.9: for the codex.failure duration on the throw path
        do {
            return try await runInner(invocation, modelID: modelID, effortArg: effortArg,
                                      onLine: onLine)
        } catch {
            // A cancelled Task is the user's STOP: the SIGTERM'd process exits non-zero, which
            // masqueraded as a real exitFailure in Sentry (field-found 2026-07-12). Not a defect.
            if !Task.isCancelled {
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                Log("codex exec: \(CodexFailureReason.classify(error).rawValue) feature=\(invocation.feature) in \(ms)ms")
                emitCodexFailure(event: "codex.failure", error, feature: invocation.feature,
                                 modelID: modelID, effort: effortArg,
                                 resumed: invocation.resumeSessionID != nil,
                                 durationMS: ms, timeoutS: Int(invocation.timeout), diag: invocation.diag)
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

    private func runInner(_ invocation: Invocation, modelID: String, effortArg: String,
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
        // One breadcrumb per exec, start + end — the shape of the run, never its content. On the
        // custom backend the model is reported as `custom` (a user's model slug is free text).
        let modelTag = ModelBackend.current == .custom ? "custom" : modelID
        Log("codex exec: start feature=\(invocation.feature) model=\(modelTag) effort=\(effortArg) resume=\(invocation.resumeSessionID != nil) sandbox=\(invocation.sandbox.rawValue) prompt_kb=\(invocation.prompt.utf8.count / 1024) trigger=\(CodexTrigger.current.rawValue)")
        // When a caller wants live play-by-play, adapt each raw --json line into a readable one.
        let stdoutLine: (@Sendable (String) -> Void)? = onLine.map { sink in
            { @Sendable raw in if let s = Self.humanLine(fromJSONL: raw) { sink(s) } }
        }
        let out = try await Self.executeAsync(binary: bin,
                                              args: try Self.arguments(for: invocation, modelID: modelID,
                                                                   effortArg: effortArg,
                                                                   schemaFile: schemaFile),
                                              stdinText: invocation.prompt,
                                              cwd: invocation.cwd,
                                              timeout: invocation.timeout,
                                              onStdoutLine: stdoutLine)
        let env = try Self.parseEnvelope(out, durationMS: Int(Date().timeIntervalSince(started) * 1000))
        sessionHadSuccess = true
        Log("codex exec: ok feature=\(invocation.feature) in \(env.durationMS ?? -1)ms turns=\(env.numTurns ?? -1) out=\(env.outputTokens ?? -1)")
        return env
    }

    /// Computer-use argv for the shared streaming `codex exec` path and required native MCP client.
    /// FrontierRun supplies the native runtime's manual. User config stays isolated while
    /// hosted/direct connector policies and the speed preference remain attached to each run.
    /// Computer-use approval bypass is confined to this user-fired path, with one task and STOP.
    /// Optional screenshots precede --skip-git-repo-check to terminate -i's variadic arguments.
    /// The computer-use argv — extracted so the connector lab can print the recipe without
    /// spawning, and so the destructive strips are one readable place. On the ChatGPT backend
    /// every known catalog id — the two pinned chip connectors plus everything the census
    /// detected — gets `apps.<id>.destructive_enabled=false` (task 1.6), so a user-fired
    /// computer-use run keeps constructive connector writes (send, create) while
    /// delete/trash-class tools are stripped from the surface entirely. An id the account
    /// doesn't carry makes the strip an inert no-op (measured), so unlinked chips cost nothing.
    static func agentArguments(prompt: String, imagePaths: [String], modelID: String,
                               effortArg: String,
                               providerOverrides: [String] = [],
                               nativeConfiguration: OpenAIComputerUse.Configuration? = nil) throws -> [String] {
        var args = (ModelBackend.current == .claude ? ["exec"] : execArguments()) + ["--json", "--dangerously-bypass-approvals-and-sandbox",
                    "-m", modelID,
                    "-c", "model_reasoning_effort=\"\(effortArg)\"",
                    "--ignore-user-config", "-c", "project_doc_max_bytes=0"]
        for override in try (nativeConfiguration ?? .resolve()).codexOverrides { args += ["-c", override] }
        for override in DirectMCPRuntime.codexOverrides(DirectMCPRuntime.current) { args += ["-c", override] }
        if ModelBackend.current == .chatgpt {
            var hooks: [HostedToolPolicy.Rule] = []
            var ids = [Invocation.gmailCatalogID, Invocation.calendarCatalogID]
            ids += ConnectorCensus.cached(for: .chatgpt).compactMap(\.catalogID)
            for id in ids { args += ["-c", "apps.\(id).destructive_enabled=false"] }
            if ConnectorCensus.cached(for: .chatgpt).contains(where: { $0.slug == "slack" }) {
                if let policy = try? SlackConnector.codexActionPolicy(exclusive: false) { args += ["-c", policy] }
                hooks.append(SlackToolPolicy.rule(backend: .chatgpt))
            }
            if ConnectorCensus.cached(for: .chatgpt).contains(where: { $0.slug == OutlookMailConnector.slug }) {
                if let policy = try? OutlookMailConnector.codexPolicy(operation: .write, exclusive: false) {
                    args += ["-c", policy]
                }
            }
            let mail = ConnectorCensus.cached(for: .chatgpt).contains { $0.slug == OutlookMailConnector.slug }
            let calendar = ConnectorCensus.cached(for: .chatgpt).contains { $0.slug == OutlookCalendarConnector.slug }
            if calendar, let policy = try? OutlookCalendarConnector.codexPolicy(operation: .read, exclusive: false) {
                args += ["-c", policy]
            }
            if mail || calendar {
                hooks.append(OutlookToolPolicy.rule(backend: .chatgpt, operation: .write,
                    runID: OutlookToolPolicy.computerRunID ?? UUID(),
                    calendar: calendar ? .init(operation: .read) : nil, includesMail: mail))
            }
            args += HostedToolPolicy.codexArguments(hooks)
        }
        if ModelBackend.current == .custom {
            for override in CustomProvider.current.providerOverrides() { args += ["-c", override] }
        }
        for override in providerOverrides { args += ["-c", override] }
        if !imagePaths.isEmpty { args += ["-i"] + imagePaths }   // followed by a flag → the variadic stops here
        args += ["--skip-git-repo-check", prompt]
        return args
    }

    func runAgentCommand(_ prompt: String, imagePaths: [String] = [], timeout: TimeInterval = 1_800,
                         onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        let t0 = Date()
        let backend = ModelBackend.current
        var nativeTask: UUID?
        var nativeLease: CodexRuntime.FileLock?
        defer { nativeLease?.unlock() }
        let (model, effort) = ComputerUseSpeed.current.codexModelAndEffort
        let (modelID, effortArg) = backend == .claude ? ClaudeCLI.agentTuned() : Self.backendTuned(model: model, effort: effort)
        var bridge: ClaudeSubscriptionBridge?
        do {
            if prompt.utf8.count > Self.promptByteCap { throw CLIError.inputTooLarge(chars: prompt.utf8.count) }
            guard await ComputerUseSetup.instance(for: .openAI).ensureInstalled() else {
                try Task.checkCancellation()
                let error = await ComputerUseSetup.instance(for: .openAI).failure
                throw error ?? OpenAIComputerUse.RuntimeError.incomplete
            }
            try Task.checkCancellation()
            nativeLease = try await CodexRuntime.sharedRuntimeLease()
            let nativeConfiguration = try OpenAIComputerUse.Configuration.resolve()
            nativeTask = try await OpenAIComputerUseRuntime.shared.beginTask(configuration: nativeConfiguration)
            try Task.checkCancellation()
            var overrides = SidekickToolServer.connection?.codexOverrides ?? []
            var environment = nativeConfiguration.clientEnvironment
            if backend == .claude {
                guard let claude = ClaudeCLI.locateBinary() else { throw CLIError.notAvailable(.notInstalled) }
                // Claude supplies readable progress; Codex's structured events still carry
                // tool activity needed by Sidekick recovery.
                onLine("codex")
                let namespaces = Set(["mcp__sentient_native"] + DirectMCPRuntime.current.map { "mcp__" + $0.connection.serverName }
                    + (SidekickToolServer.connection == nil ? [] : ["mcp__sentient_recovery"]))
                let relay = ClaudeSubscriptionBridge(binary: claude, model: modelID, effort: effortArg,
                    timeout: timeout, namespaces: namespaces, onProgress: onLine)
                bridge = relay
                let configuration = try await relay.start()
                overrides += configuration.overrides
                environment.merge(configuration.environment) { _, new in new }
            }
            let args = try Self.agentArguments(prompt: prompt, imagePaths: imagePaths,
                modelID: modelID, effortArg: effortArg, providerOverrides: overrides,
                nativeConfiguration: nativeConfiguration)
            let modelTag = backend == .custom ? "custom" : modelID
            Log("codex exec: start feature=computer runtime=openAI model=\(modelTag) effort=\(effortArg) resume=false sandbox=bypass prompt_kb=\(prompt.utf8.count / 1024) images=\(imagePaths.count) trigger=\(CodexTrigger.current.rawValue)")
            let ownedBridge = bridge
            let out = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await ComputerUseStream.run(binary: nativeConfiguration.cliURL.path, args: args, timeout: timeout,
                    extraEnv: environment, narrate: backend != .claude, onLine: onLine)
            } onCancel: {
                // Cancel inference even when Codex is between HTTP requests or waiting on a tool.
                Task { await ownedBridge?.stop() }
            }
            try Task.checkCancellation()
            if let error = await bridge?.failure { throw error }
            await bridge?.stop()
            if let nativeTask { await OpenAIComputerUseRuntime.shared.endTask(nativeTask) }
            nativeTask = nil
            Self.noteStaleSignatureIfPresent(out.stderr)
            if let error = Self.agentFailure(out) { throw error }
            let result = try Self.parseEnvelope(out, durationMS: Int(Date().timeIntervalSince(t0) * 1000)).result
            sessionHadSuccess = true
            Log("codex exec: ok feature=computer in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            return result
        } catch {
            await bridge?.stop()
            if let nativeTask { await OpenAIComputerUseRuntime.shared.endTask(nativeTask) }
            if Task.isCancelled { throw CancellationError() }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            Log("codex exec: \(CodexFailureReason.classify(error).rawValue) feature=computer in \(ms)ms")
            emitCodexFailure(event: "codex.agent_command", error, feature: "computer",
                modelID: modelID, effort: effortArg, resumed: false, durationMS: ms, timeoutS: Int(timeout))
            throw error
        }
    }

    /// Emit a structured codex failure. One seam for the whole cloud spine. Every value is an
    /// enum / bool / int / version string — never `.message`, stderr, the prompt, a token, or an
    /// account id (the free text is classified into `CodexFailureReason` on the Mac and dropped).
    /// `feature` makes it attributable; `diag` is the caller's structured extras (Invocation.diag —
    /// ints/enums only, pre-vetted). On the custom backend the model tag reports the literal
    /// "custom" — a user's model slug (or a private deployment name) is free text.
    ///
    /// Tags (indexed): feature · error (case) · model · backend · phase (ping|exec) · availability
    /// (notInstalled|notWorking|n/a) · reason (CodexFailureReason) · trigger (CodexTrigger) ·
    /// network / interface (NetworkSnapshot) · login_mode / plan / access_expired
    /// (CodexAuthSnapshot; keys avoid the scrubber words auth/token/session) · codex_version.
    /// Extras: exit_code · duration_ms · timeout_s · attempt · effort · resumed ·
    /// mins_since_last_refresh · has_refresh · secs_since_wake ·
    /// first_cloud_call_this_launch · hours_since_launch · ping_model · pings_this_run (+ diag).
    /// Fingerprint: [codex, feature, case, reason, trigger] — so a 3 AM `token_expired` and an
    /// onboarding `not_logged_in` are different issues.
    private func emitCodexFailure(event: String, _ error: Error, feature: String,
                                  modelID: String, effort: String, resumed: Bool, durationMS: Int,
                                  timeoutS: Int? = nil, diag: [String: String] = [:]) {
        let caseName: String
        let level: CrashReporting.DiagLevel
        var extra = diag
        var availability = "n/a"
        var phase = "exec"
        switch error {
        case CLIError.usageLimit:   return   // expected, not a defect — the amber caution + resume own it
        case CLIError.notAvailable(let a):
            (caseName, level) = ("notAvailable", .warning)
            phase = "ping"
            switch a {
            case .notInstalled: availability = "notInstalled"
            case .notWorking:   availability = "notWorking"
            case .available:    availability = "available"
            }
        case CLIError.timedOut:     (caseName, level) = ("timedOut", .warning)
        case CLIError.launchFailed: (caseName, level) = ("launchFailed", .error)
        case CLIError.exitFailure(let code, _):
            (caseName, level) = ("exitFailure", .error)
            extra["exit_code"] = String(code)
        case CLIError.badEnvelope:  (caseName, level) = ("badEnvelope", .error)
        case CLIError.staleClient:
            (caseName, level) = ("staleClient", .warning)
        case CLIError.inputTooLarge(let chars):
            // The canary: every prompt path is byte-budgeted, so this should stay at zero.
            (caseName, level) = ("inputTooLarge", .error)
            extra["prompt_chars"] = String(chars)
        default:                    (caseName, level) = (String(describing: type(of: error)), .error)
        }
        let reason = CodexFailureReason.classify(error)
        let trigger = CodexTrigger.current
        if phase == "ping", trigger == .probe, [.notInstalled, .notLoggedIn, .planDenied].contains(reason) { return }
        let net = NetworkSnapshot.shared.current
        let auth = CodexAuthSnapshot.read()
        let custom = ModelBackend.current == .custom

        extra["effort"] = effort
        extra["resumed"] = String(resumed)
        extra["duration_ms"] = String(durationMS)
        extra["timeout_s"] = String(phase == "ping" ? (custom ? 180 : 30) : (timeoutS ?? -1))
        extra["attempt"] = "1"
        extra["ping_model"] = custom ? "custom" : "default"
        extra["pings_this_run"] = String(pingsThisRun)
        extra["first_cloud_call_this_launch"] = String(!sessionHadSuccess)   // not "*_session": a scrubber word
        extra["hours_since_launch"] = String(Int(Date().timeIntervalSince(Self.launchedAt) / 3600))
        extra["secs_since_wake"] = diagnosticsRunStart.map { String(Int(Date().timeIntervalSince($0))) } ?? "-1"
        // Attribute a dependency regression to the runtime this run actually selected.
        if feature == "computer" {
            let runtime = ComputerUseBackend.selected(for: ModelBackend.current)
            extra["computer_runtime"] = runtime.rawValue
            if runtime == .cua { extra["cua_driver"] = CuaDriver.version }
            else {
                extra["helper_version"] = CodexRuntime.release.helper.version
                extra["helper_build"] = String(CodexRuntime.release.helperBuild)
            }
        }
        if ModelBackend.current != .claude { extra.merge(auth.extras) { cur, _ in cur } }

        var tags: [String: String] = [
            "feature": feature,
            "error": caseName,
            "model": ModelBackend.current == .claude ? "claude_subscription" : (custom ? "custom" : modelID),
            "backend": ModelBackend.current.rawValue,
            "phase": phase,
            "availability": availability,
            "reason": reason.rawValue,
            "trigger": trigger.rawValue,
            "network": net.status,
            "interface": net.interface,
            "codex_version": cachedVersion ?? "unknown",
        ]
        if ModelBackend.current == .claude {
            tags["login_mode"] = "claude_subscription"
            tags["plan"] = ClaudeAuth.cachedPlan ?? "unknown"
        } else { tags.merge(auth.tags) { cur, _ in cur } }
        Diagnostics.current?.markReported(error)
        CrashReporting.captureEvent(event, level: level, tags: tags, extra: extra,
            fingerprint: ["codex", ModelBackend.current.rawValue, feature, caseName, reason.rawValue, trigger.rawValue])
    }

    /// Fast mode applies to every Exec path, including probes and resumed sessions.
    /// This is a per-run override; the user's Codex configuration is never changed.
    private static func execArguments(resumeSessionID: String? = nil) -> [String] {
        var args = ["exec"]
        if let resumeSessionID { args += ["resume", resumeSessionID] }
        args += ["-c", #"service_tier="fast""#]
        return args
    }

    /// `exec resume` accepts only a subset of `exec`'s flags — no `-s`/`--cd`/`--add-dir`.
    /// [MEASURED] A resumed session's workspace root is the PROCESS cwd (not the remembered
    /// one), so `execute`'s cwd is load-bearing there, and the sandbox rides the
    /// `sandbox_mode` config key instead of `-s`.
    ///
    /// The connector run recipes, codex column (the README table in the Step 1 plan; the
    /// Claude column lives in ClaudeCLI.arguments):
    ///  ┌─────────────────┬────────────────────────────────────────────────────────────────┐
    ///  │ UNATTENDED READ │ Hermetic config + disabled-by-default apps and tools. Only    │
    ///  │ mcpReadConnectors│ the requested apps' verified Codex reads are enabled.         │
    ///  │                 │ Unknown identity/policy refuses the run. Read-only filesystem │
    ///  │                 │ sandbox remains; connector writes use a separate tool policy. │
    ///  ├─────────────────┼────────────────────────────────────────────────────────────────┤
    ///  │ FIRED TASK      │ `apps.<id>.default_tools_approval_mode="approve"` when the id  │
    ///  │ mcpActionServer │ resolves (server-scoped write approval), else the shipped      │
    ///  │                 │ id-free `apps._default` preset; + the destructive strip for    │
    ///  │                 │ that id. Sandbox stays ON (a real Gmail send worked under      │
    ///  │                 │ `-s read-only`, measured 2026-07-18).                          │
    ///  ├─────────────────┼────────────────────────────────────────────────────────────────┤
    ///  │ COMPUTER USE    │ agentArguments below: the shipped hermetic bypass run + (when  │
    ///  │ (runAgentCommand)│ widened) destructive strips for every known catalog id.       │
    ///  └─────────────────┴────────────────────────────────────────────────────────────────┘
    /// Internal (not private) so the connector lab's argv command can print recipes without
    /// spawning (Self Tests - Temp; may return to private when the lab is deleted at Step 4).
    static func arguments(for inv: Invocation, modelID: String, effortArg: String,
                          schemaFile: String?) throws -> [String] {
        try ResearchToolServer.validateInvocation(inv)
        let inv = inv.canonicalConnectorTargets()
        if inv.mcpReadToolNames != nil, inv.mcpReadConnectors.count != 1 {
            throw CLIError.notAvailable(.notWorking("read-tool narrowing requires one connector"))
        }
        if inv.connectorOnlyRead {
            guard !inv.bypassApprovals, inv.sandbox == .readOnly, !inv.webSearch,
                  inv.mcpActionServer == nil, !inv.mcpReadConnectors.isEmpty else {
                throw CLIError.notAvailable(.notWorking("invalid connector-only read configuration"))
            }
        }
        let direct = DirectMCPRuntime.current
        let requestedDirect = Set((inv.mcpReadConnectors + [inv.mcpActionServer].compactMap { $0 }).filter { $0.hasPrefix("direct-") })
        guard requestedDirect.isSubset(of: Set(direct.map(\.requestedTarget))) else { throw DirectMCPError.policyUnavailable }
        let hostedReads = inv.mcpReadConnectors.filter { !$0.hasPrefix("direct-") }
        if !direct.isEmpty, ModelBackend.current == .custom, !hostedReads.isEmpty {
            throw CLIError.notAvailable(.notWorking("hosted connectors are unavailable on a custom backend"))
        }
        let connectorRead = !inv.mcpReadConnectors.isEmpty && (ModelBackend.current == .chatgpt || !direct.isEmpty)
        if connectorRead {
            guard inv.sandbox == .readOnly, !inv.bypassApprovals,
                  inv.mcpActionServer == nil, inv.mcpAttachServer == nil else {
                throw CLIError.notAvailable(.notWorking("invalid unattended connector configuration"))
            }
        }
        assert([inv.mcpActionServer != nil, !inv.mcpReadConnectors.isEmpty,
                inv.mcpAttachServer != nil].filter { $0 }.count <= 1,
               "the connector recipe fields are mutually exclusive")
        assert(!(inv.bypassApprovals && (inv.mcpActionServer != nil || !inv.mcpReadConnectors.isEmpty)),
               "the sandboxed connector recipes never bypass approvals")
        assert(inv.mcpReadConnectors.isEmpty || inv.sandbox == .readOnly,
               "an unattended read is read-only by definition")
        var args = execArguments(resumeSessionID: inv.resumeSessionID)
        args += ["--json",
                 "--skip-git-repo-check",      // staging dirs and the vault aren't git repos
                 "-m", modelID,
                 "-c", "model_reasoning_effort=\"\(effortArg)\""]
        // Screenshots (run()'s optional eyes). Placed HERE because `-i` is variadic and every
        // path below continues with a flag (--ignore-user-config, the bypass flag, or a -c),
        // which terminates it — the same dodge as probeCustomEndpoint's probe image.
        if !inv.imagePaths.isEmpty { args += ["-i"] + inv.imagePaths }
        if !inv.includeUserConfig || connectorRead || ["slack", OutlookMailConnector.slug, OutlookCalendarConnector.slug].contains(inv.mcpActionServer ?? "") || !direct.isEmpty || inv.toolsDisabled || ResearchToolServer.connection != nil {
            // Hosted account apps survive hermetic runs. User MCP servers, plugins and
            // per-tool/account approvals must not widen an unattended read's tool policy.
            args += ["--ignore-user-config"]
        }

        // Approvals + sandbox. `codex exec` is headless and can't answer an approval prompt:
        //  · default → `approval_policy=never` (don't stall) + the Seatbelt sandbox (`-s`) as the
        //    guardrail for shell/file ops. Remote connector capabilities are controlled by
        //    the read/action policies below, independently of the filesystem sandbox.
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
        if inv.connectorOnlyRead || inv.toolsDisabled || Microsoft365Connector.contains(inv.mcpActionServer ?? "") || ResearchToolServer.connection != nil {
            for override in ["project_doc_max_bytes=0", "features.shell_tool=false", "features.view_image=false",
                             "features.browser_use=false", "features.computer_use=false", "features.multi_agent=false",
                             "features.code_mode=false", "features.image_generation=false", "features.goals=false",
                             "features.skill_search=false", "web_search=\"disabled\""] {
                args += ["-c", override]
            }
        }
        if inv.connectorOnlyRead, inv.mcpReadConnectors == ["slack"] {
            args += ["-c", "features.tool_search=false"]
        }
        // The connector recipes (table above). ChatGPT backend only: hosted connectors ride
        // ChatGPT-account auth, so on a custom endpoint (hermetic anyway) the fields are inert.
        if ModelBackend.current == .chatgpt {
            if let slug = inv.mcpActionServer, !slug.hasPrefix("direct-") {
                if slug == "slack" {
                    args += ["-c", try SlackConnector.codexActionPolicy(operation: inv.slackOperation ?? .write)]
                    args += SlackToolPolicy.codexArguments(operation: inv.slackOperation ?? .write, runID: inv.slackRunID,
                                                          expectedMessage: inv.slackExpectedMessage)
                } else if slug == OutlookCalendarConnector.slug {
                    guard let operation = inv.outlookCalendarOperation else { throw MCPSource.MCPError.noReadSurface(slug: slug) }
                    args += ["-c", try OutlookCalendarConnector.codexPolicy(operation: operation)]
                } else if slug == OutlookMailConnector.slug {
                    guard let operation = inv.outlookOperation else { throw MCPSource.MCPError.noReadSurface(slug: slug) }
                    args += ["-c", try OutlookMailConnector.codexPolicy(operation: operation)]
                } else if let id = ConnectorRegistry.server(for: slug)?.codexCatalogID {
                    args += ["-c", "apps.\(id).default_tools_approval_mode=\"approve\"",
                             "-c", "apps.\(id).destructive_enabled=false"]
                } else {
                    // No known id → the shipped id-free preset (approves every connector's
                    // writes for this one app-authored, single-declared-action run).
                    for override in Invocation.approveConnectorWrites { args += ["-c", override] }
                }
            }
            if connectorRead {
                args += ["-c", try connectorReadPolicy(slugs: hostedReads, subset: inv.mcpReadToolNames)]
            }
            if inv.includesOutlookMail || inv.calendarPolicy != nil {
                args += HostedToolPolicy.codexArguments([OutlookToolPolicy.rule(backend: .chatgpt,
                    operation: inv.mcpActionServer == nil ? .read : (inv.outlookOperation ?? .read), runID: inv.outlookRunID ?? UUID(),
                    mode: inv.outlookReadMode, window: inv.outlookReadWindow, expectedMessage: inv.outlookExpectedMessage,
                    expectedRecipients: inv.outlookExpectedRecipients, calendar: inv.calendarPolicy, includesMail: inv.includesOutlookMail)])
            }
        }
        if inv.toolsDisabled || (!direct.isEmpty && ModelBackend.current == .custom) || (inv.mcpActionServer?.hasPrefix("direct-") == true) {
            args += ["-c", "features.apps=false", "-c", "apps._default.enabled=false"]
        }
        for override in DirectMCPRuntime.codexOverrides(direct) { args += ["-c", override] }
        if let connection = ResearchToolServer.connection {
            args += ["--ephemeral"]
            if inv.mcpReadConnectors.isEmpty { args += ["-c", "features.apps=false", "-c", "apps._default.enabled=false"] }
            for override in connection.codexOverrides { args += ["-c", override] }
        }
        if inv.webSearch {
            args += ["-c", "tools.web_search=true"]
            if ResearchToolServer.connection != nil { args += ["-c", "web_search=\"live\""] }
        }
        if let schemaFile { args += ["--output-schema", schemaFile] }
        args.append("-")                       // the prompt arrives on stdin
        return args
    }

    /// One complete override replaces inherited app, account and tool approvals. Quoted tool
    /// keys live INSIDE the TOML value: CLI dotted paths cannot safely address dotted names.
    /// New apps/tools remain disabled. `writes` additionally refuses an allowed tool if its
    /// read-only annotation disappears or changes. No classifier fallback on unattended runs.
    private static func connectorReadPolicy(slugs: [String], subset: [String]? = nil) throws -> String {
        var entries = ["_default = { enabled = false }"]
        var ids = Set<String>()
        for slug in Set(slugs).sorted() {
            guard let pack = ConnectorRegistry.pack(forSlug: slug), !pack.capturedProvisional,
                  let reads = pack.codexReadTools, !reads.isEmpty,
                  let id = ConnectorRegistry.server(for: slug)?.codexCatalogID,
                  ConnectorRegistry.isValidCodexCatalogID(id),
                  ids.insert(id).inserted,
                  reads.allSatisfy({ $0.range(of: "^[A-Za-z_][A-Za-z0-9_./-]*\\z",
                                              options: .regularExpression) != nil }) else {
                throw CLIError.notAvailable(.notWorking("connector \(slug) has no verified Codex read policy"))
            }
            let selected = subset ?? reads
            guard !selected.isEmpty, Set(selected).isSubset(of: Set(reads)) else {
                throw CLIError.notAvailable(.notWorking("read-tool narrowing cannot widen the curated policy"))
            }
            let tools = Set(selected).sorted().map {
                "\"\($0)\" = { enabled = true, approval_mode = \"writes\" }"
            }.joined(separator: ", ")
            entries.append("\(id) = { enabled = true, default_tools_enabled = false, "
                + "default_tools_approval_mode = \"writes\", tools = { \(tools) } }")
        }
        return "apps = { \(entries.joined(separator: ", ")) }"
    }

    // MARK: JSONL parsing

    private static let usageLimitMarkers = ["usage limit", "usage_limit_reached", "rate limit",
                                            "rate_limit_exceeded", "limit reached", "limit resets", "quota", "too many requests",
                                            "out of extra usage", "plan limit"]

    /// Read structured terminal failures, with ERROR lines retained for legacy callers.
    /// Prompt echoes and ordinary tool output must not become usage-limit errors.
    static func agentFailure(_ out: ExecResult) -> CLIError? {
        guard out.status != 0 else { return nil }
        func lastErrorLine(in text: String) -> String? {
            text.split(separator: "\n").reversed()
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.hasPrefix("ERROR:") }
        }
        let terminalError = streamErrors(in: out.stdout).last
            ?? lastErrorLine(in: out.stderr) ?? lastErrorLine(in: out.stdout)
        let detail = terminalError ?? failureDetail(out)
        if let terminalError,
           usageLimitMarkers.contains(where: { terminalError.lowercased().contains($0) }) {
            return .usageLimit(message: String(detail.prefix(600)), sessionID: nil)
        }
        if let stale = staleClientError(in: out.stderr, detail) { return stale }
        return .exitFailure(code: out.status, message: String(detail.prefix(600)))
    }

    /// The stale-client signature: an older CLI failing to deserialize a `~/.codex` cache a newer
    /// codex wrote (field-found on 1.3: `codex_models_manager: failed to renew cache TTL: missing
    /// field \`base_instructions\``, after the ChatGPT desktop app's bundled CLI rewrote
    /// `models_cache.json`; reproduced 2026-08-17 as `failed to load models cache: missing field
    /// \`base_instructions\`` on 0.144.6 against a 0.147.0 cache). Deliberately narrow: only
    /// serde's "missing field" WITH the cache context, never any "missing field" (a bad `-c`
    /// override says that too), so it can't misfire on our own config mistakes.
    private static func isStaleClientSignature(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("failed to renew cache ttl") { return true }
        return lowered.contains("missing field `") && lowered.contains("cache")
    }

    /// The run's stderr carries the signature, whatever the outcome (measured: an older CLI logs
    /// the cache error, refetches, and usually finishes fine). Drifting: tell CodexSetup so the
    /// next idle tick updates ahead of the daily cap. No error, no banner — a FAILED run is
    /// classified separately below.
    private static func noteStaleSignatureIfPresent(_ stderr: String) {
        guard isStaleClientSignature(stderr) else { return }
        Task { @MainActor in CodexSetup.shared.noteStaleSignal() }
    }

    /// Flag a failed run with the cache signature and check the approved private package.
    /// Returns nil when the failure has another cause.
    private static func staleClientError(in texts: String...) -> CLIError? {
        guard texts.contains(where: isStaleClientSignature) else { return nil }
        Task { @MainActor in await CodexSetup.shared.repairStaleClient() }   // logs there
        return .staleClient
    }

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

        noteStaleSignatureIfPresent(out.stderr)   // success or failure: the drift nudge either way

        // Failure = non-zero exit OR no final message (a recovered mid-run error that still
        // produced an answer with exit 0 counts as success). The thread id arrives in the very
        // first event, so even a mid-run usage limit keeps its resume handle.
        if out.status != 0 || lastMessage == nil {
            let detail = errors.isEmpty ? failureDetail(out) : errors.joined(separator: " · ")
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
            // The cache-schema error lands on stderr (tracing), which `detail` skips when the JSONL
            // carried its own error message — so check both.
            if let stale = staleClientError(in: out.stderr, detail) { throw stale }
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
    /// and session vars (the cua daemon's socket and the shim's screenshot drop-box resolve against
    /// the real per-user temp and caches paths); `codex login` needs the same so the browser launch
    /// works. The binary's own dir leads PATH (npm shims `#!/usr/bin/env node` right next to
    /// themselves). Internal (not private): ClaudeCLI's login + agent runs need the same context.
    static func richEnvironment(binDir: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let richPath = [binDir,
                        "\(home)/.local/bin",
                        "/opt/homebrew/bin", "/opt/homebrew/sbin",
                        "/usr/local/bin",
                        "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["PATH"] = env["PATH"].map { "\(richPath):\($0)" } ?? richPath
        // Same unconditional endpoint-key injection as the sanitized env (see execute()).
        env[CustomProvider.apiKeyEnvName] = CustomProvider.apiKeyEnvValue
        env[ChildProcessDiagnostics.environmentKey] = ChildProcessDiagnostics.directory?.path
        if ChildProcessDiagnostics.directory != nil { env["TMPDIR"] = FileManager.default.temporaryDirectory.path }
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

    /// Internal (not private): this and `executeStreaming` are the engine-neutral process plumbing
    /// (sanitized env, watchdog, cancellation, multibyte-safe line streaming) that ClaudeCLI — the
    /// parallel `claude -p` engine — reuses verbatim rather than duplicating. `extraEnv` lets an
    /// engine add its own variables (Claude: updater/telemetry kill switches) without forking this.
    static func executeAsync(binary: String, args: [String], stdinText: String?,
                             cwd: String?, timeout: TimeInterval,
                             extraEnv: [String: String] = [:],
                             includeCustomProviderKey: Bool = true,
                             terminationGrace: TimeInterval = 1,
                             retainStdoutLine: (@Sendable (String) -> Bool)? = nil,
                             onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ExecResult {
        // Honor Task cancellation (a card's STOP): terminate the child so an in-flight send/action stops.
        let holder = ProcHolder(terminationGrace: terminationGrace)
        let childDirectory = ChildProcessDiagnostics.directory
        let interaction = SidekickInteraction.current
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: try ChildProcessDiagnostics.$directory.withValue(childDirectory) { try execute(binary: binary, args: args, stdinText: stdinText,
                                                            cwd: cwd, timeout: timeout, extraEnv: extraEnv,
                                                            includeCustomProviderKey: includeCustomProviderKey,
                                                            retainStdoutLine: retainStdoutLine,
                                                            onStdoutLine: onStdoutLine, procHolder: holder, interaction: interaction) }) }
                    catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: { holder.terminate() }
    }

    /// Blocking runner (call off-main). GUI-spawned `Process` works with a SANITIZED env —
    /// HOME/USER + the system PATH and the absolute binary path. Codex additionally receives
    /// the private CODEX_HOME and explicit credential settings; no TTY is needed.
    private static func execute(binary: String, args: [String], stdinText: String?,
                                cwd: String?, timeout: TimeInterval,
                                extraEnv: [String: String] = [:],
                                includeCustomProviderKey: Bool = true,
                                retainStdoutLine: (@Sendable (String) -> Bool)? = nil,
                                onStdoutLine: (@Sendable (String) -> Void)? = nil,
                                procHolder: ProcHolder? = nil, interaction: SidekickInteraction? = nil) throws -> ExecResult {
        let lease = try CodexRuntime.executionLease(for: binary, cancelled: { procHolder?.isCancelled == true })
        defer { lease?.unlock() }
        if binary == CodexRuntime.executable.path { try CodexRuntime.verifyCLIForLaunch() }
        if procHolder?.isCancelled == true { throw CancellationError() }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = CodexRuntime.arguments(args, binary: binary)
        // The binary's OWN directory leads the sanitized PATH: npm installs are
        // `#!/usr/bin/env node` shims, and (in the nvm layout) `node` sits right next to
        // them — without this, the shim exec-fails even when found.
        let binDir = (binary as NSString).deletingLastPathComponent
        var env: [String: String] = [:]
        let current = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER"] where current[key] != nil { env[key] = current[key] }
        env["PATH"] = [binDir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        // The custom endpoint's key rides the env var the provider table's `env_key` names —
        // injected UNCONDITIONALLY: codex ignores it unless a run's provider references it, and
        // the pane's pre-activation Test Connection probes the custom path while ChatGPT is
        // still the active backend. (codex hard-errors on an unset/empty env_key var; a value
        // here also blocks the ChatGPT-token fallthrough on keyless local servers.)
        if includeCustomProviderKey { env[CustomProvider.apiKeyEnvName] = CustomProvider.apiKeyEnvValue }
        env.merge(extraEnv) { _, new in new }
        env[ChildProcessDiagnostics.environmentKey] = ChildProcessDiagnostics.directory?.path
        if ChildProcessDiagnostics.directory != nil { env["TMPDIR"] = FileManager.default.temporaryDirectory.path }
        proc.environment = CodexRuntime.environment(env, binary: binary)
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        // STOP or a failed launch can close stdin while a large image prompt is still writing.
        // Treat that as a failed write on this owned pipe, never SIGPIPE in the app process.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Drain both output pipes on their own queues for the process's whole lifetime. stderr drains
        // whole; stdout LINE-streams to `onStdoutLine` (when present) so callers see codex's --json
        // play-by-play live, while still accumulating the full buffer for parseEnvelope.
        let outDrain = PipeDrain(), errDrain = PipeDrain()
        let interactionViolated = OSAllocatedUnfairLock(initialState: false)
        let observeInteraction: @Sendable (String) -> Void = { line in
            do { try interaction?.observeToolEvent(line) }
            catch {
                interactionViolated.withLock { $0 = true }
                procHolder?.terminate()
            }
        }
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            errDrain.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = outPipe.fileHandleForReading
            guard onStdoutLine != nil || retainStdoutLine != nil || interaction != nil else {
                outDrain.set(handle.readDataToEndOfFile())     // no streaming → drain whole
                drained.leave(); return
            }
            var buf = Data(), all = Data()                     // byte-level split (multibyte-safe)
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buf.append(chunk)
                if retainStdoutLine == nil { all.append(chunk) }
                while let nl = buf.firstIndex(of: 0x0A) {
                    let line = String(decoding: buf[..<nl], as: UTF8.self)
                    observeInteraction(line)
                    onStdoutLine?(line)
                    if retainStdoutLine?(line) == true { all.append(Data((line + "\n").utf8)) }
                    buf = Data(buf[buf.index(after: nl)...])
                }
            }
            if !buf.isEmpty {
                let line = String(decoding: buf, as: UTF8.self)
                observeInteraction(line)
                onStdoutLine?(line)
                if retainStdoutLine?(line) == true { all.append(buf) }
            }
            outDrain.set(all)
            drained.leave()
        }

        do { try proc.run() } catch {
            try? inPipe.fileHandleForWriting.close()
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            throw CLIError.launchFailed("\(error)")
        }
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
        let watchdog = RunWatchdog(timeout: timeout, interaction: interaction) { [weak proc] in
            timedOut.withLock { $0 = true }
            if let procHolder { procHolder.terminate() } else { proc?.terminate() }
        }

        proc.waitUntilExit()
        procHolder?.clear()
        watchdog.cancel()
        drained.wait()

        if interactionViolated.withLock({ $0 }) { throw SidekickInteraction.Failure.toolWhileWaiting }
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
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        private let terminationGrace: TimeInterval
        init(terminationGrace: TimeInterval = 1) { self.terminationGrace = terminationGrace }
        func set(_ p: Process) {
            lock.lock(); proc = p; let shouldStop = cancelled; lock.unlock()
            if shouldStop { terminate() }
        }
        func clear() { lock.lock(); proc = nil; lock.unlock() }
        func terminate() {
            lock.lock(); cancelled = true; let p = proc; lock.unlock()
            guard let p, p.isRunning else { return }
            p.terminate()
            // A provider or MCP client must not hold STOP indefinitely by ignoring SIGTERM.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGrace) { [weak p] in
                if let p, p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Streaming sibling of `execute`: same env / PATH / watchdog, but it pumps each output LINE
    /// (stdout and stderr) to `onLine` as it arrives — so the console AND the command bar show
    /// codex's play-by-play live — while accumulating the full text. No stdin (the prompt rides in
    /// argv). Byte-level line splitting so multibyte UTF-8 across a read boundary never garbles.
    /// Honors Task cancellation: cancelling the awaiting Task terminates codex (the STOP button).
    /// A throwing line consumer also terminates the child and preserves its typed failure.
    /// Internal (not private): ClaudeCLI's agent runs ride the same streaming plumbing.
    static func executeStreaming(binary: String, args: [String], timeout: TimeInterval,
                                 extraEnv: [String: String] = [:],
                                 onLine: @escaping @Sendable (String) throws -> Void) async throws -> ExecResult {
        let holder = ProcHolder()
        let interaction = SidekickInteraction.current
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ExecResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let lease: CodexRuntime.FileLock?
                do {
                    lease = try CodexRuntime.executionLease(for: binary, cancelled: { holder.isCancelled })
                    if binary == CodexRuntime.executable.path { try CodexRuntime.verifyCLIForLaunch() }
                    if holder.isCancelled { throw CancellationError() }
                } catch { cont.resume(throwing: error); return }
                defer { lease?.unlock() }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binary)
                proc.arguments = CodexRuntime.arguments(args, binary: binary)
                // Full inherited env + rich PATH (see richEnvironment): computer use needs the real
                // $TMPDIR + GUI session vars (the cua daemon's socket lives under the per-user temp
                // dir), and so does `codex login`'s browser launch — the bare env won't do.
                var env = richEnvironment(binDir: (binary as NSString).deletingLastPathComponent)
                env.merge(extraEnv) { _, new in new }
                proc.environment = CodexRuntime.environment(env, binary: binary)

                let outPipe = Pipe(), errPipe = Pipe()
                proc.standardInput = FileHandle.nullDevice
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                let outSink = LineSink(), errSink = LineSink()
                let streamFailure = OSAllocatedUnfairLock<Error?>(initialState: nil)
                // Codex can warn when it cannot sweep an old arg0 helper directory, then
                // continue normally. Keep stderr for diagnostics, but do not show this one
                // startup cleanup warning in live computer-use progress.
                let showLine: @Sendable (String) -> Void = { line in
                    guard !line.hasPrefix("stderr: WARNING: failed to clean up stale arg0 temp dirs:") else { return }
                    // One callback at a time, including stderr. Once an event interrupts the
                    // run, suppress later progress and terminate through the same STOP path.
                    let shouldStop = streamFailure.withLock { failure in
                        guard failure == nil else { return false }
                        do { try onLine(line); return false }
                        catch { failure = error; return true }
                    }
                    if shouldStop { holder.terminate() }
                }
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
                                showLine(prefix + line)
                            }
                        }
                        if !buf.isEmpty {                          // trailing partial line (no newline)
                            let line = String(decoding: buf, as: UTF8.self)
                            sink.append(line)
                            showLine(prefix + line)
                        }
                        group.leave()
                    }
                }

                do { try proc.run() } catch {
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    cont.resume(throwing: CLIError.launchFailed("\(error)")); return
                }
                holder.set(proc)        // expose to the cancellation handler (STOP)

                let timedOut = OSAllocatedUnfairLock(initialState: false)
                let watchdog = RunWatchdog(timeout: timeout, interaction: interaction) {
                    timedOut.withLock { $0 = true }; holder.terminate()
                }

                proc.waitUntilExit()
                holder.clear()
                watchdog.cancel()
                group.wait()

                if let failure = streamFailure.withLock({ $0 }) { cont.resume(throwing: failure); return }
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
