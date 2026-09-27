//
//  CuaDriverHost.swift
//  Sentient OS macOS  ·  Driver/
//
//  Sentient's long-lived cua-driver daemon — the process that actually clicks and types when the
//  Cua driver is the active one. Sentient spawns it ITSELF (never `open`, never NSWorkspace: macOS
//  attributes TCC to the top of the launch chain, and going through LaunchServices would hand the
//  daemon its own identity and cost the user a second Accessibility prompt). A codex run then
//  drives it with one-shot CLI calls through the shim this host writes per generation
//  (`<shim> <tool> '<json>'` — the shim bakes in the daemon's socket; see CuaDriver.shimURL).
//
//  Why a daemon at all, when `mcp --direct` needs no lifecycle code: only the daemon owns an AppKit
//  runloop, and that runloop is what draws the agent cursor — the glowing pointer that shows the
//  user where their agent is working without touching the real cursor. Direct mode has no overlay
//  at all. The daemon also keeps the runtime warm across commands instead of paying startup per fire.
//
//  The lifeline: the daemon's stdin is a pipe THIS process holds. `--parent-liveness-stdio` makes it
//  exit on EOF when Sentient quits or is killed. Its stderr goes to /dev/null so shutdown logging
//  remains writable after Sentient exits. Additional lifecycle backstops cover a daemon whose
//  AppKit runloop outlives its server: sweepOrphans() reaps orphaned daemons at launch, and an
//  atexit hook SIGTERMs the live owned daemon on normal quit.
//
//  Key methods: ensureRunning() · stop() · restart() · sweepOrphans() · socketPath
//
//  Doc: Driver/Documentation - Driver (cua-driver).md
//

import Foundation
import Synchronization

