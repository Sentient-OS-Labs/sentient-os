//
//  ClaudeCLI.swift
//  Sentient OS macOS
//
//  The `claude -p` wrapper service (Arch §5) — the compute spine for ALL cloud-model work:
//  vault generation, daily updates, proactive intelligence. Discovers the user's Claude Code
//  binary, validates it with a quick ping, and runs headless prompts via `Process`:
//  prompt over STDIN (never argv — macOS ARG_MAX is 1 MB), `--output-format json` envelope
//  back, tool/model/cwd scoping, and typed usage-limit errors that carry the session id so
//  callers can reschedule and resume. All mechanics pre-verified live (Arch §5 receipts).
//
//  Key methods:
//   - ClaudeCLI.locateBinary()  → cached absolute-path discovery (known paths + zsh -lc which)
//   - validate(force:)          → Availability via ping (cached per launch)
//   - run(_:)                   → Envelope (blocking JSON mode)
//
//  Doc: Documentation/ClaudeCLI (claude -p Compute Spine).md
//

import Foundation
import os

actor ClaudeCLI {

    /// One shared instance so the per-launch availability cache is app-wide.
    static let shared = ClaudeCLI()

    // MARK: Types

    enum Model: Sendable {
        case opus1M    // initial vault generation — 1M context window confirmed live
        case sonnet    // daily updates · proactive judge (stretches subscription windows)

        var flag: String {
            switch self {
            case .opus1M: return "claude-opus-4-8[1m]"
            case .sonnet: return "sonnet"
            }
        }
    }

    /// One headless `claude -p` call, fully specified.
    struct Invocation: Sendable {
        var prompt: String
        var model: Model = .sonnet
        var allowedTools: [String] = []        // e.g. ["Write","Edit","Read","Glob","Grep"]
        var cwd: String? = nil                 // the agent's working directory (vault/staging dir)
        var addDirs: [String] = []
        var maxTurns: Int? = nil
        var appendSystemPrompt: String? = nil
        var jsonSchema: String? = nil          // structured output (proactive's {time, text})
        var resumeSessionID: String? = nil     // continue a prior session (usage-limit recovery)
        var timeout: TimeInterval = 3_600      // agentic vault runs are long; default generous

        init(prompt: String) { self.prompt = prompt }
    }

    /// The parsed `--output-format json` envelope.
    struct Envelope: Sendable {
        let result: String
        let stopReason: String?
        let sessionID: String?
        let numTurns: Int?
        let durationMS: Int?
        let totalCostUSD: Double?
        let permissionDenialCount: Int
        let inputTokens: Int?
        let outputTokens: Int?
        let raw: String                        // full envelope JSON, for debugging
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
            case .notAvailable(let a):            return "Claude Code unavailable: \(a)"
            case .launchFailed(let m):            return "Failed to launch claude: \(m)"
            case .timedOut(let t):                return "claude -p timed out after \(Int(t))s"
            case .exitFailure(let code, let m):   return "claude exited \(code): \(m.prefix(300))"
            case .badEnvelope(let m):             return "Unparseable claude envelope: \(m.prefix(300))"
            case .usageLimit(let m, _):           return "Claude usage limit: \(m.prefix(200))"
            }
        }
    }

    // MARK: Discovery

    private static let pathCacheKey = "claudecli.binaryPath"

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
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        let found = known.first(where: { fm.isExecutableFile(atPath: $0) }) ?? whichViaLoginShell()
        if let found { UserDefaults.standard.set(found, forKey: pathCacheKey) }
        return found
    }

    private static func whichViaLoginShell() -> String? {
        guard let out = try? execute(binary: "/bin/zsh", args: ["-lc", "which claude"],
                                     stdinText: nil, cwd: nil, timeout: 5),
              out.status == 0 else { return nil }
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: Validation

    private var cachedAvailability: Availability?

    /// Is `claude -p` actually usable (installed AND authenticated)? Cached per app launch —
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
            let out = try await executeAsync(binary: bin,
                                             args: ["-p", "Reply with exactly: PIGGYBACK_OK"],
                                             stdinText: nil, cwd: nil, timeout: 15)
            if out.status == 0 && out.stdout.contains("PIGGYBACK_OK") { return .available(path: bin) }
            let detail = out.stderr.isEmpty ? out.stdout : out.stderr
            return .notWorking(String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
        } catch {
            return .notWorking("\(error)")
        }
    }

    // MARK: Run

    /// Execute one headless call and return the parsed JSON envelope. Throws typed errors —
    /// notably `.usageLimit` (carrying the session id) so callers can reschedule/resume.
    func run(_ invocation: Invocation) async throws -> Envelope {
        let availability = await validate()
        guard case .available(let bin) = availability else {
            throw CLIError.notAvailable(availability)
        }

        var args = ["-p", "--output-format", "json", "--model", invocation.model.flag]
        if !invocation.allowedTools.isEmpty {
            args += ["--allowedTools", invocation.allowedTools.joined(separator: ",")]
        }
        if let turns = invocation.maxTurns { args += ["--max-turns", String(turns)] }
        if let sys = invocation.appendSystemPrompt { args += ["--append-system-prompt", sys] }
        for dir in invocation.addDirs { args += ["--add-dir", dir] }
        if let schema = invocation.jsonSchema { args += ["--json-schema", schema] }
        if let sid = invocation.resumeSessionID { args += ["--resume", sid] }

        let out = try await Self.executeAsync(binary: bin, args: args,
                                              stdinText: invocation.prompt,
                                              cwd: invocation.cwd,
                                              timeout: invocation.timeout)
        return try Self.parseEnvelope(out)
    }

    // MARK: Envelope parsing

    private static let usageLimitMarkers = ["usage limit", "rate limit", "limit reached", "limit resets", "out of extra usage"]

    private static func parseEnvelope(_ out: ExecResult) throws -> Envelope {
        // Parse stdout JSON FIRST regardless of exit code — a usage-limit failure still emits
        // a JSON envelope (with is_error) alongside a non-zero exit.
        guard let data = out.stdout.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if out.status != 0 {
                throw CLIError.exitFailure(code: out.status,
                                           message: out.stderr.isEmpty ? out.stdout : out.stderr)
            }
            throw CLIError.badEnvelope(out.stdout)
        }

        let result = obj["result"] as? String ?? ""
        let sessionID = obj["session_id"] as? String
        let isError = obj["is_error"] as? Bool ?? false
        let usage = obj["usage"] as? [String: Any]

        if isError || out.status != 0 {
            let lowered = result.lowercased()
            if usageLimitMarkers.contains(where: { lowered.contains($0) }) {
                throw CLIError.usageLimit(message: result, sessionID: sessionID)
            }
            throw CLIError.exitFailure(code: out.status, message: result.isEmpty ? out.stderr : result)
        }

        return Envelope(
            result: result,
            stopReason: obj["stop_reason"] as? String,
            sessionID: sessionID,
            numTurns: obj["num_turns"] as? Int,
            durationMS: obj["duration_ms"] as? Int,
            totalCostUSD: obj["total_cost_usd"] as? Double,
            permissionDenialCount: (obj["permission_denials"] as? [Any])?.count ?? 0,
            inputTokens: usage?["input_tokens"] as? Int,
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
    /// just HOME/USER + the system PATH and the absolute binary path; Claude Code's Keychain
    /// OAuth resolves itself, no TTY needed (Arch §5, measured).
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
