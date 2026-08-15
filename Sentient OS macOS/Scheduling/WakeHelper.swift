//
//  WakeHelper.swift
//  Sentient OS macOS  ·  Scheduling/
//
//  Root-side wake helper. Runs as a LaunchDaemon — the app binary relaunched by launchd with
//  --wake-helper (entry in main.swift). It is the ONLY code path that runs as root, and all it
//  does is toggle `pmset disablesleep` and schedule wakes, behind a DEADMAN timer: if the app
//  crashes mid-run and stops sending heartbeats, the helper itself restores normal sleep — so a
//  bug can never leave the Mac awake all day. Connections are gated by a code-signing check.
//

import Foundation
import Security

final class WakeHelper: NSObject, WakeHelperProtocol, NSXPCListenerDelegate {

    /// Entry point from main.swift when launched with --wake-helper. Never returns.
    static func run() -> Never {
        let helper = WakeHelper()
        helper.log("starting (uid \(getuid()))")
        helper.pmset(["-a", "disablesleep", "0"])   // defensive: clear any keep-awake leaked by a prior crash
        helper.armedSpec = helper.loadArmed()        // re-learn a wake we armed before a daemon restart (don't cancel it)

        let listener = NSXPCListener(machServiceName: WakeHelperConfig.machServiceName)
        listener.delegate = helper
        listener.resume()
        helper.log("listening on \(WakeHelperConfig.machServiceName) · client requirement: \(clientRequirement)")
        RunLoop.current.run()
        fatalError("wake helper run loop exited")
    }

    private let queue = DispatchQueue(label: "wakehelper")
    private var deadman: DispatchSourceTimer?
    private var lastTimeout = 7200
    private var armedSpec: String?   // the pmset wake we last scheduled (for idempotent re-arm + cancel)
    private static let armedFile = "/Library/Application Support/SentientOS/armed-wake"

    // MARK: - NSXPCListenerDelegate

    /// The requirement a connecting client must satisfy: this daemon's OWN designated
    /// requirement — the app and the daemon are the same signed binary, so "signed exactly like
    /// me" is airtight AND signer-agnostic (holds for the Developer ID release, a dev's Apple
    /// Development build, and an OSS self-build alike; even ad-hoc dev signing works, its DR
    /// being the shared binary's cdhash). Falls back to the static identifier+anchor requirement
    /// if self-inspection somehow fails. Computed once; both sources are valid requirement
    /// strings by construction (setCodeSigningRequirement raises on a malformed one).
    private static let clientRequirement: String = selfDesignatedRequirement() ?? WakeHelperConfig.clientRequirement

