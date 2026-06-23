//
//  CodexCLI.swift
//  Sentient OS macOS
//
//  The `codex exec` wrapper service (Arch §5) — the compute spine for ALL cloud-model work:
//  vault generation, daily updates, proactive intelligence. Discovers the user's Codex CLI
//  binary, validates it with a quick ping, and runs headless prompts via `Process`:
//  prompt over STDIN (never argv — macOS ARG_MAX is 1 MB), `--json` JSONL events back,
//  sandbox/effort/cwd scoping, and typed usage-limit errors that carry the session (thread)
//  id so callers can reschedule and resume. All mechanics receipt-verified live (Arch §5).
//
//  Key methods:
//   - CodexCLI.locateBinary()  → cached absolute-path discovery (known paths + zsh -lc which)
//   - validate(force:)         → Availability via ping (cached per launch)
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
    /// (and everything else) = `.high`; the initial vault build overrides to `.xhigh`.
    enum Effort: String, Sendable {
        case low
        case medium
        case high
        case xhigh
    }

    /// The model id passed to `codex exec -m`. NOTE: on a ChatGPT-account (subscription) auth only
    /// gpt-5.5 and the gpt-5.4 family are available — gpt-5.4-spark / -codex / -mini-of-other-gens
    /// are API-key-only [MEASURED June 15]. `gpt54mini` is the light model for the Gmail tier.
    enum Model: String, Sendable {
        case gpt55 = "gpt-5.5"           // knowledge-base work + everything else
        case gpt54mini = "gpt-5.4-mini"  // Gmail connect-check + processing
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
        var model: Model = .gpt55              // gpt-5.5 for everything except the Gmail tier
        var effort: Effort = .high             // gpt-5.5 default; initial vault build → .xhigh; Gmail tier → .medium
        var sandbox: Sandbox = .readOnly
        var cwd: String? = nil                 // the agent's working root (vault/staging dir)
        var addDirs: [String] = []             // extra writable roots beyond cwd
        var webSearch = true                   // native web_search tool — available to EVERY call
        var includeUserConfig = true           // load the user's ~/.codex config + MCP servers (e.g.
                                               // their Gmail MCP) for EVERY call. Set false for a
                                               // hermetic run (then we pass --ignore-user-config).
        var bypassApprovals = false            // --dangerously-bypass-approvals-and-sandbox: NO
                                               // approval prompts AND NO sandbox. Needed for hosted
                                               // connector WRITE tools (Gmail `send_email`), which
                                               // are approval-gated and return "user cancelled MCP
                                               // tool call" headless even under approval_policy=never.
                                               // TRUSTED, app-authored prompts ONLY (no sandbox!).
        var outputSchema: String? = nil        // JSON Schema for the final message (the judge)
        var resumeSessionID: String? = nil     // continue a prior session (usage-limit recovery)
        var timeout: TimeInterval = 3_600      // agentic vault runs are long; default generous
        var customEnv: [String: String] = [:]  // extra env vars merged into the sanitized child env
                                               // (e.g. PLAYWRIGHT_MCP_STORAGE_STATE for the browser
                                               // executor). PATH is reserved — use extraPathDirs.
        var extraPathDirs: [String] = []       // dirs PREPENDED to the child PATH (e.g. the
                                               // playwright-cli / node bin dir) so codex's shell can
                                               // find tools it shells out to.

        init(prompt: String) { self.prompt = prompt }
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

        var description: String {
            switch self {
            case .notAvailable(let a):            return "Codex unavailable: \(a)"
            case .launchFailed(let m):            return "Failed to launch codex: \(m)"
            case .timedOut(let t):                return "codex exec timed out after \(Int(t))s"
            case .exitFailure(let code, let m):   return "codex exited \(code): \(m.prefix(300))"
            case .badEnvelope(let m):             return "Unparseable codex output: \(m.prefix(300))"
            case .usageLimit(let m, _):           return "Codex usage limit: \(m.prefix(200))"
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

    // MARK: Validation

    private var cachedAvailability: Availability?

    /// Is `codex exec` actually usable (installed AND logged in)? Cached per app launch —
    /// pass `force: true` to re-probe (e.g. right after the installer flow).
    func validate(force: Bool = false) async -> Availability {
        if !force, let cachedAvailability { return cachedAvailability }
        let result = await Self.ping()
        cachedAvailability = result
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
    func run(_ invocation: Invocation) async throws -> Envelope {
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
        let out = try await Self.executeAsync(binary: bin,
                                              args: Self.arguments(for: invocation, schemaFile: schemaFile),
                                              stdinText: invocation.prompt,
                                              cwd: invocation.cwd,
                                              timeout: invocation.timeout,
                                              customEnv: invocation.customEnv,
                                              extraPathDirs: invocation.extraPathDirs)
        return try Self.parseEnvelope(out, durationMS: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// The command bar's "Let me DO stuff for you" spine — computer use AND browser use (the mode
    /// is just a word in the prompt the caller builds, NOT a flag here). Runs a raw `codex exec`
    /// with the prompt passed as ARGV and the exact flag set verified to make Codex's computer/
    /// browser use work via the CLI: `--dangerously-bypass-approvals-and-sandbox -m gpt-5.5
    /// -c model_reasoning_effort="medium" --skip-git-repo-check`, NO `--json` (human-readable
    /// output, not JSONL). Each output LINE is pumped to `onLine` AS it arrives, so the Xcode
    /// console shows codex's play-by-play live. Reuses the sanitized-env / PATH / watchdog plumbing;
    /// the binary comes from the same discovery (`~/.local/bin/codex` first). The user's ~/.codex
    /// config + MCP servers load by default (no --ignore-user-config). Returns the full output.
    /// Computer use is the WIP CLI path.
    func runAgentCommand(_ prompt: String, timeout: TimeInterval = 1_800,
                         onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let bin = Self.locateBinary() else { throw CLIError.notAvailable(.notInstalled) }
        let args = ["exec", "--dangerously-bypass-approvals-and-sandbox",
                    "-m", Model.gpt55.rawValue,
                    "-c", "model_reasoning_effort=\"medium\"",
                    "--skip-git-repo-check", prompt]
        let out = try await Self.executeStreaming(binary: bin, args: args, timeout: timeout, onLine: onLine)
        guard out.status == 0 else {
            let detail = out.stderr.isEmpty ? out.stdout : out.stderr
            throw CLIError.exitFailure(code: out.status, message: String(detail.prefix(600)))
        }
        return out.stdout.isEmpty ? out.stderr : out.stdout
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
        //    real guardrail for shell/file ops.
        //  · bypassApprovals → `--dangerously-bypass-approvals-and-sandbox` (NO approvals, NO
        //    sandbox). Required for hosted-connector WRITE tools (Gmail `send_email`), which are
        //    approval-gated and return "user cancelled MCP tool call" headless even under
        //    approval_policy=never. Mutually exclusive — codex rejects `-s`/approval_policy with it.
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

    // MARK: Process plumbing

    struct ExecResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
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
                                     customEnv: [String: String] = [:],
                                     extraPathDirs: [String] = []) async throws -> ExecResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try execute(binary: binary, args: args, stdinText: stdinText,
                                                        cwd: cwd, timeout: timeout,
                                                        customEnv: customEnv, extraPathDirs: extraPathDirs)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Blocking runner (call off-main). GUI-spawned `Process` works with a SANITIZED env —
    /// just HOME/USER + the system PATH and the absolute binary path; codex's auth lives in
    /// ~/.codex (resolved via HOME), no TTY needed (Arch §5, measured).
    private static func execute(binary: String, args: [String], stdinText: String?,
                                cwd: String?, timeout: TimeInterval,
                                customEnv: [String: String] = [:],
                                extraPathDirs: [String] = []) throws -> ExecResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        // The binary's OWN directory leads the sanitized PATH: npm installs are
        // `#!/usr/bin/env node` shims, and (in the nvm layout) `node` sits right next to
        // them — without this, the shim exec-fails even when found. `extraPathDirs` go in FRONT of
        // it (e.g. so codex's shell finds a `playwright-cli` it shells out to).
        let binDir = (binary as NSString).deletingLastPathComponent
        var env: [String: String] = [:]
        let current = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER"] where current[key] != nil { env[key] = current[key] }
        for (k, v) in customEnv { env[k] = v }                 // app-supplied extras (PLAYWRIGHT_MCP_*)
        // PATH is set LAST so customEnv can't accidentally clobber it; extraPathDirs lead.
        env["PATH"] = (extraPathDirs + [binDir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        proc.environment = env
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Drain both output pipes on their own queues for the process's whole lifetime.
        let outDrain = PipeDrain(), errDrain = PipeDrain()
        let drained = DispatchGroup()
        for (pipe, drain) in [(outPipe, outDrain), (errPipe, errDrain)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                drain.set(pipe.fileHandleForReading.readDataToEndOfFile())
                drained.leave()
            }
        }

        do { try proc.run() } catch { throw CLIError.launchFailed("\(error)") }

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

    /// Streaming sibling of `execute`: same sanitized env / PATH / watchdog, but it pumps each
    /// output LINE (stdout and stderr) to `onLine` as it arrives — so the console shows codex's
    /// computer-use play-by-play live — while also accumulating the full text. No stdin (the
    /// computer-use prompt rides in argv). Byte-level line splitting so multibyte UTF-8 that
    /// straddles a read boundary never garbles.
    private static func executeStreaming(binary: String, args: [String], timeout: TimeInterval,
                                         onLine: @escaping @Sendable (String) -> Void) async throws -> ExecResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ExecResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binary)
                proc.arguments = args
                // Computer/browser use drives Codex's bundled GUI helper (SkyComputerUseService),
                // which codex reaches over an IPC socket living under the per-user $TMPDIR. The
                // bare HOME/USER env we use for headless codex elsewhere DROPS $TMPDIR (+ the GUI
                // session/bootstrap vars), so the helper connection hangs at the first call
                // (`list_apps`). So here we INHERIT the app's full environment — which carries the
                // real $TMPDIR + session vars, exactly like a Terminal launch — and only overlay a
                // rich PATH so codex finds the tools it shells out to (node, playwright-cli, the
                // Codex.app cua_node).
                let binDir = (binary as NSString).deletingLastPathComponent
                var env = ProcessInfo.processInfo.environment
                let home = env["HOME"] ?? NSHomeDirectory()
                let richPath = [binDir,
                                "\(home)/.local/bin",
                                "/opt/homebrew/bin", "/opt/homebrew/sbin",
                                "/usr/local/bin",
                                "/Applications/Codex.app/Contents/Resources/cua_node/bin",
                                "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
                env["PATH"] = env["PATH"].map { "\(richPath):\($0)" } ?? richPath
                proc.environment = env

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
    }
}
