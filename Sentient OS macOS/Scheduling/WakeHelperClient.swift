//
//  WakeHelperClient.swift
//  Sentient OS macOS  ·  Scheduling/
//
//  App-side client for the root wake helper. Registers the LaunchDaemon via SMAppService (a
//  one-time user approval in System Settings > Login Items), then drives the narrow XPC API. Every
//  call is async and fail-safe — if the helper isn't reachable, calls return false rather than throw.
//

import Foundation
import ServiceManagement

/// Runs a `(Bool) -> Void` exactly once, from whichever of reply/error/timeout wins. Thread-safe.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let body: (Bool) -> Void
    init(_ body: @escaping (Bool) -> Void) { self.body = body }
    func fire(_ value: Bool, diagnostic: () -> Void = {}) {
        lock.lock(); let go = !done; done = true; lock.unlock()
        if go { diagnostic(); body(value) }
    }
}

@MainActor
final class WakeHelperClient {
    static let shared = WakeHelperClient()
    private var connection: NSXPCConnection?
    private var removing = false
    private let registration = ServiceRegistration(kind: .wakeHelper)
    private var probing: Task<DaemonHealth, Never>?
    private var healthRetryAfter: TimeInterval = 0
    private var healthFailures = 0

    /// Only explicit setup actions call this. Registration may throw while successfully placing
    /// the item in the approval queue; status is authoritative in that case.
    @discardableResult
    func register() async -> SMAppService.Status {
        let result = await registration.perform(.register)
        let status = result.rawStatus.flatMap(SMAppService.Status.init(rawValue:)) ?? .notFound
        if let error = result.error, status != .requiresApproval {
            Diagnostics.report(.wakeFailed, phase: .setup, reason: "daemon_register", error: error)
            Log("WakeHelper register error: \(ErrorLabel(error))")
        }
        return status
    }

    /// Registration is consent, not liveness. Call healthProbe before scheduling any work.
    var status: SMAppService.Status { registration.cachedStatus ?? .notFound }
    var isReady: Bool { !removing && status == .enabled }
    func openLoginItemsSettings() {
        PermissionGuide.shared.guide(.overnightWake, dragging: nil)
    }

    enum DaemonHealth { case ready, requiresApproval, notSetUp, unavailable }

    func healthProbe() async -> DaemonHealth {
        guard !removing else { return .unavailable }
        if let probing {
            let health = await probing.value
            return removing ? .unavailable : health
        }
        guard ProcessInfo.processInfo.systemUptime >= healthRetryAfter else { return .unavailable }
        let task = Task { await self.checkHealth() }
        probing = task
        let health = await task.value
        probing = nil
        guard !removing else { return .unavailable }
        if health == .unavailable {
            healthFailures = min(healthFailures + 1, 5)
            healthRetryAfter = ProcessInfo.processInfo.systemUptime + min(300, 15 * pow(2, Double(healthFailures - 1)))
        } else { healthFailures = 0; healthRetryAfter = 0 }
        return health
    }

    private func checkHealth() async -> DaemonHealth {
        guard let status = await registration.refresh(), !removing else { return .unavailable }
        switch status {
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notSetUp
        case .notFound: return .unavailable
        case .enabled:
            let reachable = await call(quiet: true) { $0.prepare(withReply: $1) }
            // Approval can be revoked while the probe is in flight.
            guard let current = await registration.refresh(), !removing else { return .unavailable }
            if current == .requiresApproval { return .requiresApproval }
            return reachable && current == .enabled ? .ready : .unavailable
        @unknown default: return .unavailable
        }
    }

    /// Quiet, side-effect-free once migration completes; does not feed the awake deadman.
    func isReachable() async -> Bool {
        await healthProbe() == .ready
    }

