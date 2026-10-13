//
//  WakeHelper.swift
//  Sentient OS macOS  ·  Scheduling/
//
//  Root-side wake helper. Runs as a LaunchDaemon — the app binary relaunched by launchd with
//  --wake-helper-managed (entry in main.swift). It controls sleep, schedules wakes, and maintains
//  its own helper files. Awake sessions have TWO independent nets: a DEADMAN
//  timer (the app crashes and stops heartbeating → the helper restores normal sleep itself) and an
//  absolute CEILING per awake session (the app is alive and heartbeating but wedged → sleep comes
//  back after `WakeHelperConfig.maxAwakeSeconds` regardless). A bug can never leave the Mac awake
//  all day. Connections are gated by a code-signing check.
//

import Foundation
import Security
import IOKit.pwr_mgt

final class WakeHelper: NSObject, WakeHelperProtocol, NSXPCListenerDelegate {

    /// Entry point for the bundled daemon and the older --wake-helper installation.
    static func run(legacy: Bool = false) -> Never {
        let helper = WakeHelper()
        guard getuid() == 0 else { exit(EXIT_FAILURE) }
        helper.log("starting (uid \(getuid()))")
        helper.legacy = legacy
        helper.pmset(["-a", "disablesleep", "0"], phase: .restore)
        helper.armedSpec = helper.loadArmed()
        _ = helper.prepareForUse()
        let serviceName = legacy ? WakeHelperConfig.legacyServiceName : WakeHelperConfig.machServiceName

        let listener = NSXPCListener(machServiceName: serviceName)
        listener.delegate = helper
        helper.log("listening on \(serviceName)")
        listener.resume()
        RunLoop.current.run()
        fatalError("wake helper run loop exited")
    }

    private let queue = DispatchQueue(label: "wakehelper")
    private var deadman: DispatchSourceTimer?
    private var ceiling: DispatchSourceTimer?   // absolute per-session limit — heartbeats never feed it
    private var lastTimeout = 7200
    private var holdingAwake = false
    private var diagnosticRevision = 0
    private var diagnosticClients: [ObjectIdentifier: (enabled: Bool, id: String)?] = [:]
    private var armedSpec: String?   // the pmset wake we last scheduled (for idempotent re-arm + cancel)
    private static let armedFile = WakeHelperMaintenance.armedPath
    private var legacy = false
    private var prepared = false
    private var retiringLegacyWake = false
    private var removing = false

    // MARK: - NSXPCListenerDelegate

    /// The requirement a connecting client must satisfy: this daemon's OWN designated
    /// requirement — the app and the daemon are the same signed binary, so "signed exactly like
    /// me" is airtight AND signer-agnostic (holds for the Developer ID release, a dev's Apple
    /// Development build, and an OSS self-build alike; even ad-hoc dev signing works, its DR
    /// being the shared binary's cdhash). If self-inspection fails, refuse all connections.
    private static let clientRequirement: String? = selfDesignatedRequirement()

