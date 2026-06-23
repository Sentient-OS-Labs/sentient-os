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
        helper.log("listening on \(WakeHelperConfig.machServiceName)")
        RunLoop.current.run()
        fatalError("wake helper run loop exited")
    }

    private let queue = DispatchQueue(label: "wakehelper")
    private var deadman: DispatchSourceTimer?
    private var lastTimeout = 7200
    private var armedSpec: String?   // the pmset wake we last scheduled (for idempotent re-arm + cancel)
    private static let armedFile = "/Library/Application Support/SentientOS/armed-wake"

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        let trusted = isClientTrusted(conn)
        log("connection from pid \(conn.processIdentifier): codesign check \(trusted ? "PASSED" : "FAILED")")
        if !trusted {
            #if DEBUG
            log("DEBUG build: allowing despite failed check (verify the codesign gate before Release).")
            #else
            return false
            #endif
        }
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
            self.cancelDeadman()
            let ok = self.pmset(["-a", "disablesleep", "0"])
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

    /// Verifies the connecting process is our signed app via its audit token (PID is racy).
    private func isClientTrusted(_ conn: NSXPCConnection) -> Bool {
        guard let tokenData = conn.value(forKey: "auditToken") as? Data,
              tokenData.count == MemoryLayout<audit_token_t>.size else { return false }
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(WakeHelperConfig.clientRequirement as CFString, [], &req) == errSecSuccess,
              let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
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
