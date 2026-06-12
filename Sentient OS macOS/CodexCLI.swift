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

    /// Every job runs GPT-5.5 (1M context; 400k input through codex). Tiers differ only in
    /// reasoning effort: `.high` for the initial vault build, `.medium` for everything daily.
    enum Effort: String, Sendable {
        case high
        case medium
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
        var effort: Effort = .medium
        var sandbox: Sandbox = .readOnly
        var cwd: String? = nil                 // the agent's working root (vault/staging dir)
        var addDirs: [String] = []             // extra writable roots beyond cwd
        var webSearch = false                  // native web_search tool
        var outputSchema: String? = nil        // JSON Schema for the final message (the judge)
        var resumeSessionID: String? = nil     // continue a prior session (usage-limit recovery)
        var timeout: TimeInterval = 3_600      // agentic vault runs are long; default generous

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
        let known = [
            "\(home)/.local/bin/codex",        // the standalone installer's symlink
            "/opt/homebrew/bin/codex",         // brew / npm -g (Apple Silicon)
            "/usr/local/bin/codex",
        ]
        let found = known.first(where: { fm.isExecutableFile(atPath: $0) }) ?? whichViaLoginShell()
        if let found { UserDefaults.standard.set(found, forKey: pathCacheKey) }
        return found
    }

    private static func whichViaLoginShell() -> String? {
        guard let out = try? execute(binary: "/bin/zsh", args: ["-lc", "which codex"],
                                     stdinText: nil, cwd: nil, timeout: 5),
              out.status == 0 else { return nil }
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
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
                                              timeout: invocation.timeout)
        return try Self.parseEnvelope(out, durationMS: Int(Date().timeIntervalSince(started) * 1000))
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
                 "--ignore-user-config",       // hermetic: personal config/plugins stay out of our jobs
                 "-m", "gpt-5.5",
                 "-c", "model_reasoning_effort=\"\(inv.effort.rawValue)\""]
        if inv.resumeSessionID == nil {
            args += ["-s", inv.sandbox.rawValue]
            if let cwd = inv.cwd { args += ["--cd", cwd] }
            for dir in inv.addDirs { args += ["--add-dir", dir] }
        } else {
            args += ["-c", "sandbox_mode=\"\(inv.sandbox.rawValue)\""]
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
                                     cwd: String?, timeout: TimeInterval) async throws -> ExecResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try execute(binary: binary, args: args, stdinText: stdinText,
                                                        cwd: cwd, timeout: timeout)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Blocking runner (call off-main). GUI-spawned `Process` works with a SANITIZED env —
    /// just HOME/USER + the system PATH and the absolute binary path; codex's auth lives in
    /// ~/.codex (resolved via HOME), no TTY needed (Arch §5, measured).
    private static func execute(binary: String, args: [String], stdinText: String?,
                                cwd: String?, timeout: TimeInterval) throws -> ExecResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let current = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER"] where current[key] != nil { env[key] = current[key] }
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
}