    /// This binary's OWN designated requirement string ("signed exactly like me"), or nil if the
    /// system can't produce it. Shared by TWO callers: the XPC client gate here (which decides who
    /// may connect) AND `WakeHelperInstaller`, which bakes it into the daemon's launch-time
    /// `codesign --verify` so launchd never runs a tampered or foreign-signed binary as root. The
    /// app and the daemon are the same signed binary, so the value the installer captures in the
    /// app process matches what this gate expects in the daemon process.
    static func selfDesignatedRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { return nil }
        return text as String
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // The client gate, enforced by the SYSTEM per message via the official API (macOS 13+).
        // This replaced a hand-rolled audit-token check whose private `value(forKey: "auditToken")`
        // read came back empty on macOS 26 — every client "failed", DEBUG allowed-and-logged it,
        // and the first Release build slammed the door on our own app (field-found 2026-07-11).
        // Enforced in ALL configs now, so Debug exercises the same gate Release ships.
        conn.setCodeSigningRequirement(Self.clientRequirement)
        log("connection from pid \(conn.processIdentifier): accepted (code-sign requirement armed)")
        conn.exportedInterface = NSXPCInterface(with: WakeHelperProtocol.self)
        conn.exportedObject = self
        conn.invalidationHandler = { [weak self] in
            // The app's connection dropped (quit / crash / force-quit) → cancel the armed wake so a
            // Mac with Sentient closed never wakes on a stale schedule.
            self?.queue.async { self?.cancelArmed(reason: "client gone") }
        }
        conn.resume()
        return true
    }

    // MARK: - WakeHelperProtocol

    func beginAwake(timeoutSeconds: Int, withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            let ok = self.pmset(["-a", "disablesleep", "1"])
            self.startDeadman(seconds: max(60, timeoutSeconds))
            self.log("beginAwake timeout=\(timeoutSeconds)s ok=\(ok)")
            reply(ok)
        }
    }

    func heartbeat(withReply reply: @escaping (Bool) -> Void) {
        queue.async { self.startDeadman(seconds: self.lastTimeout); reply(true) }
    }

    func endAwake(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            // Restore normal sleep FIRST; only stand the deadman down if it actually succeeded.
            // If pmset fails we deliberately KEEP the deadman armed so it will later force
            // disablesleep 0 — cancelling it first (the old order) on a pmset failure would leave
            // the Mac awake all day, the exact failure the deadman exists to prevent (B5).
            let ok = self.pmset(["-a", "disablesleep", "0"])
            if ok {
                self.cancelDeadman()
            } else {
                self.log("endAwake: pmset disablesleep 0 FAILED — leaving deadman armed as backstop")
            }
            self.log("endAwake ok=\(ok)")
            reply(ok)
        }
    }

    func armWake(atEpoch epoch: Double, withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            let spec = Self.spec(epoch)
            // Idempotent: drop any existing event at this exact time, then add exactly one — so the
            // app can re-arm the same time repeatedly without piling up duplicate wakes.
            _ = self.pmset(["schedule", "cancel", "wake", spec])
            let ok = self.pmset(["schedule", "wake", spec])
            self.armedSpec = spec
            self.persistArmed(spec)
            self.log("armWake \(spec) ok=\(ok)")
            reply(ok)
        }
    }

    func cancelWake(withReply reply: @escaping (Bool) -> Void) {
        queue.async { self.cancelArmed(reason: "explicit"); reply(true) }
    }

    func cancelAllWakes(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            _ = self.pmset(["schedule", "cancelall"])   // wipe every scheduled wake — clean slate
            self.armedSpec = nil
            self.persistArmed(nil)
            self.log("cancelAllWakes (pmset schedule cancelall)")
            reply(true)
        }
    }

    // MARK: - Deadman

    private func startDeadman(seconds: Int) {
        lastTimeout = seconds
        cancelDeadman()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(seconds))
        t.setEventHandler { [weak self] in
            self?.log("DEADMAN fired — no heartbeat in \(seconds)s; forcing disablesleep 0")
            self?.pmset(["-a", "disablesleep", "0"])
            self?.cancelDeadman()
        }
        t.resume()
        deadman = t
    }

    private func cancelDeadman() { deadman?.cancel(); deadman = nil }

    // MARK: - pmset / codesign gate / log

    @discardableResult
    private func pmset(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { log("pmset \(args) failed: \(error)"); return false }
    }

    /// Cancels whatever wake we last armed (from memory, falling back to the persisted record so a
    /// restarted helper can still clean up). Idempotent. MUST run on `queue`.
    private func cancelArmed(reason: String) {
        if let spec = armedSpec ?? loadArmed() {
            _ = pmset(["schedule", "cancel", "wake", spec])
            log("cancelWake \(spec) (\(reason))")
        }
        armedSpec = nil
        persistArmed(nil)
    }

    private static func spec(_ epoch: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "MM/dd/yy HH:mm:ss"   // local time, matches pmset
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }

    private func persistArmed(_ spec: String?) {
        let url = URL(fileURLWithPath: Self.armedFile)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let spec { try? spec.write(to: url, atomically: true, encoding: .utf8) }
        else { try? FileManager.default.removeItem(at: url) }
    }

    private func loadArmed() -> String? {
        (try? String(contentsOf: URL(fileURLWithPath: Self.armedFile), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Root-side diagnostics. Goes to a root-writable log + stderr (visible in Console.app).
    private func log(_ s: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] [helper] \(s)\n"
        let url = URL(fileURLWithPath: "/Library/Logs/SentientOS-wakehelper.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
        FileHandle.standardError.write(Data(line.utf8))
    }
}
