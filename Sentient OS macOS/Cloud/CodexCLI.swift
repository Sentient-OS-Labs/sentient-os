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
//   - CodexCLI.locateBinary()  → binary discovery (managed install first, then cache/known paths/which)
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

    /// The model id passed to `codex exec -m`. The gpt-5.6 lineup (sol = flagship · terra = mid ·
    /// luna = light) rides ChatGPT-account auth like 5.5/5.4-mini did.
    /// (Old lesson still applies: some SKUs are API-key-only — verify a model answers through
    /// `codex exec` on a ChatGPT plan before adopting it [gpt-5.4-spark et al., MEASURED June 15].)
    enum Model: String, Sendable {
        case gpt56sol = "gpt-5.6-sol"    // knowledge-base work + everything else (paid plans)
        case gpt56terra = "gpt-5.6-terra" // the free/go stand-in for sol (see planTuned)
        case gpt56luna = "gpt-5.6-luna"  // Gmail connect-check + processing
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
    ///    read, any sol call downshifts to gpt-5.6-terra at `.medium`. Unknown plans keep sol
    ///    (CodexAuth's fail-open policy), and the luna tier is untouched.
    /// Living here at the spine means every caller — and any future one — is covered without
    /// per-call-site checks.
    private static func backendTuned(model: Model, effort: Effort) -> (modelID: String, effortArg: String) {
        if ModelBackend.current == .custom {
            return (CustomProvider.current.modelName, CustomProvider.reasoning)
        }
        guard model == .gpt56sol, CodexAuth.isLimited() else { return (model.rawValue, effort.rawValue) }
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
        let policy: CodexDataAccessPolicy
        var model: Model = .gpt56sol              // gpt-5.6-sol for everything except the Gmail tier
        var effort: Effort = .high             // gpt-5.6-sol default (nothing overrides upward); Gmail tier → .medium
        var sandbox: Sandbox = .readOnly
        var cwd: String? = nil                 // the agent's working root (vault/staging dir)
        var addDirs: [String] = []             // extra writable roots beyond cwd
        var outputSchema: String? = nil        // JSON Schema for the final message (the judge)
        var resumeSessionID: String? = nil     // continue a prior session (usage-limit recovery)
        var timeout: TimeInterval = 3_600      // agentic vault runs are long; default generous
        var diag: [String: String] = [:]       // caller-supplied structured diagnostics merged into a
                                               // codex.failure's extra (e.g. the vault's corpus_chars /
                                               // slices / slice_index). Ints and enums rendered as
                                               // strings ONLY — never paths, UUIDs, or free text (the
                                               // Sentry scrubber [Filtered]s those into uselessness).

        init(prompt: String, policy: CodexDataAccessPolicy) {
            self.prompt = prompt
            self.policy = policy
        }
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
        let accessObservations: [CodexAccessObservation]

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
        case unsupportedVersion(found: String, minimum: String)
        case invalidPolicy(String)
        case policyViolation(CodexAccessObservation)
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
            case .unsupportedVersion(let found, let minimum):
                return "Codex \(minimum) or newer is required (found \(found)). Update Codex and try again."
            case .invalidPolicy(let reason):      return "Codex data-access policy rejected: \(reason)"
            case .policyViolation:                return "Codex attempted data access outside this run's declared policy."
            case .usageLimit(let m, _):           return "Codex usage limit: \(m.prefix(200))"
            case .inputTooLarge(let c):           return "Prompt too large for codex: \(c) chars (server cap 1,048,576)"
            }
        }
    }

    /// Internal transport that preserves content-free observations when JSONL parsing fails. The
    /// public error is unwrapped again in `run`, so existing typed caller behavior is unchanged.
    private struct ObservedRunFailure: Error {
        let error: CLIError
        let observations: [CodexAccessObservation]
    }

    // MARK: Discovery

    private static let pathCacheKey = "codexcli.binaryPath"
    static let minimumVersion = "0.146.0"

    /// Version-gate the strict policy surface (`--strict-config`, ephemeral sessions and exact
    /// app/tool controls) before any prompt is sent. Unknown versions fail closed.
    private static func versionError(binary: String) -> CLIError? {
        guard let out = try? execute(binary: binary, args: ["--version"], stdinText: nil,
                                     cwd: nil, timeout: 10), out.status == 0 else {
            return .unsupportedVersion(found: "unknown", minimum: minimumVersion)
        }
        let found = (out.stdout + " " + out.stderr)
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
            .first(where: { $0.first?.isNumber == true && $0.contains(".") }) ?? "unknown"
        guard version(found, isAtLeast: minimumVersion) else {
            return .unsupportedVersion(found: found, minimum: minimumVersion)
        }
        return nil
    }

    private static func version(_ found: String, isAtLeast required: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").prefix(3).map { component in
                Int(component.prefix(while: \.isNumber)) ?? 0
            }
        }
        let lhs = parts(found), rhs = parts(required)
        guard lhs.count == 3, rhs.count == 3 else { return false }
        return lhs.lexicographicallyPrecedes(rhs) == false
    }

    /// The managed install first (unconditionally), then known locations, then a login-shell
    /// `which` (GUI apps don't inherit the user's PATH). Discovery results are cached in
    /// UserDefaults and re-verified on every read.
    static func locateBinary() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        // The standalone installer's symlink — the ONE copy our installer keeps current — wins
        // over everything, INCLUDING the cache: on a Mac that also has a brew/npm codex, a cached
        // brew path would otherwise field every run with a stale binary while the fresh install
        // sat unused. `isExecutableFile` resolves the symlink, so a dangling link (e.g. a wiped
        // `~/.codex/packages`) falls through to the fallbacks instead of being returned.
        let managed = "\(home)/.local/bin/codex"
        if fm.isExecutableFile(atPath: managed) { return managed }
        if let cached = UserDefaults.standard.string(forKey: pathCacheKey),
           fm.isExecutableFile(atPath: cached) {
            return cached
        }
        var known = [
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
        // Survive a slow connection, fail fast on a dead one. The outer curl (the tiny install.sh)
        // caps at 60s; the sed injects matching resilience into the script's OWN curl calls (the
        // real binary download): abort only if throughput stays under ~8 KB/s for 30s, so a
        // stalled transfer dies in seconds instead of burning the whole budget while a slow-but-
        // moving download keeps going. The outer timeout is generous (15 min) so a genuinely slow
        // link can finish — the old 300s ceiling was SIGTERM-ing in-progress downloads on slow
        // connections [MEASURED from install traces, 2026-07-24].
        let pipeline = #"curl -fsSL --connect-timeout 30 --max-time 60 https://chatgpt.com/codex/install.sh | sed 's|curl -fsSL|curl -fsSL -H "Accept: application/json" --connect-timeout 30 --speed-limit 8192 --speed-time 30|g' | CODEX_NON_INTERACTIVE=1 sh"#
        let out = try await executeStreaming(binary: "/bin/sh", args: ["-c", pipeline],
                                             timeout: 900, onLine: onLine)
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
    private var cachedAvailabilityFingerprint: String?

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
        let result = await Self.ping()
        if case .available = result {
            cachedAvailability = result
            cachedAvailabilityFingerprint = fingerprint
        } else {
            cachedAvailability = nil
        }
        return result
    }

    private static func backendFingerprint() -> String {
        guard ModelBackend.current == .custom else { return "chatgpt" }
        let p = CustomProvider.current
        return "custom|\(p.baseURL)|\(p.modelName)"
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

    private static func ping(forceCustom: Bool = false) async -> Availability {
        let policy = CodexDataAccessPolicy.validation
        let receiptTime = Date()
        func finish(_ value: Availability,
                    observations: [CodexAccessObservation] = [],
                    forcedOutcome: CodexAccessReceipt.Outcome? = nil) async -> Availability {
            let outcome: CodexAccessReceipt.Outcome
            if let forcedOutcome { outcome = forcedOutcome }
            else if case .available = value { outcome = .succeeded }
            else { outcome = .failed }
            await CodexAccessLedger.shared.record(policy: policy, observations: observations,
                                                   outcome: outcome, at: receiptTime)
            return value
        }
        guard let bin = locateBinary() else { return await finish(.notInstalled) }
        if let error = versionError(binary: bin) {
            return await finish(.notWorking(error.description))
        }
        let custom = forceCustom || ModelBackend.current == .custom
        var args = ["exec", "--json", "--ephemeral", "--strict-config", "--ignore-user-config",
                    "--ignore-rules", "-s", Sandbox.readOnly.rawValue]
        for override in policy.configurationOverrides() { args += ["-c", override] }
        var timeout: TimeInterval = 30
        var prompt = "Reply with exactly: PIGGYBACK_OK"
        var probeImage: (url: URL, code: String)?
        defer { if let probeImage { try? FileManager.default.removeItem(at: probeImage.url) } }

        if custom {
            let provider = CustomProvider.current
            guard provider.isConfigured else {
                return await finish(.notWorking("Custom model not configured — set a base URL and model name."))
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
            let observations = accessObservations(in: out.stdout)
            let envelope: Envelope
            do {
                envelope = try parseEnvelope(out, durationMS: 0, policy: policy)
            } catch {
                let outcome: CodexAccessReceipt.Outcome
                if case CLIError.policyViolation = error { outcome = .policyViolation }
                else { outcome = .failed }
                return await finish(.notWorking("\(error)"), observations: observations,
                                    forcedOutcome: outcome)
            }
            if let probeImage {
                // The model must have READ the code — proof it sees screenshots, not just that
                // the endpoint tolerated an image part.
                guard envelope.result.contains(probeImage.code) else {
                    return await finish(.notWorking("blind: the model answered but could not read the test image"),
                                        observations: observations)
                }
                return await finish(.available(path: bin), observations: observations)
            }
            if envelope.result.contains("PIGGYBACK_OK") {
                return await finish(.available(path: bin), observations: observations)
            }
            return await finish(.notWorking("The validation model returned an unexpected response."),
                                observations: observations)
        } catch {
            return await finish(.notWorking("\(error)"))
        }
    }

    // MARK: Run

    /// Execute one headless call and return the parsed envelope. Throws typed errors —
    /// notably `.usageLimit` (carrying the session id) so callers can reschedule/resume.
    func run(_ invocation: Invocation,
             onLine: (@Sendable (String) -> Void)? = nil) async throws -> Envelope {
        var invocation = invocation
        let receiptTime = Date()
        let (modelID, effortArg) = Self.backendTuned(model: invocation.model,
                                                     effort: invocation.effort)
        if ModelBackend.current == .custom {
            // Hosted apps and OpenAI web search are account services, not capabilities a custom
            // endpoint can safely inherit. Fail closed if a caller routes such a policy here.
            guard invocation.policy.hostedApps.isEmpty, invocation.policy.web == .denied else {
                let error = CLIError.invalidPolicy("hosted apps and web research require the ChatGPT backend")
                await CodexAccessLedger.shared.record(policy: invocation.policy, observations: [],
                                                       outcome: .failed, at: receiptTime)
                throw error
            }
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
            let envelope = try await runInner(invocation, modelID: modelID, effortArg: effortArg,
                                              onLine: onLine)
            await CodexAccessLedger.shared.record(policy: invocation.policy,
                                                   observations: envelope.accessObservations,
                                                   outcome: .succeeded, at: receiptTime)
            return envelope
        } catch {
            let reportedError: Error
            let observations: [CodexAccessObservation]
            if let observedFailure = error as? ObservedRunFailure {
                reportedError = observedFailure.error
                observations = observedFailure.observations
            } else {
                reportedError = error
                observations = []
            }
            let outcome: CodexAccessReceipt.Outcome
            if case CLIError.policyViolation = reportedError {
                outcome = .policyViolation
            } else if case CLIError.invalidPolicy = reportedError {
                outcome = .policyViolation
            } else if Task.isCancelled {
                outcome = .cancelled
            } else {
                outcome = .failed
            }
            await CodexAccessLedger.shared.record(policy: invocation.policy, observations: observations,
                                                   outcome: outcome, at: receiptTime)
            // A cancelled Task is the user's STOP: the SIGTERM'd process exits non-zero, which
            // masqueraded as a real exitFailure in Sentry (field-found 2026-07-12). Not a defect.
            if !Task.isCancelled {
                Self.emitCodexFailure(event: "codex.failure", reportedError,
                                      feature: invocation.policy.purpose.rawValue,
                                      modelID: modelID, effort: effortArg,
                                      resumed: invocation.resumeSessionID != nil,
                                      durationMS: Int(Date().timeIntervalSince(t0) * 1000),
                                      diag: invocation.diag)
            }
            throw reportedError
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
        guard invocation.policy.version == CodexDataAccessPolicy.currentVersion else {
            throw CLIError.invalidPolicy("unsupported policy version")
        }
        guard !invocation.policy.userInitiatedComputerUse else {
            throw CLIError.invalidPolicy("computer use must use the dedicated agent-command spine")
        }
        if invocation.resumeSessionID != nil, invocation.policy.session != .resumable {
            throw CLIError.invalidPolicy("an ephemeral policy cannot resume a session")
        }
        if invocation.prompt.utf8.count > Self.promptByteCap {
            throw CLIError.inputTooLarge(chars: invocation.prompt.utf8.count)
        }
        guard let located = Self.locateBinary() else {
            throw CLIError.notAvailable(.notInstalled)
        }
        if let error = Self.versionError(binary: located) { throw error }
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
                                              args: Self.arguments(for: invocation, modelID: modelID,
                                                                   effortArg: effortArg,
                                                                   schemaFile: schemaFile),
                                              stdinText: invocation.prompt,
                                              cwd: invocation.cwd,
                                              timeout: invocation.timeout,
                                              onStdoutLine: stdoutLine)
        do {
            return try Self.parseEnvelope(out,
                                          durationMS: Int(Date().timeIntervalSince(started) * 1000),
                                          policy: invocation.policy)
        } catch let error as CLIError {
            throw ObservedRunFailure(error: error, observations: Self.accessObservations(in: out.stdout))
        }
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
    /// (`~/.local/bin/codex` first). User config, rules, memories, account apps, MCP servers, and
    /// plugins remain blocked except for the exact bundled computer-use plugin. Returns the full output.
    ///
    /// `imagePaths` (optional): screenshots of the user's displays (main first), attached with
    /// `codex exec -i <file>...` so the agent SEES what they're looking at (the notch/command-bar
    /// path passes one per display; the proactive executor passes none). They're placed right before
    /// `--skip-git-repo-check` so the flag terminates `-i`'s variadic `<FILE>...` and the prompt is
    /// never mistaken for another image.
    func runAgentCommand(_ prompt: String, policy: CodexDataAccessPolicy,
                         imagePaths: [String] = [], timeout: TimeInterval = 1_800,
                         onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        let t0 = Date()
        let receiptTime = Date()
        // The user's speed-vs-intelligence slider (Settings → Proactive & Sidekick) — read fresh
        // per run, so a change applies to the very next fire with no restart. backendTuned: on the
        // custom backend the user's endpoint model + its ONE reasoning level drive computer use
        // (verified end-to-end via OpenRouter 2026-07-24); on ChatGPT, computer use is Plus-gated
        // but dev tools can still reach this on a free account — same downshift.
        let (modelID, effortArg) = Self.backendTuned(model: .gpt56sol,
                                                     effort: ComputerUseSpeed.current.effort)
        do {
            guard policy == .computerUse, policy.userInitiatedComputerUse else {
                throw CLIError.invalidPolicy("agent commands require the explicit user-initiated computer-use policy")
            }
            // Same pre-spawn guard as `run` — this spine passes the prompt as ARGV, where an
            // oversized prompt dies even earlier (ARG_MAX) with an unhelpful spawn error.
            if prompt.utf8.count > Self.promptByteCap {
                throw CLIError.inputTooLarge(chars: prompt.utf8.count)
            }
            guard let bin = Self.locateBinary() else { throw CLIError.notAvailable(.notInstalled) }
            if let error = Self.versionError(binary: bin) { throw error }
            // Self-heal the relaxed confirmation policy: a plugin update (desktop app or a
            // re-bootstrap) lays a fresh STOCK SKILL.md, whose policy stalls headless runs on
            // "shall I proceed?" questions nothing can answer. Cheap file check, idempotent.
            ComputerUseSkillPatch.ensureApplied()
            var args = ["exec", "--ephemeral", "--strict-config", "--ignore-user-config",
                        "--ignore-rules", "--dangerously-bypass-approvals-and-sandbox",
                        "-m", modelID,
                        "-c", "model_reasoning_effort=\"\(effortArg)\""]
            for override in policy.configurationOverrides() { args += ["-c", override] }
            if ModelBackend.current == .custom {
                for override in CustomProvider.current.providerOverrides() { args += ["-c", override] }
            }
            if !imagePaths.isEmpty { args += ["-i"] + imagePaths }   // followed by a flag → the variadic stops here
            args += ["--skip-git-repo-check", prompt]
            let out = try await Self.executeStreaming(binary: bin, args: args, timeout: timeout, onLine: onLine)
            guard out.status == 0 else {
                let detail = out.stderr.isEmpty ? out.stdout : out.stderr
                throw CLIError.exitFailure(code: out.status, message: String(detail.prefix(600)))
            }
            await CodexAccessLedger.shared.record(policy: policy,
                                                   observations: [.computerUseUnavailable],
                                                   outcome: .succeeded, at: receiptTime)
            return out.stdout.isEmpty ? out.stderr : out.stdout
        } catch {
            let outcome: CodexAccessReceipt.Outcome
            if case CLIError.invalidPolicy = error { outcome = .policyViolation }
            else { outcome = Task.isCancelled ? .cancelled : .failed }
            await CodexAccessLedger.shared.record(policy: policy,
                                                   observations: policy.userInitiatedComputerUse
                                                       ? [.computerUseUnavailable] : [],
                                                   outcome: outcome,
                                                   at: receiptTime)
            // §7.9: computer-use is the full-capability path (bypass-sandbox, user-fired), so a
            // genuine failure is worth a structured event. Case name only — and never on a cancelled
            // Task (the user's STOP kills codex → non-zero exit, which is not a failure; field-found
            // polluting Sentry 2026-07-12).
            if !Task.isCancelled {
                Self.emitCodexFailure(event: "codex.agent_command", error, feature: "computer",
                                      modelID: modelID, effort: effortArg, resumed: false,
                                      durationMS: Int(Date().timeIntervalSince(t0) * 1000))
            }
            throw error
        }
    }

    /// Emit a structured codex failure — the CLIError CASE NAME only (never `.message`/stderr/prompt,
    /// which embed user content). One seam for the whole cloud spine; `feature` makes it attributable;
    /// `diag` is the caller's structured extras (Invocation.diag — ints/enums only, pre-vetted).
    /// On the custom backend the model tag reports the literal "custom" — a user's model slug (or a
    /// private deployment name) is free text and never leaves the Mac.
    private static func emitCodexFailure(event: String, _ error: Error, feature: String,
                                         modelID: String, effort: String, resumed: Bool, durationMS: Int,
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
        case CLIError.unsupportedVersion: (caseName, level) = ("unsupportedVersion", .warning)
        case CLIError.invalidPolicy: (caseName, level) = ("invalidPolicy", .error)
        case CLIError.policyViolation: (caseName, level) = ("policyViolation", .error)
        case CLIError.inputTooLarge(let chars):
            // The canary: every prompt path is byte-budgeted, so this should stay at zero.
            (caseName, level) = ("inputTooLarge", .error)
            extra["prompt_chars"] = String(chars)
        default:                    (caseName, level) = (String(describing: type(of: error)), .error)
        }
        extra["effort"] = effort
        extra["resumed"] = String(resumed)
        extra["duration_ms"] = String(durationMS)
        let modelTag = ModelBackend.current == .custom ? "custom" : modelID
        CrashReporting.captureEvent(event, level: level,
            tags: ["feature": feature, "error": caseName, "model": modelTag],
            extra: extra,
            fingerprint: ["codex", feature, caseName])
    }

    /// `exec resume` accepts only a subset of `exec`'s flags — no `-s`/`--cd`/`--add-dir`.
    /// [MEASURED] A resumed session's workspace root is the PROCESS cwd (not the remembered
    /// one), so `execute`'s cwd is load-bearing there, and the sandbox rides the
    /// `sandbox_mode` config key instead of `-s`.
    static func arguments(for inv: Invocation, modelID: String, effortArg: String,
                          schemaFile: String?) -> [String] {
        var args = ["exec"]
        if let sid = inv.resumeSessionID { args += ["resume", sid] }
        args += ["--json", "--strict-config", "--ignore-user-config", "--ignore-rules",
                 "--skip-git-repo-check",      // staging dirs and the vault aren't git repos
                 "-m", modelID,
                 "-c", "model_reasoning_effort=\"\(effortArg)\""]
        if inv.policy.session == .ephemeral {
            args += ["--ephemeral"]
        }
        for override in inv.policy.configurationOverrides() { args += ["-c", override] }
        if ModelBackend.current == .custom {
            for override in CustomProvider.current.providerOverrides() { args += ["-c", override] }
        }

        // Agent commands own the only bypass path. JSON invocations always keep Seatbelt enabled.
        if inv.resumeSessionID == nil {
            args += ["-s", inv.sandbox.rawValue]
            if let cwd = inv.cwd { args += ["--cd", cwd] }
            for dir in inv.addDirs { args += ["--add-dir", dir] }
        } else {
            args += ["-c", "sandbox_mode=\"\(inv.sandbox.rawValue)\""]
        }
        if let schemaFile { args += ["--output-schema", schemaFile] }
        args.append("-")                       // the prompt arrives on stdin
        return args
    }

    // MARK: JSONL parsing

    private static let usageLimitMarkers = ["usage limit", "rate limit", "limit reached",
                                            "limit resets", "quota", "too many requests",
                                            "out of extra usage", "plan limit"]

    static func parseEnvelope(_ out: ExecResult, durationMS: Int,
                              policy: CodexDataAccessPolicy) throws -> Envelope {
        var sessionID: String?
        var lastMessage: String?
        var completedItems = 0
        var usage: [String: Any]?
        var errors: [String] = []
        let observations = accessObservations(in: out.stdout)

        for line in out.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "thread.started":
                sessionID = obj["thread_id"] as? String
            case "item.started", "item.completed":
                if type == "item.completed" { completedItems += 1 }
                if let item = obj["item"] as? [String: Any] {
                    if type == "item.completed",
                       item["type"] as? String == "agent_message",
                       let text = item["text"] as? String {
                        lastMessage = text
                    }
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

        // Authorization is checked before exit/message handling. Even a run that later failed must
        // never have an undeclared tool result returned to a caller.
        if let unauthorized = observations.first(where: { !policy.allows($0) }) {
            throw CLIError.policyViolation(unauthorized)
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
            accessObservations: observations
        )
    }

    /// One content-free scan shared by success, failure, and validation paths. Keeping this
    /// independent of result parsing ensures failed tool lifecycles still reach the receipt.
    private static func accessObservations(in jsonl: String) -> [CodexAccessObservation] {
        jsonl.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let eventType = obj["type"] as? String,
                  eventType == "item.started" || eventType == "item.completed",
                  let item = obj["item"] as? [String: Any] else { return nil }
            return CodexAccessObservation.canonical(item: item, eventType: eventType)
        }
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
        // Same unconditional endpoint-key injection as the sanitized env (see execute()).
        env[CustomProvider.apiKeyEnvName] = CustomProvider.apiKeyEnvValue
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
        // The custom endpoint's key rides the env var the provider table's `env_key` names —
        // injected UNCONDITIONALLY: codex ignores it unless a run's provider references it, and
        // the pane's pre-activation Test Connection probes the custom path while ChatGPT is
        // still the active backend. (codex hard-errors on an unset/empty env_key var; a value
        // here also blocks the ChatGPT-token fallthrough on keyless local servers.)
        env[CustomProvider.apiKeyEnvName] = CustomProvider.apiKeyEnvValue
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