    func setUp() async -> DaemonHealth {
        guard !removing else { return .unavailable }
        if let probing { _ = await probing.value }
        guard !removing else { return .unavailable }
        healthRetryAfter = 0; healthFailures = 0
        let registered = await register()
        guard !removing else { return .unavailable }
        if registered == .requiresApproval {
            openLoginItemsSettings()
            return .requiresApproval
        }
        guard registered == .enabled else { return .unavailable }
        // Recover if a prior app process exited after cleanup but before unregistering. Only
        // an explicit setup action may lift that hold; passive health checks cannot do so.
        _ = await call(quiet: true) { $0.cancelRemoval(withReply: $1) }
        // launchd can need a moment after approval. Do not promise readiness until XPC answers.
        for attempt in 0..<3 {
            // Explicit setup retries may bypass the passive health backoff. ServiceRegistration
            // still refuses to queue work behind a macOS request that has not returned.
            healthRetryAfter = 0
            let health = await healthProbe()
            if health != .unavailable || attempt == 2 { return health }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return .unavailable }
            invalidateConnection()
        }
        return .unavailable
    }

    /// Privileged cleanup happens BEFORE unregister, which immediately kills the daemon. A
    /// legacy-only installation first needs native approval so the new helper can remove it.
    func remove() async -> Bool {
        removing = true
        let hasRootFiles = [WakeHelperConfig.legacyPlistPath, WakeHelperMaintenance.supportPath,
                            WakeHelperMaintenance.logPath].contains { FileManager.default.fileExists(atPath: $0) }
        let current = await registration.refresh(force: true)
        guard let current else { return false }
        if current != .enabled, !hasRootFiles {
            return await unregister()
        }
        if current != .enabled {
            let registered = await register()
            if registered == .requiresApproval { openLoginItemsSettings() }
            guard registered == .enabled else { return false }
        }
        guard await call(phase: .remove, { $0.prepareForRemoval(withReply: $1) }) else { return false }
        return await unregister()
    }

    /// Restore the usable helper after the user cancels an incomplete uninstall.
    func cancelRemoval() async {
        if await registration.refresh(force: true) == .enabled { _ = await call(quiet: true) { $0.cancelRemoval(withReply: $1) } }
        removing = false
        healthRetryAfter = 0; healthFailures = 0
    }

    private func unregister() async -> Bool {
        let result = await registration.perform(.unregister)
        if let error = result.error {
            Diagnostics.report(.wakeFailed, phase: .remove, reason: "daemon_unregister", error: error)
            return false
        }
        if let status = result.rawStatus.flatMap(SMAppService.Status.init(rawValue:)), status == .notRegistered || status == .notFound {
            invalidateConnection()
            return true
        }
        return false
    }

    private func invalidateConnection() {
        let previous = connection
        connection = nil
        previous?.invalidate()
    }

    // MARK: - Wake operations

    func beginAwake(timeout: Int = 7200) async -> Bool { guard !removing else { return false }; return await call(phase: .begin) { $0.beginAwake(timeoutSeconds: timeout, withReply: $1) } }
    func heartbeat() async -> Bool { guard !removing else { return false }; return await call(phase: .heartbeat) { $0.heartbeat(withReply: $1) } }
    func endAwake() async -> Bool { await call(phase: .restore) { $0.endAwake(withReply: $1) } }
    func armWake(at date: Date) async -> Bool { guard !removing else { return false }; return await call(phase: .arm) { $0.armWake(atEpoch: date.timeIntervalSince1970, withReply: $1) } }
    func cancelWake() async -> Bool { await call(phase: .cancel) { $0.cancelWake(withReply: $1) } }
    func cancelAllWakes() async -> Bool { await call(phase: .cancel) { $0.cancelAllWakes(withReply: $1) } }

    // MARK: - XPC plumbing

    private func conn() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: WakeHelperConfig.machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: WakeHelperProtocol.self)
        c.invalidationHandler = { [weak self, weak c] in Task { @MainActor in
            if self?.connection === c { self?.connection = nil }
        } }
        c.resume()
        connection = c
        syncDiagnosticsConsent()
        return c
    }

    /// Does not start a helper or request installation when the diagnostics switch changes.
    func syncDiagnosticsConsent() {
        guard let connection else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? WakeHelperProtocol
        proxy?.configureDiagnostics(enabled: CrashReporting.diagnosticsEnabled,
                                    anonymousID: CrashReporting.installID, withReply: {})
    }

    /// Every call is guarded three ways so it can NEVER hang at 3am: the reply block, the XPC
    /// error handler (fires if the helper is unreachable), and a 30s timeout — all resume-once.
    /// `quiet` softens the error line for probes, where a miss is an expected state, not a fault.
    private func call(quiet: Bool = false, phase: Diagnostics.Phase = .probe,
                      _ body: @escaping (WakeHelperProtocol, @escaping (Bool) -> Void) -> Void) async -> Bool {
        let connection = conn()
        let operation = Diagnostics.current
        return await withCheckedContinuation { cont in
            let once = Once { cont.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                once.fire(false) {
                    if !quiet { Diagnostics.$current.withValue(operation) {
                        Diagnostics.report(.wakeFailed, phase: phase, reason: "xpc_timeout", counts: [.deadlineMS: 30_000])
                    } }
                }
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ err in
                if quiet { Log("WakeHelper probe: no daemon answering") }
                else { Log("WakeHelper XPC error: \(ErrorLabel(err))") }
                once.fire(false) {
                    if !quiet { Diagnostics.$current.withValue(operation) {
                        Diagnostics.report(.wakeFailed, phase: phase, reason: "xpc_error", error: err)
                    } }
                }
            }) as? WakeHelperProtocol else { once.fire(false); return }
            body(proxy) { ok in once.fire(ok) {
                if !ok && !quiet { Diagnostics.$current.withValue(operation) {
                    Diagnostics.report(.wakeFailed, phase: phase, reason: "helper_rejected")
                } }
            } }
        }
    }
}