/// Owns at most ONE daemon for the app's lifetime. An actor because `ensureRunning()` is called from
/// every fire path (Sidekick, the command bar, a card) and two commands racing must not spawn two
/// daemons — the second would bind a second socket and quietly own a second cursor.
actor CuaDriverHost {

    static let shared = CuaDriverHost()
    private init() {}

    /// Set when the user's grants changed under a running daemon. macOS caches TCC answers PER
    /// PROCESS, so the daemon keeps believing it has no Accessibility until it is REPLACED —
    /// re-probing would just re-read the same stale answer. A flag rather than an immediate restart
    /// so there is no race with a command that is already on its way to `ensureRunning()`.
    private var grantsChanged = false

    private var process: Process?
    /// The write end of the daemon's stdin. Held for the daemon's whole life: releasing it is what
    /// tells the daemon to exit, so it must not be a local that goes out of scope.
    private var lifeline: FileHandle?
    private var socket: URL?

    /// The live daemon's socket, or nil when nothing is running.
    var socketPath: String? { socket?.path }

    /// The live daemon's pid, mirrored outside the actor for the synchronous atexit hook.
    /// 0 = no daemon. See armExitBackstop().
    private static let exitPID = Atomic<pid_t>(0)
    private static let exitHookInstalled = Atomic<Bool>(false)

    // MARK: Lifecycle

    /// The CLI label is owned by the app, not by the model. Starting it here revives an ended
    /// label without spending an LLM turn; ending it releases browser preparation and cursors.
    func beginAgentSession() async -> Bool {
        guard let socket, process?.isRunning == true else { return false }
        return await sessionCommand("start_session", socket: socket.path)
    }

    func endAgentSession() async {
        guard let socket, process?.isRunning == true else { return }
        if await !sessionCommand("end_session", socket: socket.path) {
            await MainActor.run { Log("CuaDriverHost: cleanup did not finish; replacing the owned daemon before another run") }
            await stop()
        }
    }

    private func sessionCommand(_ name: String, socket: String) async -> Bool {
        let binary = await CuaDriver.binaryURL.path
        // Cleanup must run even when STOP canceled the agent task. Await it before the one-task
        // lock is released, so it cannot close the next run's identically named CLI session.
        return await Task.detached {
            let deadline = Date().addingTimeInterval(name == "end_session" ? 8 : 20)
            repeat {
                do {
                    let result = try await CodexCLI.executeAsync(binary: binary,
                        args: ["--socket", socket, name, #"{"session":"sentient"}"#],
                        stdinText: nil, cwd: nil, timeout: name == "start_session" ? 20 : max(1, min(5, deadline.timeIntervalSinceNow)),
                        extraEnv: ["CUA_DRIVER_EMBEDDED": "1", "CUA_DRIVER_RS_TELEMETRY_ENABLED": "false",
                                   "CUA_TELEMETRY_ENABLED": "false", "CUA_DRIVER_RS_UPDATE_CHECK": "false"])
                    #if DEBUG
                    // Bounded lifecycle receipts for the isolated signed-host audit; no UI content.
                    let lab = ProcessInfo.processInfo.environment
                    if lab["SENTIENT_SELFTEST"] == "nativecua", let root = lab["LAB_ROOT"], let label = lab["LAB_NAME"] {
                        let receipt: [String: Any] = ["command": name, "exit": result.status,
                            "stdout": result.stdout, "stderr": result.stderr, "time": Date().timeIntervalSince1970]
                        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
                            let file = URL(fileURLWithPath: root).appendingPathComponent("evidence/\(label).session-\(name)-\(UUID().uuidString).json")
                            try? data.write(to: file, options: .atomic)
                        }
                    }
                    #endif
                    guard result.status == 0,
                          let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else { return false }
                    if name == "start_session" { return json["active"] as? Bool == true }
                    let pending = json["cleanup_in_progress"] as? Bool == true
                        || json["cleanup_complete"] as? Bool == false
                        || json["code"] as? String == "session_cleanup_pending"
                    if !pending { return json["active"] as? Bool == false || json["cleanup_complete"] as? Bool == true }
                    try await Task.sleep(for: .milliseconds(150))
                } catch { return false }
            } while Date() < deadline
            return false
        }.value
    }

    /// Make sure a daemon is up, and hand back its socket. Idempotent: a live daemon short-circuits
    /// (a cheap liveness check, not just "is the pid still there" — a wedged daemon that stopped
    /// answering is worse than none, so it gets replaced). Returns nil when the driver isn't
    /// installed or the daemon refused to come up; callers treat that as "this driver can't run".
    func ensureRunning() async -> String? {
        if grantsChanged, process != nil {
            Log("CuaDriverHost: grants changed under the running daemon — replacing it so macOS re-answers TCC")
            await stop()
        }
        grantsChanged = false
        if let socket, isAlive() { return socket.path }
        await stop()   // clear a dead or wedged generation before spawning over it
        guard CuaDriver.isInstalled else {
            Log("CuaDriverHost: cua-driver is not installed — cannot start the daemon")
            return nil
        }

        // A fresh endpoint per generation. Unix sockets cap at 104 bytes, and an embedded daemon
        // REFUSES to start if anything already exists at its path (upstream's deliberate
        // "prove-and-remove is the host's job"), so a per-launch name sidesteps both.
        let endpoint = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sentient-cua-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(6)).sock")
        try? FileManager.default.removeItem(at: endpoint)

        let bundleID = Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS"
        let p = Process()
        p.executableURL = CuaDriver.binaryURL
        p.arguments = ["serve", "--embedded",
                       "--socket", endpoint.path,
                       "--host-bundle-id", bundleID,
                       "--permission-mode", "standard",
                       // No launch grants, on purpose: the only one the driver accepts
                       // (`existing-profile`) unlocks its typed CDP route into the user's Chrome,
                       // which is off — see CuaDriver.enabledTools. Without the grant the daemon
                       // refuses that attachment outright, the one hard gate that matters.
                       // Exit when our end of stdin closes (the lifeline below).
                       "--parent-liveness-stdio",
                       // We own the permission experience; the daemon must never raise its own UI.
                       "--no-permissions-gate",
                       // The agent cursor's motion: the daemon default is glide 0 — the cursor
                       // TELEPORTS between action points, which reads as nothing happening.
                       // 420 ms is upstream's own showcase glide; per-run cursor instances are
                       // built from this launch-time config (measured 2026-08-20: the overlay
                       // renders and pins above the target window — a fresh session just needs
                       // motion to be visible as motion).
                       "--glide-ms", "420"]
        // A curated environment, not ours wholesale: the daemon needs only enough to find the user's
        // home and temp dir. The three privacy variables are NOT optional — cua-driver ships with
        // PostHog telemetry ON and a daily GitHub update check, and neither belongs on a Sentient
        // user's machine on our behalf.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        p.environment = [
            "HOME": home,
            "USER": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "CUA_DRIVER_EMBEDDED": "1",
            "CUA_DRIVER_HOST_BUNDLE_ID": bundleID,
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "false",
            "CUA_TELEMETRY_ENABLED": "false",
            "CUA_DRIVER_RS_UPDATE_CHECK": "false",
        ]

        let stdinPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = FileHandle.nullDevice
        // The driver logs during its EOF shutdown. This destination must remain writable after
        // Sentient exits, so closing the host's descriptors cannot interrupt that cleanup.
        p.standardError = FileHandle.nullDevice

        do { try p.run() } catch {
            Log("CuaDriverHost: failed to launch the daemon — \(ErrorLabel(error))")
            return nil
        }
        process = p
        lifeline = stdinPipe.fileHandleForWriting
        socket = endpoint
        armExitBackstop(for: p.processIdentifier)

        // The socket appearing is the honest readiness signal (upstream binds it, then chmods 0600).
        // Poll rather than sleep, so a fast Mac isn't taxed and a slow one isn't cut short.
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: endpoint.path) {
                writeShim(socket: endpoint.path)
                Log("CuaDriverHost: daemon up (cua-driver \(CuaDriver.version), pid \(p.processIdentifier))")
                return endpoint.path
            }
            if !p.isRunning { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Log("CuaDriverHost: daemon did not bind its socket within 5s — standing it down")
        await stop()
        return nil
    }

    /// Stop the daemon: close the lifeline (its documented graceful exit), give it a beat, then
    /// terminate anything left. Idempotent, and safe to call when nothing is running.
    func stop() async {
        guard let p = process else { clear(); return }
        try? lifeline?.close()
        lifeline = nil
        for _ in 0..<20 {                       // ~1s of grace
            if !p.isRunning { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if p.isRunning { p.terminate() }
        if let socket { try? FileManager.default.removeItem(at: socket) }
        clear()
        Log("CuaDriverHost: daemon stopped")
    }

    /// The user just granted (or changed) a permission: the next command gets a fresh daemon.
    func markGrantsChanged() { grantsChanged = true }

    /// Bring the daemon back on a fresh generation. The reason this exists: macOS caches TCC answers
    /// PER PROCESS, so a grant the user gives after the daemon started is invisible to it until it
    /// is replaced. The permission gate calls this the moment it sees a grant land.
    func restart() async {
        await stop()
        _ = await ensureRunning()
    }

    // MARK: The two backstops (see the header: the lifeline alone is not enough)

    /// Reap daemons leaked by previous app lives. Called once per launch (AppState's startup task):
    /// every process running OUR embedded daemon binary carries its spawning Sentient's pid in its
    /// socket name — if that host is no longer a live Sentient process, the daemon is an orphan.
    /// SIGTERM, a short grace, SIGKILL for anything still standing, then the socket file. Spared on
    /// purpose: daemons of OTHER live Sentient instances (host pid alive and a Sentient binary),
    /// and any standalone CuaDriver.app a user installed themselves (wrong binary path). Also clears
    /// stale `sentient-cua-*.sock` files whose host is gone, so a fresh daemon can never collide
    /// with a dead generation's leftovers.
    nonisolated static func sweepOrphans() async {
        // One process snapshot: pid + full command line (`ww` = never truncate).
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,args="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch {
            Log("CuaDriverHost: orphan sweep could not snapshot processes — \(ErrorLabel(error))")
            return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        var orphans: [(pid: pid_t, socket: String?)] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard let gap = entry.firstIndex(of: " "), let pid = pid_t(entry[..<gap]) else { continue }
            let command = String(entry[entry.index(after: gap)...])
            // Verify the executable itself. ps may spell /private/tmp as /tmp, and argv[0]
            // alone is not an identity check. Resolve aliases and require a directory boundary.
            guard command.contains(" serve "), isManagedBinary(binaryPath(of: pid)) else { continue }
            guard let host = hostPID(in: command), !isLiveSentient(host) else { continue }
            orphans.append((pid, socketPath(in: command)))
        }

        if !orphans.isEmpty {
            for orphan in orphans { kill(orphan.pid, SIGTERM) }
            for _ in 0..<20 {   // ~2s of grace before the hard kill
                guard orphans.contains(where: { kill($0.pid, 0) == 0 }) else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            for orphan in orphans where kill(orphan.pid, 0) == 0 { kill(orphan.pid, SIGKILL) }
            for orphan in orphans {
                if let socket = orphan.socket { try? FileManager.default.removeItem(atPath: socket) }
            }
            Log("CuaDriverHost: swept \(orphans.count) orphaned daemon(s) left by previous app lives")
        }

        let tmp = NSTemporaryDirectory()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []
        where name.hasPrefix("sentient-cua-") && name.hasSuffix(".sock") {
            guard let host = hostPID(in: name), !isLiveSentient(host) else { continue }
            try? FileManager.default.removeItem(atPath: tmp + name)
        }
    }

    /// Mirror the daemon's pid where the atexit hook can see it, and install that hook once. The
    /// hook is the backstop for a NORMAL quit: process exit closes the lifeline anyway, but a
    /// daemon that has run a session can miss the EOF (see the header), so the exit path also
    /// sends a plain SIGTERM — after re-proving the pid still names our daemon, so a pid recycled
    /// since the daemon died on its own can never catch a stray signal.
    private func armExitBackstop(for pid: pid_t) {
        Self.exitPID.store(pid, ordering: .relaxed)
        guard !Self.exitHookInstalled.exchange(true, ordering: .relaxed) else { return }
        atexit {
            let pid = CuaDriverHost.exitPID.load(ordering: .relaxed)
            guard pid > 0, CuaDriverHost.isManagedBinary(CuaDriverHost.binaryPath(of: pid))
            else { return }
            kill(pid, SIGTERM)
        }
    }

    /// The Sentient pid baked into a daemon's socket name (`sentient-cua-<pid>-<nonce>.sock`),
    /// findable in a command line and a bare file name alike.
    nonisolated private static func hostPID(in text: String) -> pid_t? {
        guard let mark = text.range(of: "sentient-cua-") else { return nil }
        return pid_t(text[mark.upperBound...].prefix(while: \.isNumber))
    }

    /// The `--socket` value in a daemon's command line (a temp-dir path — never has spaces).
    nonisolated private static func socketPath(in command: String) -> String? {
        guard let flag = command.range(of: "--socket ") else { return nil }
        let path = command[flag.upperBound...].prefix(while: { $0 != " " })
        return path.isEmpty ? nil : String(path)
    }

    /// Is this pid a live Sentient process? Compared by executable NAME, not path, so a daemon
    /// spawned by a Debug build is recognized by the Release app and vice versa.
    nonisolated private static func isLiveSentient(_ pid: pid_t) -> Bool {
        let path = binaryPath(of: pid)
        guard !path.isEmpty else { return false }
        return URL(fileURLWithPath: path).lastPathComponent
            == (Bundle.main.executableURL?.lastPathComponent ?? "Sentient OS")
    }

    /// The executable behind a pid, or "" when it can't be read (dead pid, or another user's
    /// process — both read as "not ours", which is the safe answer for every caller here).
    nonisolated private static func binaryPath(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    nonisolated private static func isManagedBinary(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let root = CuaDriver.installRoot.resolvingSymlinksInPath().standardizedFileURL.path
        return executable.lastPathComponent == "cua-driver" && executable.path.hasPrefix(root + "/")
    }

    // MARK: Internals

    /// Is the daemon actually answering? `status` speaks the real protocol, so a wedged daemon that
    /// still holds a pid reads as dead — which is what we want before handing it a user's command.
    private func isAlive() -> Bool {
        guard let socket, let p = process, p.isRunning else { return false }
        let probe = Process()
        probe.executableURL = CuaDriver.binaryURL
        probe.arguments = ["status", "--socket", socket.path]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        probe.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                             "PATH": "/usr/bin:/bin",
                             "CUA_DRIVER_RS_TELEMETRY_ENABLED": "false",
                             "CUA_DRIVER_RS_UPDATE_CHECK": "false"]
        do { try probe.run() } catch { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    private func clear() {
        process = nil
        lifeline = nil
        socket = nil
        Self.exitPID.store(0, ordering: .relaxed)
    }

    /// Write the CLI shim for this daemon generation — the space-free launcher the model's shell
    /// calls (`<shim> <tool> '<json>'`). Our `--socket` goes FIRST so it always wins (the driver
    /// takes the first occurrence of a flag), and the privacy env rides along so a one-shot call
    /// can never phone home.
    private func writeShim(socket: String) {
        let fm = FileManager.default
        let shim = CuaDriver.shimURL
        do {
            try fm.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The typed browser route used to save page screenshots beside the shim; those frames
            // are content-bearing, so sweep any left by an earlier version once.
            try? fm.removeItem(at: shim.deletingLastPathComponent().appendingPathComponent("cua-shots"))
            let script = """
            #!/bin/sh
            # Sentient OS — cua-driver one-shot launcher (regenerated per daemon generation).
            export CUA_DRIVER_RS_TELEMETRY_ENABLED=false CUA_TELEMETRY_ENABLED=false CUA_DRIVER_RS_UPDATE_CHECK=false
            exec "\(CuaDriver.binaryURL.path)" --socket "\(socket)" "$@"
            """
            try script.write(to: shim, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        } catch {
            // Non-fatal on purpose: the daemon is up; a failed shim only surfaces when the model's
            // first call can't find it, and the run's own failure line says why.
            Log("CuaDriverHost: could not write the CLI shim — \(ErrorLabel(error))")
        }
    }
}