    /// App and helper share this binary and its signing identity. SMAppService validates the
    /// bundled executable; this requirement authenticates each message from the GUI client.
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
        guard let requirement = Self.clientRequirement else { return false }
        conn.setCodeSigningRequirement(requirement)
        conn.exportedInterface = NSXPCInterface(with: WakeHelperProtocol.self)
        conn.exportedObject = self
        let clientID = ObjectIdentifier(conn)
        queue.async {
            self.log("connection from pid \(conn.processIdentifier): accepted (code-sign requirement armed)")
            self.diagnosticClients[clientID] = .some(nil)
            self.reconcileDiagnostics()
        }
        conn.invalidationHandler = { [weak self] in
            // The app's connection dropped (quit / crash / force-quit) → cancel the armed wake so a
            // Mac with Sentient closed never wakes on a stale schedule.
            self?.queue.async {
                self?.diagnosticClients.removeValue(forKey: clientID)
                // Retain the last authenticated choice after the last client exits: deadman/crash reporting still needs it.
                if self?.diagnosticClients.isEmpty == false { self?.reconcileDiagnostics() }
                if self?.removing == false { self?.cancelArmed(reason: "client gone") }
            }
        }
        conn.resume()
        return true
    }

    func configureDiagnostics(enabled: Bool, anonymousID: String, withReply reply: @escaping () -> Void) {
        guard let client = NSXPCConnection.current(), UUID(uuidString: anonymousID) != nil else { reply(); return }
        let clientID = ObjectIdentifier(client)
        queue.async {
            guard self.diagnosticClients.keys.contains(clientID) else { reply(); return }
            self.diagnosticClients[clientID] = (enabled, anonymousID)
            self.reconcileDiagnostics(completion: reply)
        }
    }

    /// With multiple users/clients connected, no single identity owns machine-wide helper events.
    private func reconcileDiagnostics(completion: @escaping () -> Void = {}) {
        diagnosticRevision += 1
        let revision = diagnosticRevision
        let selection = diagnosticClients.count == 1 ? diagnosticClients.values.first.flatMap { $0 } : nil
        Task { @MainActor in
            if let selection { CrashReporting.configureHelper(enabled: selection.enabled, anonymousID: selection.id, revision: revision) }
            else { CrashReporting.suspendHelper(revision: revision) }
            completion()
        }
    }

    // MARK: - WakeHelperProtocol

    func prepare(withReply reply: @escaping (Bool) -> Void) {
        queue.async { reply(self.prepareForUse()) }
    }

    /// Called before listening, then on the serial queue for retryable migration failures.
    private func prepareForUse() -> Bool {
        guard !removing else { return false }
        if prepared { return true }
        do {
            try WakeHelperMaintenance.validateSupportDirectory()
            if !legacy {
                let retired = try WakeHelperMaintenance.retireLegacy()
                retiringLegacyWake = retiringLegacyWake || retired
                if retiringLegacyWake {
                    guard pmset(["-a", "disablesleep", "0"], phase: .restore),
                          cancelArmed(reason: "legacy migration") else { return false }
                    retiringLegacyWake = false
                }
            }
            prepared = true
            return true
        } catch {
            Diagnostics.report(.wakeFailed, phase: .setup, reason: "legacy_cleanup", error: error, source: "wakeHelper")
            return false
        }
    }

    func prepareForRemoval(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            do {
                // Stop the old process first so it cannot change sleep or wake state after us.
                if !self.legacy { try WakeHelperMaintenance.retireLegacy() }
            } catch {
                Diagnostics.report(.wakeFailed, phase: .remove, reason: "legacy_cleanup", error: error, source: "wakeHelper")
                reply(false); return
            }
            // A failed restore leaves both safety timers alive. Never unregister in that state.
            guard self.pmset(["-a", "disablesleep", "0"], phase: .restore),
                  self.cancelArmed(reason: "uninstall") else { reply(false); return }
            self.holdingAwake = false
            self.cancelDeadman()
            self.cancelCeiling()
            do {
                try WakeHelperMaintenance.removeState()
                self.removing = true
                reply(true)
            } catch {
                Diagnostics.report(.wakeFailed, phase: .remove, reason: "helper_files", error: error, source: "wakeHelper")
                reply(false)
            }
        }
    }

    func cancelRemoval(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            self.removing = false
            reply(self.prepareForUse())
        }
    }

    func beginAwake(timeoutSeconds: Int, withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            guard self.prepared, !self.removing else { reply(false); return }
            let ok = self.pmset(["-a", "disablesleep", "1"], phase: .begin)
            if ok { self.holdingAwake = true }
            self.startDeadman(seconds: max(60, timeoutSeconds))
            self.startCeiling()
            self.log("beginAwake timeout=\(timeoutSeconds)s ceiling=\(WakeHelperConfig.maxAwakeSeconds)s ok=\(ok)")
            reply(ok)
        }
    }

    func heartbeat(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            guard self.prepared, !self.removing else { reply(false); return }
            self.startDeadman(seconds: self.lastTimeout); reply(true)
        }
    }

    func endAwake(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            // Restore normal sleep FIRST; only stand the deadman down if it actually succeeded.
            // If pmset fails we deliberately KEEP the deadman armed so it will later force
            // disablesleep 0 — cancelling it first (the old order) on a pmset failure would leave
            // the Mac awake all day, the exact failure the deadman exists to prevent (B5).
            let ok = self.pmset(["-a", "disablesleep", "0"], phase: .restore)
            if ok {
                self.holdingAwake = false
                self.cancelDeadman()
                self.cancelCeiling()
            } else {
                self.log("endAwake: pmset disablesleep 0 FAILED — leaving deadman + ceiling armed as backstop")
            }
            self.log("endAwake ok=\(ok)")
            reply(ok)
        }
    }

    func armWake(atEpoch epoch: Double, withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            guard self.prepared, !self.removing, epoch.isFinite else { reply(false); return }
            let spec = Self.spec(epoch)
            // Idempotent: drop any existing event at this exact time, then add exactly one — so the
            // app can re-arm the same time repeatedly without piling up duplicate wakes.
            _ = self.pmset(["schedule", "cancel", "wake", spec], phase: .arm, expectedAbsence: true)
            let ok = self.pmset(["schedule", "wake", spec], phase: .arm)
            self.armedSpec = spec
            self.persistArmed(spec)
            self.log("armWake \(spec) ok=\(ok)")
            reply(ok)
        }
    }

    func cancelWake(withReply reply: @escaping (Bool) -> Void) {
        queue.async { reply(self.cancelArmed(reason: "explicit")) }
    }

    func cancelAllWakes(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            guard !self.removing else { reply(false); return }
            guard self.pmset(["schedule", "cancelall"], phase: .cancel) else { reply(false); return }   // wipe every scheduled wake — clean slate
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
            let restored = self?.pmset(["-a", "disablesleep", "0"], phase: .deadman) ?? false
            if self?.holdingAwake == true {
                Diagnostics.report(.wakeFailed, phase: .deadman, reason: "safety_timer_fired",
                                   source: "wakeHelper", counts: [.elapsedMS: seconds * 1000], flags: [.restored: restored])
            }
            if restored { self?.holdingAwake = false }
            self?.cancelDeadman()
            self?.cancelCeiling()
        }
        t.resume()
        deadman = t
    }

    private func cancelDeadman() { deadman?.cancel(); deadman = nil }

    // MARK: - Ceiling

    /// The absolute awake limit, armed once per `beginAwake` and deliberately NOT fed by
    /// heartbeats: the deadman catches a DEAD app, this catches a wedged-but-alive one (still
    /// heartbeating, making no progress). When it fires, normal sleep comes back no matter what.
    private func startCeiling() {
        cancelCeiling()
        let seconds = WakeHelperConfig.maxAwakeSeconds
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(seconds))
        t.setEventHandler { [weak self] in
            self?.log("CEILING fired — awake \(seconds)s since beginAwake; forcing disablesleep 0")
            let restored = self?.pmset(["-a", "disablesleep", "0"], phase: .ceiling) ?? false
            Diagnostics.report(.wakeFailed, phase: .ceiling, reason: "safety_timer_fired",
                               source: "wakeHelper", counts: [.elapsedMS: seconds * 1000], flags: [.restored: restored])
            self?.cancelDeadman()
            self?.cancelCeiling()
        }
        t.resume()
        ceiling = t
    }

    private func cancelCeiling() { ceiling?.cancel(); ceiling = nil }

    // MARK: - pmset / codesign gate / log

    @discardableResult
    private func pmset(_ args: [String], phase: Diagnostics.Phase, expectedAbsence: Bool = false) -> Bool {
        do {
            let status = try WakeHelperMaintenance.run("/usr/bin/pmset", args)
            if status != 0, !expectedAbsence {
                log("pmset failed: phase=\(phase.rawValue) exit=\(status)")
                Diagnostics.report(.wakeFailed, phase: phase, reason: "pmset_exit", source: "wakeHelper",
                                   counts: [.exitCode: Int(status)])
            }
            return status == 0
        } catch {
            Diagnostics.report(.wakeFailed, phase: phase, reason: "pmset_launch", error: error, source: "wakeHelper")
            log("pmset failed: \(ErrorLabel(error))"); return false
        }
    }

    /// Idempotent, but never forget a wake that could not actually be cancelled. MUST run on queue.
    @discardableResult
    private func cancelArmed(reason: String) -> Bool {
        if let spec = armedSpec ?? loadArmed() {
            let cancelled = pmset(["schedule", "cancel", "wake", spec], phase: .cancel, expectedAbsence: true)
            if !cancelled {
                // pmset also fails when an event has already fired or been removed. Check the
                // native schedule before treating that expected absence as a cleanup failure.
                let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] ?? []
                let stillScheduled = events.contains { event in
                    guard let date = event[kIOPMPowerEventTimeKey] as? Date,
                          event[kIOPMPowerEventTypeKey] as? String == kIOPMAutoWake else { return false }
                    return Self.spec(date.timeIntervalSince1970) == spec
                }
                guard !stillScheduled else { return false }
            }
            log("cancelWake \(spec) (\(reason))")
        }
        armedSpec = nil
        persistArmed(nil)
        return true
    }

    private static func spec(_ epoch: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "MM/dd/yy HH:mm:ss"   // local time, matches pmset
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }

    private func persistArmed(_ spec: String?) {
        let url = URL(fileURLWithPath: Self.armedFile)
        guard !removing else { return }
        do {
            try WakeHelperMaintenance.validateSupportDirectory()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            if let spec { try spec.write(to: url, atomically: true, encoding: .utf8) }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch { Diagnostics.report(.wakeFailed, phase: .write, reason: "armed_state", error: error, source: "wakeHelper") }
    }

    private func loadArmed() -> String? {
        guard (try? WakeHelperMaintenance.validateSupportDirectory()) != nil else { return nil }
        let fd = open(Self.armedFile, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 64 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0, let value = String(bytes: bytes.prefix(count), encoding: .utf8) else { return nil }
        let spec = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter(); formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        return formatter.date(from: spec) == nil ? nil : spec
    }

    /// Root-side diagnostics, with no symlink traversal and no file recreation after removal.
    private func log(_ s: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] [helper] \(s)\n"
        if !removing {
            let fd = open(WakeHelperMaintenance.logPath, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
            if fd >= 0 {
                var info = stat()
                if fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0, info.st_nlink == 1 {
                    _ = line.withCString { write(fd, $0, strlen($0)) }
                }
                close(fd)
            }
        }
        FileHandle.standardError.write(Data(line.utf8))
    }
}
