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
//  remains writable after Sentient exits and the daemon can finish its cleanup.
//
//  Key methods: ensureRunning() · stop() · restart() · socketPath
//
//  Doc: Driver/Documentation - Driver (cua-driver).md
//

import Foundation

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

    // MARK: Lifecycle

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
                       // The one launch grant cua accepts: binding to the user's already-running,
                       // logged-in Chrome. A tool call can never ask for this, which is exactly why
                       // it has to be decided here.
                       "--grant", "existing-profile",
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
    }

    /// Write the CLI shim for this daemon generation — the space-free launcher the model's shell
    /// calls (`<shim> <tool> '<json>'`). Our `--socket` goes FIRST so it always wins (the driver
    /// takes the first occurrence of a flag), and the privacy env rides along so a one-shot call
    /// can never phone home. Also (re)creates the screenshot drop-box and wipes the previous
    /// generation's frames — they are content-bearing images of the user's windows, so they live
    /// exactly as long as they're useful.
    private func writeShim(socket: String) {
        let fm = FileManager.default
        let shim = CuaDriver.shimURL
        let shots = CuaDriver.shotsDirURL
        do {
            try fm.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: shots)                     // wipe last generation's frames
            try fm.createDirectory(at: shots, withIntermediateDirectories: true)
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
